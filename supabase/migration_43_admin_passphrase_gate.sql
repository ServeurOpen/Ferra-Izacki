-- ============================================================
-- Izacki — Migration 43 : mot de passe de passage pour Bannir / Créditer
-- un joueur / Créditer tout le monde (06/09/2026, demande explicite :
-- "je le veux à chaque fois qu'on utilise un ban ou give crédit all ou 1
-- [...] barrière impénétrable au cas où je me fais hack").
--
-- Le mot de passe n'est JAMAIS stocké en clair nulle part (ni ici, ni
-- dans le Launcher, ni dans un fichier du dépôt) : seul son EMPREINTE
-- SHA-256 est comparée côté serveur — impossible de retrouver le mot de
-- passe à partir de cette empreinte. Verrou anti-force-brute : 5 essais
-- faux d'affilée bloquent toute nouvelle tentative pendant 15 minutes.
--
-- IMPORTANT : ce verrou protège contre un compte admin compromis (session
-- volée) qui tenterait ces 3 actions précises — ce n'est PAS un
-- remplacement de la sécurité du compte lui-même (mot de passe du compte,
-- accès à l'ordinateur...). Étendre à d'autres actions (retraits,
-- remboursements...) est possible sur demande, volontairement pas fait
-- ici pour rester sur exactement ce qui a été demandé.
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_42.
-- ============================================================

create extension if not exists pgcrypto;

create table if not exists public.admin_passphrase_state (
  id boolean primary key default true check (id),
  failed_count int not null default 0,
  locked_until timestamptz
);
insert into public.admin_passphrase_state (id) values (true) on conflict (id) do nothing;
alter table public.admin_passphrase_state enable row level security;
-- Aucune policy select/insert/update pour "authenticated" : cette table
-- n'est lue/écrite que par les fonctions security definer ci-dessous.

create or replace function public._verify_admin_passphrase(p_passphrase text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_state record;
  -- Empreinte SHA-256 du mot de passe de passage (jamais le mot de passe
  -- lui-même) — voir MdpSafe.txt côté joueur pour la valeur réelle.
  v_hash text := 'e7ca2a5d63e1f60f867c8339fb87031bafd2052593abf66bb4069070a91ae670';
begin
  if not public.is_current_user_admin() then
    raise exception 'forbidden';
  end if;
  select * into v_state from public.admin_passphrase_state where id = true for update;
  if v_state.locked_until is not null and v_state.locked_until > now() then
    return jsonb_build_object('ok', false, 'reason', 'locked', 'lockedUntil', v_state.locked_until);
  end if;
  if encode(digest(trim(coalesce(p_passphrase, '')), 'sha256'), 'hex') = v_hash then
    update public.admin_passphrase_state set failed_count = 0, locked_until = null where id = true;
    return jsonb_build_object('ok', true);
  else
    update public.admin_passphrase_state
      set failed_count = failed_count + 1,
          locked_until = case when failed_count + 1 >= 5 then now() + interval '15 minutes' else locked_until end
      where id = true;
    return jsonb_build_object('ok', false, 'reason', 'wrong_passphrase');
  end if;
end;
$$;
grant execute on function public._verify_admin_passphrase(text) to authenticated;

-- ---- Les 3 fonctions protégées — DROP obligatoire (nouveau paramètre =
-- signature différente, "create or replace" créerait un doublon au lieu
-- de remplacer, voir le bug déjà rencontré avec ces mêmes fonctions en
-- migration_23). Corps identique à migration_25, seul le contrôle du mot
-- de passe est ajouté tout en haut. ----
drop function if exists public.admin_ban_user(uuid, text, int, text);
drop function if exists public.admin_grant_credits(uuid, int, text);
drop function if exists public.admin_grant_credits_all(int, text);

create function public.admin_grant_credits(p_target_user_id uuid, p_amount int, p_reason text default 'concours', p_passphrase text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_email text;
  v_new_balance int;
  v_check jsonb;
begin
  select lower(trim(email)) into v_caller_email from auth.users where id = auth.uid();
  if v_caller_email is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  v_check := public._verify_admin_passphrase(p_passphrase);
  if not coalesce((v_check->>'ok')::boolean, false) then
    return v_check;
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
grant execute on function public.admin_grant_credits(uuid, int, text, text) to authenticated;

create function public.admin_grant_credits_all(p_amount int, p_reason text default 'cadeau', p_passphrase text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_email text;
  v_count int;
  v_check jsonb;
begin
  select lower(trim(email)) into v_caller_email from auth.users where id = auth.uid();
  if v_caller_email is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  v_check := public._verify_admin_passphrase(p_passphrase);
  if not coalesce((v_check->>'ok')::boolean, false) then
    return v_check;
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
grant execute on function public.admin_grant_credits_all(int, text, text) to authenticated;

create function public.admin_ban_user(p_target_user_id uuid, p_reason text, p_duration_hours int default null, p_scope text default 'launcher', p_passphrase text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_email text;
  v_until timestamptz;
  v_check jsonb;
begin
  select lower(trim(email)) into v_caller_email from auth.users where id = auth.uid();
  if v_caller_email is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  v_check := public._verify_admin_passphrase(p_passphrase);
  if not coalesce((v_check->>'ok')::boolean, false) then
    return v_check;
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
grant execute on function public.admin_ban_user(uuid, text, int, text, text) to authenticated;

NOTIFY pgrst, 'reload schema';
