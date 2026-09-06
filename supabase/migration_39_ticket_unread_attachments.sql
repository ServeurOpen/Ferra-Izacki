-- ============================================================
-- Izacki — Migration 39 : badge "non lu" précis par ticket + pièces
-- jointes (06/09/2026, demande explicite).
--
-- Non-lu : chaque ticket connaît la date de sa dernière activité
-- (last_message_at) et la date à laquelle CHAQUE camp l'a vue pour la
-- dernière fois (player_last_seen_at / admin_last_seen_at) — un ticket
-- est "non lu" pour un camp si last_message_at est postérieur à SA
-- propre date de dernière vue. admin_last_seen_at démarre à NULL (jamais
-- vu) pour qu'un tout nouveau ticket compte bien comme non lu côté admin
-- dès sa création.
--
-- Pièces jointes : chemin de stockage optionnel par message (même bucket
-- que les captures de jeu, dossier dédié <ticket_id>/<message_id>.<ext>),
-- utile surtout pour les signalements de bug (capture d'écran du souci).
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_38.
-- ============================================================

alter table public.support_tickets add column if not exists last_message_at timestamptz not null default now();
alter table public.support_tickets add column if not exists player_last_seen_at timestamptz not null default now();
alter table public.support_tickets add column if not exists admin_last_seen_at timestamptz;
alter table public.support_ticket_messages add column if not exists attachment_path text;

-- Rattrapage des tickets déjà créés pendant les tests (avant cette
-- colonne) : last_message_at prend la vraie date du dernier message
-- existant plutôt que de rester sur la valeur par défaut "maintenant".
update public.support_tickets t
  set last_message_at = coalesce(
    (select max(m.created_at) from public.support_ticket_messages m where m.ticket_id = t.id),
    t.created_at
  );

-- ---- Bucket de stockage pour les pièces jointes de tickets ----
insert into storage.buckets (id, name, public)
  values ('ticket-attachments', 'ticket-attachments', true)
  on conflict (id) do nothing;
drop policy if exists "Un joueur gere ses propres pieces jointes de ticket" on storage.objects;
create policy "Un joueur gere ses propres pieces jointes de ticket"
  on storage.objects for all
  using (bucket_id = 'ticket-attachments' and (auth.uid()::text = (storage.foldername(name))[1] or public.is_current_user_admin()))
  with check (bucket_id = 'ticket-attachments' and (auth.uid()::text = (storage.foldername(name))[1] or public.is_current_user_admin()));

-- ---- send_ticket_message étendue : pièce jointe optionnelle + tient
-- last_message_at à jour ----
-- DROP obligatoire : nouveau paramètre = signature différente de la
-- version migration_37 (uuid, text) — "create or replace" créerait un
-- doublon (uuid, text, text default null) au lieu de remplacer, et comme
-- ce nouveau paramètre a une valeur par défaut, PostgREST pourrait alors
-- hésiter entre les deux à chaque appel à 2 arguments (même piège que
-- migration_23/43).
drop function if exists public.send_ticket_message(uuid, text);

create function public.send_ticket_message(p_ticket_id uuid, p_message text, p_attachment_path text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ticket record;
  v_is_admin boolean;
begin
  select * into v_ticket from public.support_tickets where id = p_ticket_id;
  if v_ticket.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  v_is_admin := public.is_current_user_admin();
  if not v_is_admin and v_ticket.user_id <> auth.uid() then
    return jsonb_build_object('ok', false, 'reason', 'forbidden');
  end if;
  if v_ticket.status = 'closed' then
    return jsonb_build_object('ok', false, 'reason', 'ticket_closed');
  end if;
  if coalesce(trim(p_message), '') = '' and p_attachment_path is null then
    return jsonb_build_object('ok', false, 'reason', 'message_required');
  end if;
  insert into public.support_ticket_messages (ticket_id, sender, message, attachment_path)
    values (p_ticket_id, case when v_is_admin then 'admin' else 'player' end, coalesce(trim(p_message), ''), p_attachment_path);
  update public.support_tickets set last_message_at = now() where id = p_ticket_id;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.send_ticket_message(uuid, text, text) to authenticated;

-- ---- Marque un ticket comme vu par celui qui appelle (joueur ou admin) ----
create or replace function public.mark_ticket_seen(p_ticket_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ticket record;
begin
  select * into v_ticket from public.support_tickets where id = p_ticket_id;
  if v_ticket.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  if public.is_current_user_admin() then
    update public.support_tickets set admin_last_seen_at = now() where id = p_ticket_id;
  elsif v_ticket.user_id = auth.uid() then
    update public.support_tickets set player_last_seen_at = now() where id = p_ticket_id;
  else
    return jsonb_build_object('ok', false, 'reason', 'forbidden');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.mark_ticket_seen(uuid) to authenticated;

-- ---- admin_list_support_tickets étendue (last_message_at/admin_last_seen_at) ----
-- DROP obligatoire : on ajoute 2 colonnes à la table de retour, Postgres
-- refuse de changer le type de retour d'une fonction existante avec un
-- simple "create or replace" (erreur 42P13, même piège que d'habitude
-- sur ce projet quand une signature change).
drop function if exists public.admin_list_support_tickets();

create function public.admin_list_support_tickets()
returns table(
  id uuid, user_email text, category text, subject text, status text,
  refund_request_id uuid, created_at timestamptz, closed_at timestamptz,
  last_message_at timestamptz, admin_last_seen_at timestamptz
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
    select t.id, u.email::text, t.category, t.subject, t.status, t.refund_request_id, t.created_at, t.closed_at,
           t.last_message_at, t.admin_last_seen_at
    from public.support_tickets t
    join auth.users u on u.id = t.user_id
    order by (t.status = 'open') desc, t.last_message_at desc;
end;
$$;
grant execute on function public.admin_list_support_tickets() to authenticated;

-- ---- admin_process_refund : le message auto met aussi last_message_at à jour ----
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
    update public.support_tickets set status = 'closed', closed_at = now(), last_message_at = now() where id = v_ticket_id;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_process_refund(uuid, boolean, text) to authenticated;

NOTIFY pgrst, 'reload schema';
