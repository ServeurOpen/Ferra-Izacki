-- ============================================================
-- Izacki — Migration 30 : temps de jeu dans le Portail créateurs
-- (05/09/2026) — débloqué par l'installation/lancement natif des jeux
-- .exe du marketplace (voir launch_marketplace_game côté Rust, qui émet
-- le même événement "game-session-end" que les jeux officiels → même
-- pipeline add_playtime déjà générique, aucune restriction de game_id).
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

drop function if exists public.creator_portal_games();
create function public.creator_portal_games()
returns table(game_id uuid, title text, status text, price_credits int, sales_count bigint, credits_earned bigint, total_playtime_secs bigint)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
    select sg.id, sg.title, sg.status, sg.price_credits,
           count(gp.id)::bigint as sales_count,
           coalesce(sum(gp.price_credits), 0)::bigint as credits_earned,
           coalesce((select sum(total_secs) from public.game_stats where game_id = sg.id::text), 0)::bigint as total_playtime_secs
    from public.submitted_games sg
    left join public.game_purchases gp on gp.game_id = sg.id
    where sg.seller_id = auth.uid()
    group by sg.id, sg.title, sg.status, sg.price_credits
    order by sg.created_at desc;
end;
$$;
grant execute on function public.creator_portal_games() to authenticated;
