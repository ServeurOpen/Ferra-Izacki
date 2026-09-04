-- ============================================================
-- Izacki — Migration 18 : parrainage (05/09/2026, demande explicite :
-- "fais tout ce comment on peut gagner des crédits sauf le parrainage
-- [...] plafond IP appareil [...] sur les 3 premiers jours [...] gagnable
-- par semaine").
--
-- Règles anti-abus retenues (discutées en chat, aucune n'est parfaite
-- seule mais combinées ça rend la fraude peu rentable) :
--  1. Le parrain ne touche sa récompense QUE la première fois que le
--     filleul atteint le JOUR 3 de récompense quotidienne (pas juste
--     "compte créé") — un faux compte doit donc vraiment être utilisé
--     3 jours de suite pour rapporter quoi que ce soit.
--  2. Plafond de 3 parrainages récompensés par appareil ET par IP
--     (les DEUX plafonds s'appliquent, tous parrains confondus — sinon
--     quelqu'un pourrait créer 10 comptes sur sa propre machine).
--  3. Plafond de 5 parrainages récompensés par semaine ET par parrain.
-- Montant choisi : 20 crédits par parrainage réussi (ajustable — aucun
-- montant précis n'avait été donné, à mi-chemin entre le quotidien normal
-- (5) et le palier du jour 7 (25)).
--
-- `signup_device_id` : identifiant aléatoire généré côté client (site ET
-- Launcher, voir assets/js/auth.js / Launcher/src/supabase.ts), persisté
-- en local — contournable (vider les données du navigateur, autre
-- appareil) mais bloque le cas naïf "je crée plusieurs comptes d'affilée
-- sur ma machine".
-- `signup_ip` : capturée côté serveur (fonction Edge record-signup-ip,
-- lit l'en-tête x-forwarded-for) — best-effort, une IP peut être partagée
-- (4G, VPN, box familiale), connu et accepté comme limite.
-- Les deux ne sont écrits qu'UNE SEULE FOIS par compte (via coalesce),
-- jamais modifiables ensuite même par le propriétaire du compte, pour
-- qu'un joueur ne puisse pas se "réinitialiser" son propre plafond.
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_15 et migration_17.
-- ============================================================

alter table public.profiles add column if not exists referred_by uuid references auth.users(id);
alter table public.profiles add column if not exists signup_device_id text;
alter table public.profiles add column if not exists signup_ip text;

create table if not exists public.referral_rewards (
  id uuid primary key default gen_random_uuid(),
  referrer_id uuid not null references auth.users(id) on delete cascade,
  referred_id uuid not null unique references auth.users(id) on delete cascade,
  device_id text,
  ip text,
  amount integer not null,
  created_at timestamptz not null default now()
);
create index if not exists referral_rewards_referrer_idx on public.referral_rewards (referrer_id, created_at);
create index if not exists referral_rewards_device_idx on public.referral_rewards (device_id);
create index if not exists referral_rewards_ip_idx on public.referral_rewards (ip);

alter table public.referral_rewards enable row level security;
drop policy if exists "Un joueur voit les parrainages ou il est parrain" on public.referral_rewards;
create policy "Un joueur voit les parrainages ou il est parrain"
  on public.referral_rewards for select
  using (auth.uid() = referrer_id);
-- Pas de policy insert/update : seule la fonction claim_daily_reward
-- (security definer) y écrit.

-- ---- Associer un compte au parrain qui a partagé son tag, UNE FOIS ----
-- Volontairement séparé de la création de compte (qui se fait sans
-- session active) : appelé juste après le tout premier signUp() réussi,
-- une fois authentifié.
create or replace function public.set_referral(p_username text, p_number bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_referrer_id uuid;
  v_current uuid;
begin
  select referred_by into v_current from public.profiles where id = auth.uid();
  if v_current is not null then
    return jsonb_build_object('ok', false, 'reason', 'already_set');
  end if;

  select id into v_referrer_id from public.profiles
    where lower(username) = lower(p_username) and player_number = p_number
    limit 1;
  if v_referrer_id is null then
    return jsonb_build_object('ok', false, 'reason', 'tag_not_found');
  end if;
  if v_referrer_id = auth.uid() then
    return jsonb_build_object('ok', false, 'reason', 'self_referral');
  end if;

  update public.profiles set referred_by = v_referrer_id where id = auth.uid();
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.set_referral(text, bigint) to authenticated;

-- ---- Empreinte appareil / IP — écrites une seule fois (coalesce) ----
create or replace function public.record_signup_device(p_device_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.profiles set signup_device_id = coalesce(signup_device_id, p_device_id) where id = auth.uid();
end;
$$;
grant execute on function public.record_signup_device(text) to authenticated;

create or replace function public.record_signup_ip(p_ip text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.profiles set signup_ip = coalesce(signup_ip, p_ip) where id = auth.uid();
end;
$$;
grant execute on function public.record_signup_ip(text) to authenticated;

-- ---- claim_daily_reward, complétée avec le versement au parrain ----
-- Remplace entièrement la version de migration_15 (même nom de fonction).
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
  v_referrer uuid;
  v_device text;
  v_ip text;
  v_referral_amount int := 20;
  v_referral_weekly_cap int := 5;
  v_referral_id_cap int := 3;
  v_already_rewarded boolean;
  v_device_count int;
  v_ip_count int;
  v_weekly_count int;
begin
  select daily_reward_last_claimed_at, daily_reward_day, referred_by, signup_device_id, signup_ip
    into v_last, v_day, v_referrer, v_device, v_ip
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

  -- Parrainage : versé au parrain la toute première fois que CE filleul
  -- atteint le jour 3, sous réserve des plafonds anti-abus (appareil, IP,
  -- hebdomadaire par parrain). `referral_rewards.referred_id` étant
  -- UNIQUE, un filleul ne peut de toute façon déclencher ceci qu'une
  -- seule fois dans sa vie, même si le code était rappelé par erreur.
  if v_new_day = 3 and v_referrer is not null then
    select exists(select 1 from public.referral_rewards where referred_id = auth.uid()) into v_already_rewarded;
    if not v_already_rewarded then
      select count(*) into v_device_count from public.referral_rewards where v_device is not null and device_id = v_device;
      select count(*) into v_ip_count from public.referral_rewards where v_ip is not null and ip = v_ip;
      select count(*) into v_weekly_count from public.referral_rewards
        where referrer_id = v_referrer and created_at > now() - interval '7 days';

      if (v_device is null or v_device_count < v_referral_id_cap)
         and (v_ip is null or v_ip_count < v_referral_id_cap)
         and v_weekly_count < v_referral_weekly_cap then
        insert into public.referral_rewards (referrer_id, referred_id, device_id, ip, amount)
          values (v_referrer, auth.uid(), v_device, v_ip, v_referral_amount);
        update public.profiles set credits = credits + v_referral_amount where id = v_referrer;
        insert into public.credit_transactions (user_id, amount, reason)
          values (v_referrer, v_referral_amount, 'parrainage');
      end if;
    end if;
  end if;

  return jsonb_build_object('claimed', true, 'day', v_new_day, 'amount', v_amount, 'newBalance', v_new_balance);
end;
$$;
grant execute on function public.claim_daily_reward() to authenticated;
