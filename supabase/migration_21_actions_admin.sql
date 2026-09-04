-- ============================================================
-- Izacki — Migration 21 : "Actions" admin (05/09/2026, demande explicite :
-- "une catégorie pour give des crédits à un joueur ou tous", "Ban quelqu'un
-- pour une période temporaire ou définitif avec une raison affichée...
-- touche contester le ban", "Quand j'offre des crédits ça fait un pop up
-- stylé").
--
-- Comme toujours : jamais de write direct depuis le client sur des
-- colonnes sensibles (credits, bannissement) — tout passe par des
-- fonctions "security definer" qui revérifient elles-mêmes que l'appelant
-- est bien ferra.izacki@gmail.com, même si le client (Launcher/site) a
-- déjà fait ce contrôle de son côté avant d'afficher les boutons.
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

-- ---- Dons de crédits (individuel ou global) : sert à déclencher un pop up
-- côté joueur ("Le créateur vous a offert X crédits !") sans avoir à
-- stocker un flag "vu" par ligne de profils. target_user_id NULL = don à
-- TOUS les joueurs (passé/présent, pas seulement ceux inscrits au moment
-- du don — un joueur qui s'inscrit après verra quand même l'annonce). ----
create table if not exists public.credit_gift_notifications (
  id uuid primary key default gen_random_uuid(),
  target_user_id uuid references auth.users(id) on delete cascade,
  amount integer not null,
  created_at timestamptz not null default now()
);
create index if not exists credit_gift_notifications_target_idx on public.credit_gift_notifications (target_user_id);

alter table public.credit_gift_notifications enable row level security;
drop policy if exists "Un joueur voit ses dons individuels + les dons globaux" on public.credit_gift_notifications;
create policy "Un joueur voit ses dons individuels + les dons globaux"
  on public.credit_gift_notifications for select
  using (auth.uid() = target_user_id or target_user_id is null);
-- Pas de policy insert : seules les fonctions ci-dessous (admin_grant_credits*,
-- security definer) peuvent en créer.

-- Marque une notification comme déjà affichée à un joueur donné — surtout
-- utile pour les dons GLOBAUX (une seule ligne pour tout le monde, chaque
-- joueur doit pouvoir la "consommer" indépendamment des autres).
create table if not exists public.credit_gift_seen (
  notification_id uuid not null references public.credit_gift_notifications(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  seen_at timestamptz not null default now(),
  primary key (notification_id, user_id)
);
alter table public.credit_gift_seen enable row level security;
drop policy if exists "Un joueur gere uniquement ses propres accuses de lecture" on public.credit_gift_seen;
create policy "Un joueur gere uniquement ses propres accuses de lecture"
  on public.credit_gift_seen for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- ---- admin_grant_credits (migration_17) étendu pour aussi poser la
-- notification de pop up — remplace la version précédente. ----
create or replace function public.admin_grant_credits(p_target_user_id uuid, p_amount int, p_reason text default 'concours')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_email text;
  v_new_balance int;
begin
  select email into v_caller_email from auth.users where id = auth.uid();
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

-- ---- Créditer TOUS les joueurs d'un coup (05/09/2026, demande explicite :
-- "Une touche pour offrir à tout les joueurs") ----
create or replace function public.admin_grant_credits_all(p_amount int, p_reason text default 'cadeau')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_email text;
  v_count int;
begin
  select email into v_caller_email from auth.users where id = auth.uid();
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

-- ============================================================
-- Bannissement (05/09/2026, demande explicite : "Ban quelqu'un pour une
-- période temporaire ou définitif avec une raison qui sera affiché au
-- milieu de l'écran du joueur... décompte de son ban au lancement du
-- launcher... touche contester le ban").
-- banned_until NULL = définitif. Une seule ligne par joueur (primary key
-- user_id) : un nouveau ban remplace l'ancien (voir admin_ban_user, upsert).
-- ============================================================
create table if not exists public.user_bans (
  user_id uuid primary key references auth.users(id) on delete cascade,
  reason text not null,
  banned_until timestamptz,
  banned_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

alter table public.user_bans enable row level security;
drop policy if exists "Un joueur voit uniquement son propre statut de ban" on public.user_bans;
create policy "Un joueur voit uniquement son propre statut de ban"
  on public.user_bans for select
  using (auth.uid() = user_id);
-- Pas de policy insert/update/delete pour "authenticated" : seules les
-- fonctions admin_ban_user / admin_unban_user (security definer) écrivent ici.

create or replace function public.admin_ban_user(p_target_user_id uuid, p_reason text, p_duration_hours int default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_email text;
  v_until timestamptz;
begin
  select email into v_caller_email from auth.users where id = auth.uid();
  if v_caller_email is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;

  v_until := case when p_duration_hours is null then null else now() + (p_duration_hours || ' hours')::interval end;

  insert into public.user_bans (user_id, reason, banned_until, banned_by, created_at)
    values (p_target_user_id, trim(p_reason), v_until, auth.uid(), now())
    on conflict (user_id) do update
      set reason = excluded.reason, banned_until = excluded.banned_until,
          banned_by = excluded.banned_by, created_at = now();

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_ban_user(uuid, text, int) to authenticated;

create or replace function public.admin_unban_user(p_target_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_email text;
begin
  select email into v_caller_email from auth.users where id = auth.uid();
  if v_caller_email is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  delete from public.user_bans where user_id = p_target_user_id;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_unban_user(uuid) to authenticated;

-- Liste des joueurs actuellement bannis, avec email (auth.users n'est
-- jamais lisible directement par un client, même admin — cette fonction
-- security definer fait la jointure à sa place).
create or replace function public.admin_list_bans()
returns table(user_id uuid, email text, reason text, banned_until timestamptz, banned_by uuid, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select email from auth.users where id = auth.uid()) is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  return query
    select ub.user_id, u.email::text, ub.reason, ub.banned_until, ub.banned_by, ub.created_at
    from public.user_bans ub
    join auth.users u on u.id = ub.user_id
    order by ub.created_at desc;
end;
$$;
grant execute on function public.admin_list_bans() to authenticated;

-- ---- Historique des contestations de ban (audit uniquement — l'email
-- réel part depuis la fonction Edge "contest-ban" via Resend, jamais
-- directement depuis le client). Pas de policy RLS pour "authenticated" :
-- seule la fonction Edge (clé service role) y écrit/lit. ----
create table if not exists public.ban_appeals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  message text not null,
  created_at timestamptz not null default now()
);
alter table public.ban_appeals enable row level security;
