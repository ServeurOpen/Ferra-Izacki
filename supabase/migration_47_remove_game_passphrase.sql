-- ============================================================
-- Izacki — Migration 47 : mot de passe de passage aussi pour la
-- suppression d'un jeu (06/09/2026, demande explicite : "fais en sorte
-- qu'il faut mettre le mdp ban 2000 caractère aussi").
--
-- L'erreur "Could not find the function public.admin_remove_game
-- (p_game_id, p_reason) in the schema cache" que tu as eue vient de
-- migration_40 : elle a été écrite et donnée le 06/09/2026 (en même
-- temps que "suppression de jeu admin" dans le Launcher v0.2.54), mais
-- n'a en réalité jamais été exécutée dans Supabase — pas un bug de code,
-- juste une migration jamais lancée (le genre de chose que tu m'avais
-- justement demandé de noter quand ça arrive). Si ce n'est pas déjà
-- fait, exécute d'abord, DANS L'ORDRE :
--   1. migration_39_ticket_unread_attachments.sql
--   2. migration_40_admin_remove_game.sql
-- (les deux sont sans risque à relancer même si elles l'ont déjà été —
-- tout y est écrit en "if not exists" / "create or replace").
-- PUIS cette migration_47, après migration_46.
--
-- On ajoute p_passphrase à admin_remove_game : comme d'habitude sur ce
-- projet quand on change une liste de paramètres, il faut DROP l'ancienne
-- signature avant de recréer, sinon Postgres garde les deux fonctions en
-- parallèle au lieu de remplacer (piège déjà rencontré en migration_23
-- et migration_43).
-- ============================================================

drop function if exists public.admin_remove_game(uuid, text);

create function public.admin_remove_game(p_game_id uuid, p_reason text, p_passphrase text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seller_id uuid;
  v_title text;
  v_check jsonb;
begin
  if not public.is_current_user_admin() then
    raise exception 'forbidden';
  end if;
  v_check := public._verify_admin_passphrase(p_passphrase);
  if not coalesce((v_check->>'ok')::boolean, false) then
    return v_check;
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
grant execute on function public.admin_remove_game(uuid, text, text) to authenticated;

NOTIFY pgrst, 'reload schema';
