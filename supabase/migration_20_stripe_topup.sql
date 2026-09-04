-- ============================================================
-- Izacki — Migration 20 : recharge de crédits par carte (Stripe)
-- (05/09/2026, demande explicite : "rajouter le solde d'argent en haut et
-- faire en sorte que le joueur puisse alimenter son solde avec sa carte").
--
-- `stripe_topups` sert d'abord d'IDEMPOTENCE : Stripe peut renvoyer le même
-- événement de webhook plusieurs fois (retry réseau, etc.) — la clé
-- primaire sur `stripe_session_id` garantit qu'une même session de
-- paiement ne peut créditer le joueur qu'UNE seule fois, même si le
-- webhook est appelé 3 fois pour le même paiement.
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_15 (colonne `credits`
-- et table `credit_transactions`).
-- ============================================================

create table if not exists public.stripe_topups (
  stripe_session_id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  amount_credits integer not null,
  amount_cents integer not null,
  created_at timestamptz not null default now()
);
create index if not exists stripe_topups_user_idx on public.stripe_topups (user_id);

alter table public.stripe_topups enable row level security;
drop policy if exists "Un joueur voit ses propres recharges" on public.stripe_topups;
create policy "Un joueur voit ses propres recharges"
  on public.stripe_topups for select
  using (auth.uid() = user_id);
-- Pas de policy insert/update pour "authenticated" : seule la fonction
-- Edge stripe-webhook (clé de service) peut créditer un solde.

-- Appelée UNIQUEMENT par la fonction Edge stripe-webhook (client à
-- privilège de service, jamais exposée à "authenticated") — après
-- confirmation RÉELLE du paiement par Stripe, jamais avant.
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

  return jsonb_build_object('ok', true, 'newBalance', v_new_balance);
end;
$$;
-- Volontairement PAS de "grant execute ... to authenticated" : cette
-- fonction ne doit être appelable que par la clé de service (bypass RLS
-- et grants), jamais directement par un joueur.
