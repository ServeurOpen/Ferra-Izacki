-- ============================================================
-- Izacki — Migration 26 : marketplace "Sortir mon jeu" — Phase 1 (soumission
-- + modération), demandé le 05/09/2026.
--
-- Phase 1 = soumission d'un jeu (fichier + description + prix) par un
-- joueur, file d'attente admin (accepter/refuser + raison), notification
-- au joueur. PAS ENCORE la vente/paiement (Stripe Connect, partage 97/3%
-- confirmé par le joueur) — ce sera la Phase 2, une fois la modération en
-- place et testée.
--
-- Mêmes principes de sécurité que tout le reste du projet : jamais de
-- write direct sur le statut (pending/approved/rejected) depuis le
-- client — seules les fonctions "security definer" admin_list_pending_games
-- et admin_review_game (réservées à ferra.izacki@gmail.com) peuvent
-- changer un statut.
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

-- ---- Buckets de stockage ----
-- "game-submission-files" : PRIVÉ — le jeu lui-même (.zip pour un jeu
-- HTML, .exe pour un exécutable). Pas de vente/téléchargement public en
-- Phase 1, seul le vendeur et l'admin (via une future fonction Edge de
-- lecture, Phase 2) y auront accès.
-- "game-submission-screenshots" : PUBLIC — juste des images, aucune
-- raison de les protéger, elles doivent s'afficher dans la fiche du jeu.
insert into storage.buckets (id, name, public)
  values ('game-submission-files', 'game-submission-files', false)
  on conflict (id) do nothing;
insert into storage.buckets (id, name, public)
  values ('game-submission-screenshots', 'game-submission-screenshots', true)
  on conflict (id) do nothing;

drop policy if exists "Un joueur gere ses propres fichiers de jeu soumis" on storage.objects;
create policy "Un joueur gere ses propres fichiers de jeu soumis"
  on storage.objects for all
  using (bucket_id = 'game-submission-files' and auth.uid()::text = (storage.foldername(name))[1])
  with check (bucket_id = 'game-submission-files' and auth.uid()::text = (storage.foldername(name))[1]);

-- L'admin doit pouvoir télécharger le jeu d'un AUTRE joueur pour le
-- vérifier avant validation — sans ça, seul le vendeur lui-même pourrait
-- lire son propre fichier (policy ci-dessus).
drop policy if exists "Admin lit tous les fichiers de jeu soumis" on storage.objects;
create policy "Admin lit tous les fichiers de jeu soumis"
  on storage.objects for select
  using (
    bucket_id = 'game-submission-files'
    and (select lower(trim(au.email)) from auth.users au where au.id = auth.uid()) = 'ferra.izacki@gmail.com'
  );

drop policy if exists "Captures de jeu soumis lisibles par tous" on storage.objects;
create policy "Captures de jeu soumis lisibles par tous"
  on storage.objects for select
  using (bucket_id = 'game-submission-screenshots');
drop policy if exists "Un joueur gere ses propres captures de jeu soumis" on storage.objects;
create policy "Un joueur gere ses propres captures de jeu soumis"
  on storage.objects for all
  using (bucket_id = 'game-submission-screenshots' and auth.uid()::text = (storage.foldername(name))[1])
  with check (bucket_id = 'game-submission-screenshots' and auth.uid()::text = (storage.foldername(name))[1]);

-- ---- Table des jeux soumis ----
create table if not exists public.submitted_games (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 2 and 80),
  description text not null check (char_length(trim(description)) between 10 and 4000),
  price_cents int not null check (price_cents >= 0),
  file_type text not null check (file_type in ('html_zip', 'exe')),
  file_path text not null,
  file_size_bytes bigint not null default 0,
  screenshot_paths text[] not null default '{}',
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  rejection_reason text,
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists submitted_games_seller_idx on public.submitted_games (seller_id);
create index if not exists submitted_games_status_idx on public.submitted_games (status);

alter table public.submitted_games enable row level security;

drop policy if exists "Jeux approuves visibles par tous, sinon par le vendeur" on public.submitted_games;
create policy "Jeux approuves visibles par tous, sinon par le vendeur"
  on public.submitted_games for select
  using (status = 'approved' or seller_id = auth.uid());

drop policy if exists "Un joueur soumet son propre jeu en attente" on public.submitted_games;
create policy "Un joueur soumet son propre jeu en attente"
  on public.submitted_games for insert
  with check (seller_id = auth.uid() and status = 'pending');

drop policy if exists "Un joueur retire sa soumission tant qu'elle est en attente" on public.submitted_games;
create policy "Un joueur retire sa soumission tant qu'elle est en attente"
  on public.submitted_games for delete
  using (seller_id = auth.uid() and status = 'pending');
-- Pas de policy UPDATE pour "authenticated" : changer le statut
-- (approuver/refuser) ne passe QUE par admin_review_game ci-dessous.

-- ---- Notifications de résultat de modération (05/09/2026, demande
-- explicite : "le joueur recevra un mail + alertes a l'entrée dans le
-- launcher pop ups") — même principe que credit_gift_notifications :
-- le joueur consulte ses propres notifications non vues au boot du
-- Launcher, puis les marque vues. ----
create table if not exists public.game_review_notifications (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references auth.users(id) on delete cascade,
  game_id uuid not null references public.submitted_games(id) on delete cascade,
  game_title text not null,
  approved boolean not null,
  rejection_reason text,
  created_at timestamptz not null default now(),
  seen boolean not null default false
);
alter table public.game_review_notifications enable row level security;
drop policy if exists "Un joueur gere ses propres notifications de jeu" on public.game_review_notifications;
create policy "Un joueur gere ses propres notifications de jeu"
  on public.game_review_notifications for all
  using (seller_id = auth.uid())
  with check (seller_id = auth.uid());
-- L'insertion réelle passe par admin_review_game (security definer),
-- cette policy "for all" ne sert qu'à autoriser le SELECT/UPDATE (marquer
-- vue) du joueur sur SES propres lignes.

-- ---- Modération (admin uniquement) ----
create or replace function public.admin_list_pending_games()
returns table(
  id uuid, seller_id uuid, seller_email text, title text, description text,
  price_cents int, file_type text, file_path text, file_size_bytes bigint,
  screenshot_paths text[], created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select lower(trim(au.email)) from auth.users au where au.id = auth.uid()) is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  return query
    select sg.id, sg.seller_id, u.email::text, sg.title, sg.description, sg.price_cents,
           sg.file_type, sg.file_path, sg.file_size_bytes, sg.screenshot_paths, sg.created_at
    from public.submitted_games sg
    join auth.users u on u.id = sg.seller_id
    where sg.status = 'pending'
    order by sg.created_at asc;
end;
$$;
grant execute on function public.admin_list_pending_games() to authenticated;

create or replace function public.admin_review_game(p_game_id uuid, p_approve boolean, p_rejection_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_email text;
  v_seller_id uuid;
  v_title text;
begin
  select lower(trim(email)) into v_caller_email from auth.users where id = auth.uid();
  if v_caller_email is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  if not p_approve and coalesce(trim(p_rejection_reason), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'rejection_reason_required');
  end if;

  update public.submitted_games
    set status = case when p_approve then 'approved' else 'rejected' end,
        rejection_reason = case when p_approve then null else trim(p_rejection_reason) end,
        reviewed_by = auth.uid(),
        reviewed_at = now()
    where id = p_game_id and status = 'pending'
    returning seller_id, title into v_seller_id, v_title;

  if v_seller_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found_or_already_reviewed');
  end if;

  insert into public.game_review_notifications (seller_id, game_id, game_title, approved, rejection_reason)
    values (v_seller_id, p_game_id, v_title, p_approve, case when p_approve then null else trim(p_rejection_reason) end);

  return jsonb_build_object('ok', true, 'sellerId', v_seller_id, 'title', v_title);
end;
$$;
grant execute on function public.admin_review_game(uuid, boolean, text) to authenticated;
