-- ============================================================
-- Izacki — Migration 8 : classement (leaderboard) générique par jeu.
-- Première utilisation : Tower Défense Infini, métrique "best_wave"
-- (meilleure vague atteinte, tous run confondus). Le schéma est générique
-- (game_id + metric) pour pouvoir servir d'autres jeux/métriques plus
-- tard sans nouvelle migration.
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_5_profils_stylises.sql
-- (utilise public.profiles.display_name/avatar_url/is_private).
-- ============================================================

create table if not exists public.leaderboard_scores (
  user_id uuid not null references auth.users(id) on delete cascade,
  game_id text not null,
  metric text not null,
  best_value integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, game_id, metric)
);

alter table public.leaderboard_scores enable row level security;

-- Lecture publique de la table brute désactivée : tout passe par la
-- fonction get_leaderboard() ci-dessous, qui respecte is_private. Aucune
-- policy select => aucun accès direct table pour les clients (seul le rôle
-- service peut la lire directement, jamais utilisé côté jeu/launcher).

-- Écriture : uniquement via submit_leaderboard_score() (security definer),
-- jamais d'insert/update direct côté client — pas de policy insert/update
-- ici non plus, la fonction contourne RLS avec security definer.

-- ---- Soumission d'un score (le jeu envoie sa meilleure valeur locale ;
-- seul le maximum est conservé côté serveur, jamais écrasé par une valeur
-- plus basse) ----
create or replace function public.submit_leaderboard_score(p_game_id text, p_metric text, p_value integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return;
  end if;
  insert into public.leaderboard_scores (user_id, game_id, metric, best_value, updated_at)
  values (auth.uid(), p_game_id, p_metric, greatest(coalesce(p_value, 0), 0), now())
  on conflict (user_id, game_id, metric) do update
    set best_value = greatest(public.leaderboard_scores.best_value, excluded.best_value),
        updated_at = case
          when excluded.best_value > public.leaderboard_scores.best_value then now()
          else public.leaderboard_scores.updated_at
        end;
end;
$$;

grant execute on function public.submit_leaderboard_score(text, text, integer) to authenticated;

-- ---- Lecture du classement (top N) — exclut les profils privés (sauf le
-- sien propre, toujours inclus avec son rang réel calculé sur l'ensemble
-- des scores, privés compris, pour rester honnête) ----
create or replace function public.get_leaderboard(p_game_id text, p_metric text, p_limit integer default 20)
returns table(
  user_id uuid,
  display_name text,
  avatar_url text,
  best_value integer,
  updated_at timestamptz,
  rank integer
)
language sql
security definer
set search_path = public
as $$
  with ranked as (
    select
      ls.user_id,
      coalesce(p.display_name, 'Joueur') as display_name,
      p.avatar_url,
      ls.best_value,
      ls.updated_at,
      coalesce(p.is_private, false) as is_private,
      row_number() over (order by ls.best_value desc, ls.updated_at asc) as rank
    from public.leaderboard_scores ls
    left join public.profiles p on p.id = ls.user_id
    where ls.game_id = p_game_id and ls.metric = p_metric
  )
  select user_id, display_name, avatar_url, best_value, updated_at, rank
  from ranked
  where not is_private or user_id = auth.uid()
  order by rank asc
  limit greatest(1, least(coalesce(p_limit, 20), 100));
$$;

grant execute on function public.get_leaderboard(text, text, integer) to authenticated, anon;

-- ---- Rang + score d'un joueur précis, même hors du top N affiché ----
create or replace function public.get_my_leaderboard_rank(p_game_id text, p_metric text)
returns table(best_value integer, rank integer, total_players integer)
language sql
security definer
set search_path = public
as $$
  with ranked as (
    select
      user_id,
      best_value,
      row_number() over (order by best_value desc, updated_at asc) as rank,
      count(*) over () as total_players
    from public.leaderboard_scores
    where game_id = p_game_id and metric = p_metric
  )
  select best_value, rank, total_players from ranked where user_id = auth.uid();
$$;

grant execute on function public.get_my_leaderboard_rank(text, text) to authenticated;
