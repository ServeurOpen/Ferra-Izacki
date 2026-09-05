-- ============================================================
-- Izacki — Migration 33 : demandes de remboursement marketplace
-- (05/09/2026, demande explicite).
--
-- Règle anti-abus (informative pour l'admin, jamais bloquante — "il peut
-- essayer, ce sera sûrement refusé") : un achat est présumé NON éligible
-- si le joueur a joué plus d'1h OU le possède depuis plus de 7 jours,
-- mais la demande reste toujours envoyable — c'est TOI qui trancherais
-- (jamais automatique, tu gardes le contrôle du solde).
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

create table if not exists public.refund_requests (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null references public.game_purchases(id) on delete cascade,
  buyer_id uuid not null references auth.users(id) on delete cascade,
  seller_id uuid not null references auth.users(id) on delete cascade,
  game_id uuid not null references public.submitted_games(id) on delete cascade,
  amount_credits int not null,
  buyer_message text,
  playtime_secs_at_request bigint not null default 0,
  days_owned_at_request numeric not null default 0,
  meets_policy boolean not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  rejection_reason text,
  created_at timestamptz not null default now(),
  processed_at timestamptz
);
-- Empêche 2 demandes "pending" pour le même achat, sans bloquer une
-- nouvelle demande après un refus (index PARTIEL, pas une contrainte
-- unique classique qui viserait aussi les lignes rejected/approved).
drop index if exists refund_requests_one_pending_idx;
create unique index refund_requests_one_pending_idx on public.refund_requests (purchase_id) where status = 'pending';

create index if not exists refund_requests_seller_idx on public.refund_requests (seller_id);
alter table public.refund_requests enable row level security;
drop policy if exists "Un joueur voit ses propres demandes de remboursement" on public.refund_requests;
create policy "Un joueur voit ses propres demandes de remboursement"
  on public.refund_requests for select
  using (buyer_id = auth.uid());
-- Pas de policy insert/update pour "authenticated" : seules
-- request_refund/admin_process_refund (security definer) écrivent ici.

create or replace function public.request_refund(p_game_id uuid, p_message text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_purchase record;
  v_playtime bigint;
  v_days numeric;
  v_meets boolean;
  v_request_id uuid;
begin
  select id, seller_id, price_credits, purchased_at into v_purchase
    from public.game_purchases where game_id = p_game_id and buyer_id = auth.uid();
  if v_purchase.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_purchased');
  end if;
  if exists (select 1 from public.refund_requests where purchase_id = v_purchase.id and status = 'pending') then
    return jsonb_build_object('ok', false, 'reason', 'already_pending');
  end if;
  if v_purchase.price_credits = 0 then
    return jsonb_build_object('ok', false, 'reason', 'free_game_not_refundable');
  end if;

  select coalesce(total_secs, 0) into v_playtime
    from public.game_stats where user_id = auth.uid() and game_id = p_game_id::text;
  v_playtime := coalesce(v_playtime, 0);
  v_days := extract(epoch from (now() - v_purchase.purchased_at)) / 86400;
  v_meets := v_playtime <= 3600 and v_days <= 7;

  insert into public.refund_requests (
    purchase_id, buyer_id, seller_id, game_id, amount_credits, buyer_message,
    playtime_secs_at_request, days_owned_at_request, meets_policy
  ) values (
    v_purchase.id, auth.uid(), v_purchase.seller_id, p_game_id, v_purchase.price_credits, nullif(trim(p_message), ''),
    v_playtime, v_days, v_meets
  ) returning id into v_request_id;

  return jsonb_build_object('ok', true, 'requestId', v_request_id, 'meetsPolicy', v_meets);
end;
$$;
grant execute on function public.request_refund(uuid, text) to authenticated;

create or replace function public.admin_list_refund_requests()
returns table(
  id uuid, buyer_email text, seller_email text, game_title text, amount_credits int,
  buyer_message text, playtime_secs_at_request bigint, days_owned_at_request numeric,
  meets_policy boolean, created_at timestamptz
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
    select rr.id, bu.email::text, su.email::text, sg.title, rr.amount_credits,
           rr.buyer_message, rr.playtime_secs_at_request, rr.days_owned_at_request,
           rr.meets_policy, rr.created_at
    from public.refund_requests rr
    join auth.users bu on bu.id = rr.buyer_id
    join auth.users su on su.id = rr.seller_id
    join public.submitted_games sg on sg.id = rr.game_id
    where rr.status = 'pending'
    order by rr.created_at asc;
end;
$$;
grant execute on function public.admin_list_refund_requests() to authenticated;

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
    -- Remboursement : l'acheteur récupère ses crédits, le vendeur les rend
    -- (peut passer en négatif si déjà dépensés/retirés — cas rare, à
    -- surveiller manuellement plutôt que bloquer le remboursement du joueur).
    update public.profiles set credits = credits + v_amount where id = v_buyer_id;
    update public.profiles set credits = credits - v_amount where id = v_seller_id;
    insert into public.credit_transactions (user_id, amount, reason) values (v_buyer_id, v_amount, 'refund_received');
    insert into public.credit_transactions (user_id, amount, reason) values (v_seller_id, -v_amount, 'refund_clawback');
    -- Révoque l'accès au fichier (RLS storage) et permet un futur rachat.
    delete from public.game_purchases where id = v_purchase_id;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_process_refund(uuid, boolean, text) to authenticated;
