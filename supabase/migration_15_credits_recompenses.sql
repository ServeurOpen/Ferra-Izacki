-- ============================================================
-- Izacki — Migration 15 : crédits + récompense quotidienne + bonus de
-- bienvenue (05/09/2026, demande explicite : "5 crédits/jour, 25 le jour 7",
-- "10 crédits offerts à la première ouverture du launcher").
--
-- Note : le mail de bienvenue automatique et le parrainage par numéro de
-- téléphone ont été abandonnés dans la même conversation (Resend ne peut
-- pas envoyer vers de vrais joueurs sans domaine à nous, et le parrainage
-- sans vérification SMS était trop facile à contourner) — cette migration
-- ne couvre donc QUE les crédits, la récompense quotidienne (jours 1 à 7)
-- et le bonus de bienvenue, tout géré en interne au Launcher, sans email.
--
-- Tout passe par des fonctions "security definer" (jamais un update direct
-- depuis le client) pour qu'un joueur ne puisse pas se créditer lui-même en
-- trafiquant les appels réseau — même logique que add_playtime
-- (migration_5) et verify-admin-password (fonctions Edge).
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

alter table public.profiles add column if not exists credits integer not null default 0;
-- 0 = jamais réclamée. 1 à 7 = jour actuel du cycle hebdomadaire.
alter table public.profiles add column if not exists daily_reward_day smallint not null default 0;
alter table public.profiles add column if not exists daily_reward_last_claimed_at timestamptz;
alter table public.profiles add column if not exists welcome_bonus_claimed boolean not null default false;

-- Historique de tous les mouvements de crédits — sert à la fois d'audit
-- (comprendre d'où vient un solde) et de base pour un futur relevé "mes
-- crédits" côté joueur si besoin un jour.
create table if not exists public.credit_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  amount integer not null,
  reason text not null,
  created_at timestamptz not null default now()
);
create index if not exists credit_transactions_user_idx on public.credit_transactions (user_id);

alter table public.credit_transactions enable row level security;
drop policy if exists "Un joueur voit uniquement son propre historique de credits" on public.credit_transactions;
create policy "Un joueur voit uniquement son propre historique de credits"
  on public.credit_transactions for select
  using (auth.uid() = user_id);
-- Pas de policy insert/update/delete pour "authenticated" : seules les
-- fonctions security definer ci-dessous (qui tournent avec les droits du
-- propriétaire de la fonction, pas de l'appelant) peuvent y écrire.

-- ---- Bonus de bienvenue : +10 crédits, une seule fois par compte ----
create or replace function public.claim_welcome_bonus()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_already boolean;
  v_amount int := 10;
  v_new_balance int;
begin
  select welcome_bonus_claimed into v_already from public.profiles where id = auth.uid();
  if v_already is null then
    return jsonb_build_object('claimed', false, 'reason', 'no_profile');
  end if;
  if v_already then
    return jsonb_build_object('claimed', false, 'reason', 'already_claimed');
  end if;

  update public.profiles
    set credits = credits + v_amount, welcome_bonus_claimed = true
    where id = auth.uid()
    returning credits into v_new_balance;

  insert into public.credit_transactions (user_id, amount, reason)
    values (auth.uid(), v_amount, 'welcome_bonus');

  return jsonb_build_object('claimed', true, 'amount', v_amount, 'newBalance', v_new_balance);
end;
$$;
grant execute on function public.claim_welcome_bonus() to authenticated;

-- ---- Récompense quotidienne : 5 crédits/jour, 25 le jour 7, cycle sur 7
-- jours qui repart à 1. Une fenêtre de 20h (pas 24h pile) évite qu'un
-- joueur qui se connecte un peu plus tôt chaque jour se retrouve bloqué ;
-- au-delà de 48h sans réclamer, la série repart à zéro (jour 1). ----
create or replace function public.claim_daily_reward()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_last timestamptz;
  v_day smallint;
  v_new_day smallint;
  v_amount int;
  v_new_balance int;
begin
  select daily_reward_last_claimed_at, daily_reward_day into v_last, v_day
    from public.profiles where id = auth.uid();
  if v_day is null then
    return jsonb_build_object('claimed', false, 'reason', 'no_profile');
  end if;

  if v_last is not null and now() - v_last < interval '20 hours' then
    return jsonb_build_object(
      'claimed', false, 'reason', 'too_soon',
      'nextAvailableAt', v_last + interval '20 hours'
    );
  end if;

  if v_last is not null and now() - v_last <= interval '48 hours' and v_day > 0 then
    v_new_day := case when v_day >= 7 then 1 else v_day + 1 end;
  else
    v_new_day := 1;
  end if;
  v_amount := case when v_new_day = 7 then 25 else 5 end;

  update public.profiles
    set credits = credits + v_amount, daily_reward_day = v_new_day, daily_reward_last_claimed_at = now()
    where id = auth.uid()
    returning credits into v_new_balance;

  insert into public.credit_transactions (user_id, amount, reason)
    values (auth.uid(), v_amount, 'daily_reward_day_' || v_new_day);

  return jsonb_build_object('claimed', true, 'day', v_new_day, 'amount', v_amount, 'newBalance', v_new_balance);
end;
$$;
grant execute on function public.claim_daily_reward() to authenticated;
