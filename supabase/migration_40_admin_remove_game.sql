-- ============================================================
-- Izacki — Migration 40 : suppression d'un jeu du marketplace par l'admin
-- (06/09/2026, demande explicite : "je dois mettre une raison, et ça la
-- met dans le mail au joueur").
--
-- SUPPRESSION LOGIQUE (status='removed'), jamais un vrai DELETE de la
-- ligne : submitted_games est référencée par game_purchases (achats déjà
-- faits) et refund_requests — un vrai DELETE aurait cascadé et fait
-- disparaître l'historique d'achat des joueurs qui l'ont déjà acquis
-- (ils gardent leur accès, seule la fiche disparaît de la Boutique pour
-- empêcher de nouveaux achats — même logique qu'un jeu "retiré" sur les
-- plateformes classiques).
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_39.
-- ============================================================

alter table public.submitted_games drop constraint if exists submitted_games_status_check;
alter table public.submitted_games
  add constraint submitted_games_status_check
  check (status in ('pending', 'approved', 'rejected', 'removed'));
alter table public.submitted_games add column if not exists removal_reason text;
alter table public.submitted_games add column if not exists removed_at timestamptz;

create or replace function public.admin_remove_game(p_game_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seller_id uuid;
  v_title text;
begin
  if not public.is_current_user_admin() then
    raise exception 'forbidden';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;
  update public.submitted_games
    set status = 'removed', removal_reason = trim(p_reason), removed_at = now()
    where id = p_game_id and status = 'approved'
    returning seller_id, title into v_seller_id, v_title;
  if v_seller_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found_or_not_approved');
  end if;
  return jsonb_build_object('ok', true, 'sellerId', v_seller_id, 'title', v_title);
end;
$$;
grant execute on function public.admin_remove_game(uuid, text) to authenticated;
