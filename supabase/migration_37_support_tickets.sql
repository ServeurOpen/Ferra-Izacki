-- ============================================================
-- Izacki — Migration 37 : Service Client / tickets d'assistance
-- (06/09/2026, demande explicite) — onglet Launcher où un joueur ouvre un
-- ticket (Question / Bug / Remboursement / Autre) façon Amazon : une seule
-- conversation qui reste consultable même une fois fermée. Une demande de
-- remboursement créée via un ticket catégorie "Remboursement" appelle EN
-- INTERNE la même request_refund() déjà existante (migration_33) — elle
-- arrive donc "au même endroit qu'actuellement" pour l'admin (Launcher +
-- panel.html, section Demandes de remboursement), sans rien dupliquer.
-- Quand l'admin traite cette demande (admin_process_refund, inchangée
-- niveau appelant), on poste maintenant automatiquement un message dans
-- le ticket lié ("De la part de l'équipe Ferra : ...") et on le referme.
-- Le bouton "Demander un remboursement" existant sur la fiche d'un jeu
-- passe par ce même chemin désormais (voir Launcher/src/main.ts).
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_33_refunds.sql.
-- ============================================================

create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  category text not null check (category in ('question', 'bug', 'refund', 'other')),
  subject text not null,
  status text not null default 'open' check (status in ('open', 'closed')),
  -- Rempli uniquement pour la catégorie "refund" (voir create_support_ticket) —
  -- relie ce ticket à la vraie ligne refund_requests que l'admin traite.
  refund_request_id uuid references public.refund_requests(id),
  created_at timestamptz not null default now(),
  closed_at timestamptz
);
create index if not exists support_tickets_user_idx on public.support_tickets (user_id);
create index if not exists support_tickets_status_idx on public.support_tickets (status);
alter table public.support_tickets enable row level security;
drop policy if exists "Un joueur voit ses tickets, l'admin voit tout" on public.support_tickets;
create policy "Un joueur voit ses tickets, l'admin voit tout"
  on public.support_tickets for select
  using (user_id = auth.uid() or public.is_current_user_admin());
-- Pas de policy insert/update pour "authenticated" : seules les fonctions
-- security definer ci-dessous (+ admin_process_refund) écrivent ici.

create table if not exists public.support_ticket_messages (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets(id) on delete cascade,
  sender text not null check (sender in ('player', 'admin', 'system')),
  message text not null,
  created_at timestamptz not null default now()
);
create index if not exists support_ticket_messages_ticket_idx on public.support_ticket_messages (ticket_id);
alter table public.support_ticket_messages enable row level security;
drop policy if exists "Voit les messages de ses propres tickets, l'admin voit tout" on public.support_ticket_messages;
create policy "Voit les messages de ses propres tickets, l'admin voit tout"
  on public.support_ticket_messages for select
  using (
    exists (
      select 1 from public.support_tickets t
      where t.id = ticket_id and (t.user_id = auth.uid() or public.is_current_user_admin())
    )
  );

-- ---- Création d'un ticket ----
create or replace function public.create_support_ticket(
  p_category text, p_subject text, p_message text, p_game_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ticket_id uuid;
  v_subject text;
  v_refund jsonb;
  v_refund_request_id uuid;
begin
  if p_category not in ('question', 'bug', 'refund', 'other') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_category');
  end if;
  if coalesce(trim(p_message), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'message_required');
  end if;

  v_subject := coalesce(nullif(trim(p_subject), ''), case p_category
    when 'refund' then 'Demande de remboursement'
    when 'bug' then 'Signalement de bug'
    when 'question' then 'Question'
    else 'Autre demande'
  end);

  -- Catégorie remboursement : on réutilise TELLE QUELLE la fonction déjà
  -- éprouvée (migration_33), avec ses propres règles (déjà acheté,
  -- pas de doublon "pending", jeu gratuit non remboursable) — si elle
  -- refuse, on refuse aussi la création du ticket (jamais de ticket
  -- orphelin sans vraie demande de remboursement derrière).
  if p_category = 'refund' then
    if p_game_id is null then
      return jsonb_build_object('ok', false, 'reason', 'game_required');
    end if;
    v_refund := public.request_refund(p_game_id, p_message);
    if not coalesce((v_refund->>'ok')::boolean, false) then
      return v_refund;
    end if;
    v_refund_request_id := (v_refund->>'requestId')::uuid;
  end if;

  insert into public.support_tickets (user_id, category, subject, refund_request_id)
    values (auth.uid(), p_category, v_subject, v_refund_request_id)
    returning id into v_ticket_id;

  insert into public.support_ticket_messages (ticket_id, sender, message)
    values (v_ticket_id, 'player', trim(p_message));

  return jsonb_build_object('ok', true, 'ticketId', v_ticket_id, 'meetsPolicy', v_refund->>'meetsPolicy');
end;
$$;
grant execute on function public.create_support_ticket(text, text, text, uuid) to authenticated;

-- ---- Répondre dans un ticket (joueur si c'est le sien et qu'il est
-- encore ouvert, admin toujours) ----
create or replace function public.send_ticket_message(p_ticket_id uuid, p_message text)
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
  if coalesce(trim(p_message), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'message_required');
  end if;
  insert into public.support_ticket_messages (ticket_id, sender, message)
    values (p_ticket_id, case when v_is_admin then 'admin' else 'player' end, trim(p_message));
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.send_ticket_message(uuid, text) to authenticated;

-- ---- Fermeture manuelle par l'admin (tickets Question/Bug/Autre — les
-- tickets Remboursement se ferment tout seuls, voir admin_process_refund
-- plus bas) ----
create or replace function public.admin_close_ticket(p_ticket_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_current_user_admin() then
    raise exception 'forbidden';
  end if;
  update public.support_tickets set status = 'closed', closed_at = now() where id = p_ticket_id;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_close_ticket(uuid) to authenticated;

-- ---- Liste admin (tous les tickets, ouverts en premier) ----
create or replace function public.admin_list_support_tickets()
returns table(
  id uuid, user_email text, category text, subject text, status text,
  refund_request_id uuid, created_at timestamptz, closed_at timestamptz
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
    select t.id, u.email::text, t.category, t.subject, t.status, t.refund_request_id, t.created_at, t.closed_at
    from public.support_tickets t
    join auth.users u on u.id = t.user_id
    order by (t.status = 'open') desc, t.created_at desc;
end;
$$;
grant execute on function public.admin_list_support_tickets() to authenticated;

-- ---- admin_process_refund étendue : réponse auto + fermeture du ticket
-- lié, si cette demande de remboursement vient d'un ticket (sinon
-- comportement 100% identique à avant, migration_33) ----
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

  if p_approve then
    update public.profiles set credits = credits + v_amount where id = v_buyer_id;
    update public.profiles set credits = credits - v_amount where id = v_seller_id;
    insert into public.credit_transactions (user_id, amount, reason) values (v_buyer_id, v_amount, 'refund_received');
    insert into public.credit_transactions (user_id, amount, reason) values (v_seller_id, -v_amount, 'refund_clawback');
    delete from public.game_purchases where id = v_purchase_id;
  end if;

  select id into v_ticket_id from public.support_tickets where refund_request_id = p_request_id;
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

-- ---- Realtime (même principe que migration_34) ----
do $$
begin
  alter publication supabase_realtime add table public.support_tickets;
exception when duplicate_object then null;
end $$;
do $$
begin
  alter publication supabase_realtime add table public.support_ticket_messages;
exception when duplicate_object then null;
end $$;
