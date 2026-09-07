-- ============================================================
-- Izacki — Classement du studio : 6e catégorie "Achats de crédits"
-- (07/09/2026, demande explicite : "ceux qui ont le plus acheté de
-- crédit... dépensé d'argent"). Compromis volontaire — voir cadrage en
-- chat ("le meilleur juste milieu") : classé sur les CRÉDITS achetés
-- (monnaie du jeu, voir stripe_topups.amount_credits), jamais le montant
-- réel en euros, pour ne pas exposer une info financière trop précise
-- publiquement. Même fonction que migration_54/55, corps complet
-- (CREATE OR REPLACE, signature inchangée, pas de DROP nécessaire).
-- ============================================================

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

  elsif p_category = 'topups' then
    -- Crédits achetés avec de l'argent réel (voir stripe_topups,
    -- migration_20) — jamais le montant en euros, juste le nombre de
    -- crédits, pour rester dans la même monnaie "de jeu" que les autres
    -- catégories plutôt que d'afficher une somme d'argent réelle.
    return query
      with agg as (
        select st.user_id as uid, sum(st.amount_credits)::numeric as val
        from public.stripe_topups st
        group by st.user_id
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
