-- ============================================================
-- Izacki — Migration 5 : profils stylisés (bannière/avatar/nom
-- d'affichage/vie privée), statistiques de jeu synchronisées (temps de
-- jeu) et succès débloqués par jeu, visibles depuis le Launcher (popup
-- profil cliquable dans Amis + page "Mon Profil").
-- À exécuter UNE FOIS dans Supabase, APRÈS toutes les migrations
-- précédentes (migration_4_tag_pseudo.sql en particulier, pour
-- player_number).
-- ============================================================

-- ---- Profil enrichi ----
-- display_name : nom affiché partout (bulle profil, Amis...) — distinct du
-- "username#numero" (le vrai identifiant Izacki, jamais modifiable, voir
-- migration_4). Si vide, le launcher retombe sur le username.
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists banner_url text;
alter table public.profiles add column if not exists is_private boolean not null default false;

-- Un joueur privé n'est visible en détail que par lui-même — les autres ne
-- voient plus ni ses stats/succès/bannière via les policies ci-dessous.
-- Le pseudo/tag reste public (nécessaire pour Amis/recherche par tag).
drop policy if exists "Les profils sont visibles par tous" on public.profiles;
create policy "Le pseudo/tag de tous les profils reste visible"
  on public.profiles for select
  using (true);
-- (Le détail enrichi — display_name/avatar/banner — est de toute façon
-- masqué côté launcher si is_private=true et que ce n'est pas ton profil ;
-- la ligne reste lisible pour ne pas casser la recherche par tag/Amis.)

-- ---- Statistiques de jeu (temps de jeu synchronisé) ----
-- Une ligne par (joueur, jeu) — le launcher envoie le cumul à chaque fin de
-- session (voir "game-session-end" côté src-tauri/src/lib.rs et
-- syncPlaytime côté src/main.ts).
create table if not exists public.game_stats (
  user_id uuid not null references auth.users(id) on delete cascade,
  game_id text not null,
  total_secs bigint not null default 0,
  last_played_at timestamptz,
  primary key (user_id, game_id)
);

alter table public.game_stats enable row level security;

create policy "Stats visibles si profil public ou le sien"
  on public.game_stats for select
  using (
    auth.uid() = user_id
    or exists (select 1 from public.profiles p where p.id = user_id and p.is_private = false)
  );

create policy "Un joueur ecrit uniquement ses propres stats"
  on public.game_stats for insert
  with check (auth.uid() = user_id);

create policy "Un joueur met a jour uniquement ses propres stats"
  on public.game_stats for update
  using (auth.uid() = user_id);

-- ---- Succès débloqués par jeu ----
-- achievement_id = identifiant stable défini côté jeu (ex. "first_blood",
-- "kills_1000"...). name/description/icon/tier sont envoyés PAR LE JEU au
-- moment du déblocage (voir izacki-cloud.js -> izackiUnlockAchievement) —
-- plutôt que de dupliquer à la main la liste de chaque jeu côté launcher
-- (FERRA/Tower Défense en ont des dizaines, certains générés
-- dynamiquement par palier), chaque jeu reste la seule source de vérité
-- sur son propre contenu. Le launcher se contente d'afficher ce qui lui
-- est rapporté.
create table if not exists public.game_achievements (
  user_id uuid not null references auth.users(id) on delete cascade,
  game_id text not null,
  achievement_id text not null,
  name text,
  description text,
  icon text,
  tier text,
  unlocked_at timestamptz not null default now(),
  primary key (user_id, game_id, achievement_id)
);

alter table public.game_achievements enable row level security;

create policy "Succes visibles si profil public ou le sien"
  on public.game_achievements for select
  using (
    auth.uid() = user_id
    or exists (select 1 from public.profiles p where p.id = user_id and p.is_private = false)
  );

create policy "Un joueur debloque uniquement ses propres succes"
  on public.game_achievements for insert
  with check (auth.uid() = user_id);

-- ---- Stockage : bannières et avatars ----
-- Buckets publics en lecture (les images doivent s'afficher chez les amis
-- qui les consultent) mais écriture restreinte au propriétaire, un dossier
-- par utilisateur (chemin "{user_id}/xxx.png") — voir uploadProfileImage
-- côté src/main.ts.
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true), ('banners', 'banners', true)
on conflict (id) do nothing;

drop policy if exists "Avatars lisibles par tous" on storage.objects;
create policy "Avatars lisibles par tous"
  on storage.objects for select
  using (bucket_id = 'avatars');

drop policy if exists "Un joueur gere uniquement son propre avatar" on storage.objects;
create policy "Un joueur gere uniquement son propre avatar"
  on storage.objects for all
  using (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1])
  with check (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);

drop policy if exists "Bannieres lisibles par tous" on storage.objects;
create policy "Bannieres lisibles par tous"
  on storage.objects for select
  using (bucket_id = 'banners');

drop policy if exists "Un joueur gere uniquement sa propre banniere" on storage.objects;
create policy "Un joueur gere uniquement sa propre banniere"
  on storage.objects for all
  using (bucket_id = 'banners' and auth.uid()::text = (storage.foldername(name))[1])
  with check (bucket_id = 'banners' and auth.uid()::text = (storage.foldername(name))[1]);

-- ---- Upsert pratique pour les jeux (évite un aller-retour select+insert
-- côté jeu pour cumuler le temps de jeu) ----
create or replace function public.add_playtime(p_game_id text, p_secs bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.game_stats (user_id, game_id, total_secs, last_played_at)
  values (auth.uid(), p_game_id, greatest(p_secs, 0), now())
  on conflict (user_id, game_id)
    do update set total_secs = public.game_stats.total_secs + greatest(p_secs, 0), last_played_at = now();
end;
$$;

grant execute on function public.add_playtime(text, bigint) to authenticated;

-- Débloque un succès pour l'appelant connecté — idempotent (un succès déjà
-- débloqué ne fait rien, jamais d'erreur si le jeu retente). name/icon/tier
-- optionnels : un jeu qui ne les transmet pas garde juste l'id (le launcher
-- affiche alors un badge générique).
create or replace function public.unlock_achievement(
  p_game_id text, p_achievement_id text,
  p_name text default null, p_description text default null,
  p_icon text default null, p_tier text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.game_achievements (user_id, game_id, achievement_id, name, description, icon, tier)
  values (auth.uid(), p_game_id, p_achievement_id, p_name, p_description, p_icon, p_tier)
  on conflict (user_id, game_id, achievement_id) do nothing;
end;
$$;

grant execute on function public.unlock_achievement(text, text, text, text, text, text) to authenticated;
