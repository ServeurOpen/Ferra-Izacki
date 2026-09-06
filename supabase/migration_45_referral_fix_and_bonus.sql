-- ============================================================
-- Izacki — Migration 45 : corrige une régression réelle + ajoute le bonus
-- filleul (06/09/2026, demande explicite : "le parrainage donne 20
-- crédits au joueur et 10 à celui qui rejoint").
--
-- 🐞 BUG TROUVÉ EN COURS DE ROUTE (pas demandé, découvert en préparant ce
-- changement, attribution corrigée après une revue de code adversariale) :
-- migration_31_fixes.sql (05/09/2026, "jour 7 : 25 -> 15 crédits") a été
-- LA PREMIÈRE à remplacer claim_daily_reward() par une version qui NE
-- CONTENAIT PLUS le versement au parrain ajouté par migration_18 — un
-- `create or replace` sur la même fonction remplace TOUT son corps, et
-- cette version-là avait été réécrite à partir de zéro sans reporter ce
-- bloc. migration_32 (rééquilibrage 6/20, juste après) n'a fait que
-- reporter ce corps déjà cassé en changeant les montants. Conséquence
-- réelle : depuis migration_31, AUCUN parrain n'a perçu ses crédits de
-- parrainage, même quand un filleul atteignait bien le jour 3 —
-- silencieusement, sans erreur visible nulle part. Cette migration
-- restaure le versement au parrain (montants actuels 6/20, pas les
-- anciens 5/25 de migration_18) ET ajoute le nouveau bonus filleul.
--
-- Le filleul touche son bonus au MÊME moment que le parrain (jour 3 de
-- SA récompense quotidienne) — un seul point de déclenchement à
-- maintenir, cohérent avec "dès qu'il atteint son 3e jour" déjà annoncé
-- au joueur. Les plafonds anti-abus (5 parrainages récompensés/semaine
-- par parrain, 3 par appareil/IP) restent inchangés et s'appliquent
-- toujours — le bonus filleul suit exactement la même autorisation que
-- le bonus parrain (les deux sont versés ensemble ou aucun des deux,
-- jamais l'un sans l'autre).
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_44.
-- ============================================================

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
  v_referral_amount int := 20;      -- versé au PARRAIN
  v_referred_bonus int := 10;       -- 06/09/2026 : versé au FILLEUL (nouveau)
  v_referral_weekly_cap int := 5;   -- par parrain, par semaine glissante
  v_referral_id_cap int := 3;       -- par appareil / par IP, à vie
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
  -- Montants actuels (migration_32, 05/09/2026) : 6 crédits/jour, 20 le jour 7.
  v_amount := case when v_new_day = 7 then 20 else 6 end;

  update public.profiles
    set credits = credits + v_amount, daily_reward_day = v_new_day, daily_reward_last_claimed_at = now()
    where id = auth.uid()
    returning credits into v_new_balance;

  insert into public.credit_transactions (user_id, amount, reason)
    values (auth.uid(), v_amount, 'daily_reward_day_' || v_new_day);

  -- Parrainage : versé au parrain (+20) ET au filleul (+10, nouveau) la
  -- toute première fois que CE filleul atteint le jour 3, sous réserve
  -- des plafonds anti-abus. `referral_rewards.referred_id` étant UNIQUE,
  -- un filleul ne peut de toute façon déclencher ceci qu'une seule fois
  -- dans sa vie, même si ce code était rappelé par erreur.
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
        -- Bonus filleul (06/09/2026, nouveau) — versé au compte qui vient
        -- d'appeler cette fonction (auth.uid() = le filleul lui-même).
        update public.profiles set credits = credits + v_referred_bonus where id = auth.uid();
        insert into public.credit_transactions (user_id, amount, reason)
          values (auth.uid(), v_referred_bonus, 'parrainage_bonus_filleul');
        v_new_balance := v_new_balance + v_referred_bonus;
      end if;
    end if;
  end if;

  return jsonb_build_object('claimed', true, 'day', v_new_day, 'amount', v_amount, 'newBalance', v_new_balance);
end;
$$;
grant execute on function public.claim_daily_reward() to authenticated;
