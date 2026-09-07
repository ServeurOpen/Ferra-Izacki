-- ============================================================
-- Izacki — Classement du studio, multi-catégories (07/09/2026, demande
-- explicite : "un classement... le plus d'heure de jeux, le plus de
-- tokens, le plus de crédit... plein de classement... des sous
-- catégorie"). Un seul onglet "Classement" dans le Launcher, à ne PAS
-- confondre avec le classement propre à Tower Défense (meilleure vague,
-- voir migration_8/migration_9) qui reste inchangé et vit dans le jeu
-- lui-même — celui-ci est transverse à TOUT le studio.
--
-- Respecte la même règle de confidentialité que le classement Tower
-- Défense : un profil "is_private" n'apparaît jamais, sauf pour
-- lui-même (auth.uid()).
-- ============================================================

drop function if exists public.get_studio_leaderboard(text, integer);
create or replace function public.get_studio_leaderboard(p_category text, p_limit integer default 20)
returns table (
  user_id uuid,
  display_name text,
  avatar_url text,
  value numeric,
  rank integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 20), 100));
begin
  if p_category = 'playtime' then
    -- Temps de jeu cumulé, TOUS les jeux confondus (voir game_stats,
    -- alimentée par add_playtime à chaque fin de session).
    return query
      with agg as (
        select gs.user_id as uid, sum(gs.total_secs)::numeric as val
        from public.game_stats gs
        group by gs.user_id
      ), ranked as (
        select a.uid, a.val,
               coalesce(p.display_name, p.username, 'Joueur') as dn,
               p.avatar_url as av,
               coalesce(p.is_private, false) as priv,
               row_number() over (order by a.val desc) as rnk
        from agg a join public.profiles p on p.id = a.uid
        where a.val > 0
      )
      select uid, dn, av, val, rnk::integer from ranked
      where not priv or uid = auth.uid()
      order by rnk limit v_limit;

  elsif p_category = 'tokens' then
    -- Tokens (économie de profil, migration_48) — la fraction de minute
    -- en cours (token_playtime_remainder_secs) est comptée pour être
    -- cohérent avec ce qu'affiche déjà le Launcher (voir renderCreditsChip).
    return query
      with ranked as (
        select p.id as uid,
               (p.tokens + p.token_playtime_remainder_secs / 60.0)::numeric as val,
               coalesce(p.display_name, p.username, 'Joueur') as dn,
               p.avatar_url as av,
               coalesce(p.is_private, false) as priv,
               row_number() over (order by (p.tokens + p.token_playtime_remainder_secs / 60.0) desc) as rnk
        from public.profiles p
        where p.tokens > 0
      )
      select uid, dn, av, val, rnk::integer from ranked
      where not priv or uid = auth.uid()
      order by rnk limit v_limit;

  elsif p_category = 'credits' then
    return query
      with ranked as (
        select p.id as uid, p.credits::numeric as val,
               coalesce(p.display_name, p.username, 'Joueur') as dn,
               p.avatar_url as av,
               coalesce(p.is_private, false) as priv,
               row_number() over (order by p.credits desc) as rnk
        from public.profiles p
        where p.credits > 0
      )
      select uid, dn, av, val, rnk::integer from ranked
      where not priv or uid = auth.uid()
      order by rnk limit v_limit;

  elsif p_category = 'sales' then
    -- Ventes marketplace des créateurs (voir game_purchases, migration_29)
    -- — le plein montant, jamais l'identité des acheteurs (déjà la règle
    -- ailleurs dans le projet).
    return query
      with agg as (
        select gp.seller_id as uid, sum(gp.price_credits)::numeric as val
        from public.game_purchases gp
        where gp.price_credits > 0
        group by gp.seller_id
      ), ranked as (
        select a.uid, a.val,
               coalesce(p.display_name, p.username, 'Joueur') as dn,
               p.avatar_url as av,
               coalesce(p.is_private, false) as priv,
               row_number() over (order by a.val desc) as rnk
        from agg a join public.profiles p on p.id = a.uid
      )
      select uid, dn, av, val, rnk::integer from ranked
      where not priv or uid = auth.uid()
      order by rnk limit v_limit;

  elsif p_category = 'referrals' then
    -- Parrainages CONFIRMÉS uniquement (le filleul a atteint le palier
    -- jour 3, voir migration_18/claim_daily_reward) — pas juste "inscrit
    -- avec mon code", pour ne récompenser que les vrais parrainages actifs.
    return query
      with agg as (
        select referred_by as uid, count(*)::numeric as val
        from public.profiles
        where referred_by is not null and daily_reward_day >= 3
        group by referred_by
      ), ranked as (
        select a.uid, a.val,
               coalesce(p.display_name, p.username, 'Joueur') as dn,
               p.avatar_url as av,
               coalesce(p.is_private, false) as priv,
               row_number() over (order by a.val desc) as rnk
        from agg a join public.profiles p on p.id = a.uid
      )
      select uid, dn, av, val, rnk::integer from ranked
      where not priv or uid = auth.uid()
      order by rnk limit v_limit;

  else
    return;
  end if;
end;
$$;
grant execute on function public.get_studio_leaderboard(text, integer) to authenticated;

notify pgrst, 'reload schema';
