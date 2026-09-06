-- ============================================================
-- Izacki — Migration 38 : correctif urgent — le remboursement échouait
-- (06/09/2026, bug remonté par le joueur : "Échec : update or delete on
-- table refund_requests violates foreign key constraint
-- support_tickets_refund_request_id_fkey").
--
-- Cause : admin_process_refund() fait `delete from game_purchases`, qui
-- CASCADE vers refund_requests (purchase_id ... on delete cascade, voir
-- migration_33) — mais support_tickets.refund_request_id référence
-- refund_requests SANS règle on delete (défaut = RESTRICT), donc ce
-- cascade était bloqué net dès qu'un ticket existait pour cette demande.
-- Toute la fonction annulait sa transaction (aucun crédit déplacé, aucun
-- message posté) malgré le message d'erreur peu clair côté joueur/admin.
--
-- Correctif en 2 parties :
--  1) La contrainte passe en ON DELETE SET NULL (le ticket ne dépend pas
--     de l'existence de la ligne refund_requests pour continuer à vivre).
--  2) admin_process_refund() capture l'id du ticket AVANT de supprimer
--     game_purchases (donc avant que le cascade ne survienne), pour
--     pouvoir quand même y poster la réponse auto et le fermer après coup.
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_37.
-- ============================================================

alter table public.support_tickets drop constraint if exists support_tickets_refund_request_id_fkey;
alter table public.support_tickets
  add constraint support_tickets_refund_request_id_fkey
  foreign key (refund_request_id) references public.refund_requests(id) on delete set null;

create or replace function public.admin_process_refund(p_request_id uuid, p_approve boolean, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_buyer_id uuid;
  v_seller_id uuid;
  v_purchase_id uuid;
  v_amount int;
  v_ticket_id uuid;
begin
  if not public.is_current_user_admin() then
    raise exception 'forbidden';
  end if;
  if not p_approve and coalesce(trim(p_reason), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'rejection_reason_required');
  end if;

  update public.refund_requests
    set status = case when p_approve then 'approved' else 'rejected' end,
        rejection_reason = case when p_approve then null else trim(p_reason) end,
        processed_at = now()
    where id = p_request_id and status = 'pending'
    returning buyer_id, seller_id, purchase_id, amount_credits into v_buyer_id, v_seller_id, v_purchase_id, v_amount;

  if v_buyer_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found_or_already_processed');
  end if;

  -- Capturé AVANT le delete game_purchases ci-dessous (voir explication
  -- en tête de fichier) — sinon le cascade aurait déjà mis
  -- refund_request_id à NULL sur le ticket avant qu'on ait pu le retrouver.
  select id into v_ticket_id from public.support_tickets where refund_request_id = p_request_id;

  if p_approve then
    update public.profiles set credits = credits + v_amount where id = v_buyer_id;
    update public.profiles set credits = credits - v_amount where id = v_seller_id;
    insert into public.credit_transactions (user_id, amount, reason) values (v_buyer_id, v_amount, 'refund_received');
    insert into public.credit_transactions (user_id, amount, reason) values (v_seller_id, -v_amount, 'refund_clawback');
    delete from public.game_purchases where id = v_purchase_id;
  end if;

  if v_ticket_id is not null then
    insert into public.support_ticket_messages (ticket_id, sender, message)
      values (v_ticket_id, 'system',
        case when p_approve
          then 'De la part de l''équipe Ferra : vos crédits ont été remboursés. Bonne journée à vous.'
          else 'De la part de l''équipe Ferra : votre demande de remboursement a été refusée. Motif : ' || coalesce(trim(p_reason), '') || '. Bonne journée à vous.'
        end);
    update public.support_tickets set status = 'closed', closed_at = now() where id = v_ticket_id;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_process_refund(uuid, boolean, text) to authenticated;
