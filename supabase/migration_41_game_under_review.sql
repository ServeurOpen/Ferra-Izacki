-- ============================================================
-- Izacki — Migration 41 : "Mettre en examen" un jeu soumis (06/09/2026,
-- demande explicite) — 3e action de modération en plus d'Accepter/
-- Refuser, envoie une notification en TEMPS RÉEL au vendeur ("Votre jeu
-- est mis en examen, il sera disponible d'ici quelques minutes").
--
-- game_review_notifications avait un simple booléen `approved` (ne
-- pouvait représenter que 2 issues) — ajout d'une colonne `kind` à 3
-- valeurs, `approved` gardée pour compatibilité (dérivée automatiquement).
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_40.
-- ============================================================

alter table public.submitted_games drop constraint if exists submitted_games_status_check;
alter table public.submitted_games
  add constraint submitted_games_status_check
  check (status in ('pending', 'approved', 'rejected', 'removed', 'under_review'));

alter table public.game_review_notifications add column if not exists kind text;
update public.game_review_notifications set kind = case when approved then 'approved' else 'rejected' end where kind is null;
alter table public.game_review_notifications alter column kind set not null;
alter table public.game_review_notifications drop constraint if exists game_review_notifications_kind_check;
alter table public.game_review_notifications
  add constraint game_review_notifications_kind_check
  check (kind in ('approved', 'rejected', 'under_review'));

create or replace function public.admin_set_game_under_review(p_game_id uuid)
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
  update public.submitted_games
    set status = 'under_review'
    where id = p_game_id and status = 'pending'
    returning seller_id, title into v_seller_id, v_title;
  if v_seller_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found_or_already_reviewed');
  end if;
  insert into public.game_review_notifications (seller_id, game_id, game_title, approved, kind)
    values (v_seller_id, p_game_id, v_title, false, 'under_review');
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_set_game_under_review(uuid) to authenticated;

-- ---- admin_list_pending_games étendue : montre aussi les jeux "en
-- examen" (avec leur statut), pas seulement "pending" — DROP obligatoire
-- avant de recréer : le retour (RETURNS TABLE) change de forme (colonne
-- `status` en plus), `create or replace` seul refuse ce genre de
-- changement ("cannot change return type of existing function"). ----
drop function if exists public.admin_list_pending_games();
create function public.admin_list_pending_games()
returns table(
  id uuid, seller_id uuid, seller_email text, title text, description text,
  price_cents int, file_type text, file_path text, file_size_bytes bigint,
  screenshot_paths text[], created_at timestamptz, status text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_current_user_admin() then
    raise exception 'forbidden';
  end if;
  return query
    select sg.id, sg.seller_id, u.email::text, sg.title, sg.description, sg.price_credits,
           sg.file_type, sg.file_path, sg.file_size_bytes, sg.screenshot_paths, sg.created_at, sg.status
    from public.submitted_games sg
    join auth.users u on u.id = sg.seller_id
    where sg.status in ('pending', 'under_review')
    order by sg.created_at asc;
end;
$$;
grant execute on function public.admin_list_pending_games() to authenticated;

-- ---- admin_review_game : peut désormais aussi trancher un jeu qui
-- était "en examen" (pas seulement "pending") ----
create or replace function public.admin_review_game(p_game_id uuid, p_approve boolean, p_rejection_reason text default null)
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
  if not p_approve and coalesce(trim(p_rejection_reason), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'rejection_reason_required');
  end if;

  update public.submitted_games
    set status = case when p_approve then 'approved' else 'rejected' end,
        rejection_reason = case when p_approve then null else trim(p_rejection_reason) end,
        reviewed_by = auth.uid(),
        reviewed_at = now()
    where id = p_game_id and status in ('pending', 'under_review')
    returning seller_id, title into v_seller_id, v_title;

  if v_seller_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found_or_already_reviewed');
  end if;

  insert into public.game_review_notifications (seller_id, game_id, game_title, approved, kind, rejection_reason)
    values (v_seller_id, p_game_id, v_title, p_approve, case when p_approve then 'approved' else 'rejected' end,
            case when p_approve then null else trim(p_rejection_reason) end);

  return jsonb_build_object('ok', true, 'sellerId', v_seller_id, 'title', v_title);
end;
$$;
grant execute on function public.admin_review_game(uuid, boolean, text) to authenticated;

-- ---- Realtime : le vendeur doit recevoir la notification "en examen"
-- SANS avoir à redémarrer le Launcher ----
do $$
begin
  alter publication supabase_realtime add table public.game_review_notifications;
exception when duplicate_object then null;
end $$;
