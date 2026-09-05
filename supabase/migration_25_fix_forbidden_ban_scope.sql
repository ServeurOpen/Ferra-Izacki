-- ============================================================
-- Izacki — Migration 25 : correctif "Échec : forbidden" lors d'un ban
-- depuis le SITE (05/09/2026) — la vérification admin de admin_ban_user
-- (et par cohérence, des 4 autres fonctions "Actions admin") comparait
-- l'email en clair et sensible à la casse/aux espaces
-- ("v_caller_email is distinct from 'ferra.izacki@gmail.com'"), alors que
-- CÔTÉ CLIENT la même vérification normalise toujours avec
-- .trim().toLowerCase() (voir isAdminSession dans le Launcher et
-- ferraIsAdminEmail sur le site) — un email stocké avec une casse ou un
-- espace différent passait donc le contrôle visuel mais échouait côté
-- serveur. Ce correctif applique la même normalisation partout.
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('admin_ban_user', 'admin_unban_user', 'admin_list_bans', 'admin_grant_credits', 'admin_grant_credits_all')
  loop
    execute format('drop function if exists %s cascade', r.sig);
  end loop;
end $$;

create function public.admin_grant_credits(p_target_user_id uuid, p_amount int, p_reason text default 'concours')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_email text;
  v_new_balance int;
begin
  select lower(trim(email)) into v_caller_email from auth.users where id = auth.uid();
  if v_caller_email is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  if p_amount = 0 then
    return jsonb_build_object('ok', false, 'reason', 'amount_zero');
  end if;

  update public.profiles
    set credits = credits + p_amount
    where id = p_target_user_id
    returning credits into v_new_balance;

  if v_new_balance is null then
    return jsonb_build_object('ok', false, 'reason', 'user_not_found');
  end if;

  insert into public.credit_transactions (user_id, amount, reason)
    values (p_target_user_id, p_amount, coalesce(nullif(trim(p_reason), ''), 'concours'));

  if p_amount > 0 then
    insert into public.credit_gift_notifications (target_user_id, amount)
      values (p_target_user_id, p_amount);
  end if;

  return jsonb_build_object('ok', true, 'newBalance', v_new_balance);
end;
$$;
grant execute on function public.admin_grant_credits(uuid, int, text) to authenticated;

create function public.admin_grant_credits_all(p_amount int, p_reason text default 'cadeau')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_email text;
  v_count int;
begin
  select lower(trim(email)) into v_caller_email from auth.users where id = auth.uid();
  if v_caller_email is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  if p_amount = 0 then
    return jsonb_build_object('ok', false, 'reason', 'amount_zero');
  end if;

  update public.profiles set credits = credits + p_amount;
  get diagnostics v_count = row_count;

  insert into public.credit_transactions (user_id, amount, reason)
    select id, p_amount, coalesce(nullif(trim(p_reason), ''), 'cadeau') from public.profiles;

  if p_amount > 0 then
    insert into public.credit_gift_notifications (target_user_id, amount)
      values (null, p_amount);
  end if;

  return jsonb_build_object('ok', true, 'count', v_count);
end;
$$;
grant execute on function public.admin_grant_credits_all(int, text) to authenticated;

create function public.admin_ban_user(p_target_user_id uuid, p_reason text, p_duration_hours int default null, p_scope text default 'launcher')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_email text;
  v_until timestamptz;
begin
  select lower(trim(email)) into v_caller_email from auth.users where id = auth.uid();
  if v_caller_email is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;
  if p_scope not in ('launcher', 'site', 'both') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_scope');
  end if;

  v_until := case when p_duration_hours is null then null else now() + (p_duration_hours || ' hours')::interval end;

  insert into public.user_bans (user_id, reason, banned_until, banned_by, scope, created_at)
    values (p_target_user_id, trim(p_reason), v_until, auth.uid(), p_scope, now())
    on conflict (user_id) do update
      set reason = excluded.reason, banned_until = excluded.banned_until,
          banned_by = excluded.banned_by, scope = excluded.scope, created_at = now();

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_ban_user(uuid, text, int, text) to authenticated;

create function public.admin_unban_user(p_target_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_email text;
begin
  select lower(trim(email)) into v_caller_email from auth.users where id = auth.uid();
  if v_caller_email is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  delete from public.user_bans where user_id = p_target_user_id;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_unban_user(uuid) to authenticated;

create function public.admin_list_bans()
returns table(user_id uuid, email text, reason text, banned_until timestamptz, banned_by uuid, created_at timestamptz, scope text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select lower(trim(au.email)) from auth.users au where au.id = auth.uid()) is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  return query
    select ub.user_id, u.email::text, ub.reason, ub.banned_until, ub.banned_by, ub.created_at, ub.scope
    from public.user_bans ub
    join auth.users u on u.id = ub.user_id
    order by ub.created_at desc;
end;
$$;
grant execute on function public.admin_list_bans() to authenticated;

NOTIFY pgrst, 'reload schema';
