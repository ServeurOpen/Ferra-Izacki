-- ============================================================
-- Izacki — Migration 32 : rééquilibrage de la récompense quotidienne
-- (05/09/2026) — 6 crédits/jour (jours 1-6), 20 crédits le jour 7.
-- Objectif discuté : ~56 crédits/semaine, soit environ 2 mois de
-- connexion quotidienne pour gagner un jeu à 500 crédits gratuitement —
-- assez long pour ne pas cannibaliser les ventes, assez court pour rester
-- motivant. Remplace le 5/25 initial puis le 5/15 intermédiaire.
-- À exécuter UNE FOIS dans Supabase.
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
  -- 05/09/2026 : 6 crédits/jour, 20 crédits le jour 7 (~56/semaine).
  v_amount := case when v_new_day = 7 then 20 else 6 end;

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
