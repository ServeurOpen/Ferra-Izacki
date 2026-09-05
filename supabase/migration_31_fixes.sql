-- ============================================================
-- Izacki — Migration 31 : 2 correctifs (05/09/2026).
--
-- 1) "Erreur : column sg.price_cents does not exist" dans la modération
--    des jeux — admin_list_pending_games() n'avait jamais été recréée
--    après le renommage price_cents -> price_credits (migration_28) : le
--    correctif donné sur le moment ne contenait QUE la commande de
--    renommage de colonne, pas la recréation de cette fonction.
-- 2) Récompense quotidienne, jour 7 : 25 -> 15 crédits (demande explicite).
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

drop function if exists public.admin_list_pending_games();
create function public.admin_list_pending_games()
returns table(
  id uuid, seller_id uuid, seller_email text, title text, description text,
  price_credits int, file_type text, file_path text, file_size_bytes bigint,
  screenshot_paths text[], created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select lower(trim(au.email)) from auth.users au where au.id = auth.uid()) is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  return query
    select sg.id, sg.seller_id, u.email::text, sg.title, sg.description, sg.price_credits,
           sg.file_type, sg.file_path, sg.file_size_bytes, sg.screenshot_paths, sg.created_at
    from public.submitted_games sg
    join auth.users u on u.id = sg.seller_id
    where sg.status = 'pending'
    order by sg.created_at asc;
end;
$$;
grant execute on function public.admin_list_pending_games() to authenticated;

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
  -- 05/09/2026, demande explicite : jour 7 ramené de 25 à 15 crédits.
  v_amount := case when v_new_day = 7 then 15 else 5 end;

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
