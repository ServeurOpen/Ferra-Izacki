-- ============================================================
-- Izacki — Migration 9 : classement — nom affiché plus propre quand le
-- joueur n'a pas défini de Nom d'affichage.
-- Avant : retombait sur le générique "Joueur" pour tout le monde, ce qui
-- rendait plusieurs joueurs indiscernables dans le classement.
-- Après : retombe sur le pseudo Izacki (username, sans le #numéro) --
-- n'est plus JAMAIS vide puisque le username est obligatoire à l'inscription.
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_8_leaderboard.sql.
-- ============================================================

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
      coalesce(p.display_name, p.username, 'Joueur') as display_name,
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
