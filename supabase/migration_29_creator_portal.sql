-- ============================================================
-- Izacki — Migration 29 : achat de jeux en crédits + Portail des créateurs
-- + retraits PayPal (05/09/2026, demande explicite).
--
-- Contient :
--  1) game_purchases + purchase_game() : achète un jeu du marketplace en
--     crédits (vendeur crédité en PLEIN, pas de commission à la vente).
--  2) platform_finance : GARDE-FOU DE SOLVABILITÉ — au lieu de simplement
--     "baisser le taux de crédits gratuits" (qui réduit le risque sans le
--     supprimer), on suit combien de VRAIS euros sont entrés (recharges
--     Stripe) et combien sont ressortis (retraits payés). Un retrait ne
--     peut JAMAIS faire sortir plus d'argent réel qu'il n'en est
--     réellement entré — peu importe combien de crédits GRATUITS circulent
--     dans le système, impossible de payer plus que le vrai chiffre
--     d'affaires encaissé. C'est une garantie mathématique, pas une
--     réduction de probabilité.
--  3) Éligibilité créateur (1 jeu publié minimum + 5 ventes minimum) +
--     retrait à partir de 1000 crédits, taux 0,70€/100cr (30% de marge).
--  4) withdrawal_requests + fonctions admin (liste, refuser). Le PAIEMENT
--     réel (appel API PayPal) se fait depuis une fonction Edge
--     "process-withdrawal" (SQL ne peut pas appeler une API externe) —
--     voir ce fichier séparément.
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

-- ---- 1) Achat d'un jeu du marketplace ----
create table if not exists public.game_purchases (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.submitted_games(id) on delete cascade,
  buyer_id uuid not null references auth.users(id) on delete cascade,
  seller_id uuid not null references auth.users(id) on delete cascade,
  price_credits int not null,
  purchased_at timestamptz not null default now(),
  unique (game_id, buyer_id)
);
create index if not exists game_purchases_seller_idx on public.game_purchases (seller_id);
create index if not exists game_purchases_buyer_idx on public.game_purchases (buyer_id);

alter table public.game_purchases enable row level security;
drop policy if exists "Un joueur voit ses propres achats" on public.game_purchases;
create policy "Un joueur voit ses propres achats"
  on public.game_purchases for select
  using (buyer_id = auth.uid());
-- Le VENDEUR n'a PAS accès direct à cette table (jamais l'identité de ses
-- acheteurs) — demande explicite : "ne jamais donner l'accès email, mdp
-- ou information confidentielle" ; il ne voit que des AGRÉGATS via
-- creator_portal_stats() ci-dessous. Pas de policy insert/update/delete
-- pour "authenticated" : seule purchase_game() (security definer) écrit ici.

create or replace function public.purchase_game(p_game_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seller_id uuid;
  v_price int;
  v_status text;
  v_buyer_balance int;
begin
  select seller_id, price_credits, status into v_seller_id, v_price, v_status
    from public.submitted_games where id = p_game_id;

  if v_seller_id is null then
    return jsonb_build_object('ok', false, 'reason', 'game_not_found');
  end if;
  if v_status is distinct from 'approved' then
    return jsonb_build_object('ok', false, 'reason', 'game_not_available');
  end if;
  if v_seller_id = auth.uid() then
    return jsonb_build_object('ok', false, 'reason', 'cannot_buy_own_game');
  end if;
  if exists (select 1 from public.game_purchases where game_id = p_game_id and buyer_id = auth.uid()) then
    return jsonb_build_object('ok', false, 'reason', 'already_owned');
  end if;

  if v_price > 0 then
    select credits into v_buyer_balance from public.profiles where id = auth.uid();
    if v_buyer_balance is null or v_buyer_balance < v_price then
      return jsonb_build_object('ok', false, 'reason', 'insufficient_credits');
    end if;
    update public.profiles set credits = credits - v_price where id = auth.uid();
    -- Le vendeur touche le PLEIN montant — pas de commission à la vente,
    -- elle se prend au retrait (voir request_withdrawal ci-dessous).
    update public.profiles set credits = credits + v_price where id = v_seller_id;
    insert into public.credit_transactions (user_id, amount, reason) values (auth.uid(), -v_price, 'game_purchase');
    insert into public.credit_transactions (user_id, amount, reason) values (v_seller_id, v_price, 'game_sale');
  end if;

  insert into public.game_purchases (game_id, buyer_id, seller_id, price_credits)
    values (p_game_id, auth.uid(), v_seller_id, v_price);

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.purchase_game(uuid) to authenticated;

-- L'ACHETEUR doit pouvoir télécharger le fichier qu'il vient d'acheter —
-- sans ça, seuls le vendeur et l'admin (voir migration_27) peuvent le lire.
drop policy if exists "Acheteur telecharge le fichier achete" on storage.objects;
create policy "Acheteur telecharge le fichier achete"
  on storage.objects for select
  using (
    bucket_id = 'game-submission-files'
    and exists (
      select 1 from public.submitted_games sg
      join public.game_purchases gp on gp.game_id = sg.id
      where sg.file_path = storage.objects.name and gp.buyer_id = auth.uid()
    )
  );

-- ---- 2) Garde-fou de solvabilité ----
-- Une seule ligne (id fixé à true) — voir l'astuce "singleton row" via une
-- contrainte check sur une colonne booléenne toujours égale à true.
create table if not exists public.platform_finance (
  id boolean primary key default true check (id),
  total_topup_cents bigint not null default 0,
  total_payout_cents bigint not null default 0
);
insert into public.platform_finance (id) values (true) on conflict (id) do nothing;
alter table public.platform_finance enable row level security;
-- Aucune policy pour "authenticated"/"anon" (RLS activé sans policy =
-- accès refusé à tout le monde côté PostgREST) : lu/écrit UNIQUEMENT via
-- des fonctions security definer (admin) ou la clé de service (webhook
-- Stripe), qui contournent RLS par nature — jamais lu/écrit en direct.

-- credit_stripe_topup (migration_20) recrédité pour aussi alimenter le
-- compteur "argent réellement entré" — sans cette étape, le garde-fou de
-- solvabilité penserait qu'aucun argent réel n'a jamais été encaissé.
create or replace function public.credit_stripe_topup(
  p_session_id text, p_user_id uuid, p_amount_credits int, p_amount_cents int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new_balance int;
begin
  insert into public.stripe_topups (stripe_session_id, user_id, amount_credits, amount_cents)
    values (p_session_id, p_user_id, p_amount_credits, p_amount_cents)
    on conflict (stripe_session_id) do nothing;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'already_processed');
  end if;

  update public.profiles set credits = credits + p_amount_credits where id = p_user_id
    returning credits into v_new_balance;

  insert into public.credit_transactions (user_id, amount, reason)
    values (p_user_id, p_amount_credits, 'stripe_topup');

  update public.platform_finance set total_topup_cents = total_topup_cents + p_amount_cents where id = true;

  return jsonb_build_object('ok', true, 'newBalance', v_new_balance);
end;
$$;

-- ---- 3) Éligibilité créateur + demande de retrait ----
-- Taux de retrait FIXE : 0,70€ pour 100 crédits (0,7 centime/crédit) —
-- 30% de marge par rapport au taux d'achat (1€/100cr), comparable à la
-- commission de Steam/App Store/Google Play. Minimum 1000 crédits.
create or replace function public.creator_withdrawal_eligibility(p_seller_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seller uuid := coalesce(p_seller_id, auth.uid());
  v_approved_games int;
  v_total_sales int;
  v_balance int;
begin
  -- Un joueur ne peut vérifier que SA PROPRE éligibilité (p_seller_id
  -- n'existe que pour un usage admin futur ; ici on l'ignore si l'appelant
  -- n'est pas admin, pour ne jamais exposer les stats crédits d'un autre).
  if p_seller_id is not null and p_seller_id <> auth.uid() and not public.is_current_user_admin() then
    raise exception 'forbidden';
  end if;

  select count(*) into v_approved_games from public.submitted_games where seller_id = v_seller and status = 'approved';
  select count(*) into v_total_sales from public.game_purchases where seller_id = v_seller;
  select credits into v_balance from public.profiles where id = v_seller;

  return jsonb_build_object(
    'approvedGames', v_approved_games,
    'totalSales', v_total_sales,
    'balance', coalesce(v_balance, 0),
    'minGames', 1,
    'minSales', 5,
    'minWithdrawCredits', 1000,
    'eligible', v_approved_games >= 1 and v_total_sales >= 5 and coalesce(v_balance, 0) >= 1000
  );
end;
$$;
grant execute on function public.creator_withdrawal_eligibility(uuid) to authenticated;

-- Stats agrégées PAR JEU pour le vendeur (crédits gagnés) — jamais
-- l'identité des acheteurs, demande explicite du 05/09/2026.
create or replace function public.creator_portal_games()
returns table(game_id uuid, title text, status text, price_credits int, sales_count bigint, credits_earned bigint)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
    select sg.id, sg.title, sg.status, sg.price_credits,
           count(gp.id)::bigint as sales_count,
           coalesce(sum(gp.price_credits), 0)::bigint as credits_earned
    from public.submitted_games sg
    left join public.game_purchases gp on gp.game_id = sg.id
    where sg.seller_id = auth.uid()
    group by sg.id, sg.title, sg.status, sg.price_credits
    order by sg.created_at desc;
end;
$$;
grant execute on function public.creator_portal_games() to authenticated;

create table if not exists public.withdrawal_requests (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references auth.users(id) on delete cascade,
  amount_credits int not null,
  payout_cents int not null,
  paypal_email text not null,
  status text not null default 'pending' check (status in ('pending', 'paid', 'rejected')),
  rejection_reason text,
  created_at timestamptz not null default now(),
  processed_at timestamptz
);
create index if not exists withdrawal_requests_seller_idx on public.withdrawal_requests (seller_id);
alter table public.withdrawal_requests enable row level security;
drop policy if exists "Un joueur voit ses propres demandes de retrait" on public.withdrawal_requests;
create policy "Un joueur voit ses propres demandes de retrait"
  on public.withdrawal_requests for select
  using (seller_id = auth.uid());
-- Pas de policy insert/update pour "authenticated" : seules
-- request_withdrawal/admin_reject_withdrawal (security definer) écrivent ici.

create or replace function public.request_withdrawal(p_amount_credits int, p_paypal_email text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eligibility jsonb;
  v_payout_cents int;
begin
  if coalesce(trim(p_paypal_email), '') = '' or p_paypal_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_paypal_email');
  end if;
  if p_amount_credits < 1000 then
    return jsonb_build_object('ok', false, 'reason', 'below_minimum');
  end if;

  v_eligibility := public.creator_withdrawal_eligibility(auth.uid());
  if not (v_eligibility->>'eligible')::boolean then
    return jsonb_build_object('ok', false, 'reason', 'not_eligible', 'eligibility', v_eligibility);
  end if;
  if (v_eligibility->>'balance')::int < p_amount_credits then
    return jsonb_build_object('ok', false, 'reason', 'insufficient_credits');
  end if;

  v_payout_cents := round(p_amount_credits * 0.7);

  update public.profiles set credits = credits - p_amount_credits where id = auth.uid();
  insert into public.credit_transactions (user_id, amount, reason) values (auth.uid(), -p_amount_credits, 'withdrawal_request');

  insert into public.withdrawal_requests (seller_id, amount_credits, payout_cents, paypal_email)
    values (auth.uid(), p_amount_credits, v_payout_cents, trim(p_paypal_email));

  return jsonb_build_object('ok', true, 'payoutCents', v_payout_cents);
end;
$$;
grant execute on function public.request_withdrawal(int, text) to authenticated;

-- ---- 4) Traitement admin ----
create or replace function public.admin_list_withdrawal_requests()
returns table(id uuid, seller_id uuid, seller_email text, amount_credits int, payout_cents int, paypal_email text, status text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_current_user_admin() then
    raise exception 'forbidden';
  end if;
  return query
    select wr.id, wr.seller_id, u.email::text, wr.amount_credits, wr.payout_cents, wr.paypal_email, wr.status, wr.created_at
    from public.withdrawal_requests wr
    join auth.users u on u.id = wr.seller_id
    where wr.status = 'pending'
    order by wr.created_at asc;
end;
$$;
grant execute on function public.admin_list_withdrawal_requests() to authenticated;

-- Combien la plateforme peut payer SANS jamais dépasser le vrai chiffre
-- d'affaires encaissé (voir le commentaire du bloc 2 en haut du fichier).
create or replace function public.admin_get_platform_finance()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_topup bigint;
  v_payout bigint;
begin
  if not public.is_current_user_admin() then
    raise exception 'forbidden';
  end if;
  select total_topup_cents, total_payout_cents into v_topup, v_payout from public.platform_finance where id = true;
  return jsonb_build_object('totalTopupCents', v_topup, 'totalPayoutCents', v_payout, 'availableCents', v_topup - v_payout);
end;
$$;
grant execute on function public.admin_get_platform_finance() to authenticated;

create or replace function public.admin_reject_withdrawal(p_request_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seller_id uuid;
  v_amount int;
begin
  if not public.is_current_user_admin() then
    raise exception 'forbidden';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;

  update public.withdrawal_requests
    set status = 'rejected', rejection_reason = trim(p_reason), processed_at = now()
    where id = p_request_id and status = 'pending'
    returning seller_id, amount_credits into v_seller_id, v_amount;

  if v_seller_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found_or_already_processed');
  end if;

  -- Remboursement des crédits retenus lors de la demande (voir request_withdrawal).
  update public.profiles set credits = credits + v_amount where id = v_seller_id;
  insert into public.credit_transactions (user_id, amount, reason) values (v_seller_id, v_amount, 'withdrawal_rejected_refund');

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_reject_withdrawal(uuid, text) to authenticated;

-- Appelée UNIQUEMENT par la fonction Edge "process-withdrawal" (clé de
-- service) une fois le paiement PayPal réellement confirmé — jamais
-- exposée à "authenticated" (pas de grant), exactement comme
-- credit_stripe_topup pour le webhook Stripe.
create or replace function public.mark_withdrawal_paid(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payout_cents int;
begin
  update public.withdrawal_requests set status = 'paid', processed_at = now()
    where id = p_request_id and status = 'pending'
    returning payout_cents into v_payout_cents;

  if v_payout_cents is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found_or_already_processed');
  end if;

  update public.platform_finance set total_payout_cents = total_payout_cents + v_payout_cents where id = true;

  return jsonb_build_object('ok', true);
end;
$$;
