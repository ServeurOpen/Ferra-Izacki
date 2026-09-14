-- ============================================================
-- Izacki — Migration 57 : compteur d'heures de développement de
-- l'entreprise Ferra.Izacki (14/09/2026, demande explicite : "un compteur
-- d'heure de développement en comptant tout les jeux, le launcher, le
-- site... visible sur le launcher dans le menu admin panel").
--
-- Composé de 3 sources, jamais dupliquées entre elles :
--   1. Une base MANUELLE de départ (dev_hours_base.base_hours) pour
--      couvrir tout le travail déjà fait avant la mise en place de ce
--      compteur — demandé explicitement à 272h (30 jours à 8h/jour, sauf
--      16h le dimanche : 26 jours x 8h + 4 dimanches x 16h = 208 + 64).
--      Ajustable ensuite par l'admin (voir admin_set_dev_hours_base).
--   2. Le temps passé Launcher/site OUVERTS en tant qu'admin, en secondes
--      cumulées (dev_time_sessions) — un "heartbeat" toutes les 60s côté
--      client insère un incrément, jamais un minuteur codé côté serveur
--      (impossible de savoir depuis la base si une appli tourne encore).
--   3. Le temps de jeu déjà tracké sur les 3 jeux officiels pour ce même
--      compte admin (table `game_stats`, alimentée depuis longtemps par
--      add_playtime/"game-session-end", voir migration_30) — RÉUTILISÉ
--      tel quel, jamais dupliqué dans une nouvelle table.
--
-- Volontairement scopé au SEUL compte admin (ferra.izacki@gmail.com) : ce
-- compteur mesure le travail d'Izacki sur son entreprise, pas le temps de
-- jeu agrégé de tous les joueurs — voir la policy RLS ci-dessous, qui
-- interdit à quiconque d'insérer une ligne dev_time_sessions pour un autre
-- user_id que le sien ET qui n'est pas cet email précis.
--
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

-- ---- 1) Base manuelle (une seule ligne, singleton) ----
create table if not exists public.dev_hours_base (
  id boolean primary key default true check (id),
  base_hours numeric not null default 0,
  updated_at timestamptz not null default now()
);
insert into public.dev_hours_base (id, base_hours)
  values (true, 272)
  on conflict (id) do nothing;

alter table public.dev_hours_base enable row level security;
-- Aucune policy select/insert/update pour le client : lecture et écriture
-- passent uniquement par les fonctions security definer ci-dessous.

-- ---- 2) Sessions Launcher/site (admin uniquement) ----
create table if not exists public.dev_time_sessions (
  id bigint generated always as identity primary key,
  source text not null check (source in ('launcher', 'site')),
  user_id uuid not null references auth.users(id) on delete cascade,
  duration_secs int not null check (duration_secs > 0 and duration_secs <= 900), -- un heartbeat = 60s max normalement, 900s de marge (15 min, ex. reprise après veille)
  created_at timestamptz not null default now()
);
create index if not exists dev_time_sessions_created_idx on public.dev_time_sessions (created_at);
create index if not exists dev_time_sessions_user_source_idx on public.dev_time_sessions (user_id, source);

alter table public.dev_time_sessions enable row level security;

drop policy if exists "Admin peut logger son propre temps de dev" on public.dev_time_sessions;
create policy "Admin peut logger son propre temps de dev"
  on public.dev_time_sessions for insert
  with check (
    auth.uid() = user_id
    and exists (
      select 1 from auth.users u
      where u.id = auth.uid() and lower(u.email) = 'ferra.izacki@gmail.com'
    )
  );
-- Pas de policy select : la lecture passe par get_dev_hours_total() (security definer).

-- ---- 3) Lecture agrégée (base + launcher + site + jeux officiels) ----
create or replace function public.get_dev_hours_total()
returns table(
  base_hours numeric,
  launcher_secs bigint,
  site_secs bigint,
  games_secs bigint,
  total_hours numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  admin_id uuid;
  v_launcher_secs bigint;
  v_site_secs bigint;
  v_games_secs bigint;
  v_base numeric;
begin
  select id into admin_id from auth.users where lower(email) = 'ferra.izacki@gmail.com' limit 1;

  select coalesce(sum(duration_secs), 0) into v_launcher_secs
    from dev_time_sessions where source = 'launcher' and user_id = admin_id;

  select coalesce(sum(duration_secs), 0) into v_site_secs
    from dev_time_sessions where source = 'site' and user_id = admin_id;

  select coalesce(sum(total_secs), 0) into v_games_secs
    from game_stats
    where user_id = admin_id and game_id in ('ferra', 'tower-defense', 'anime-clicker');

  select b.base_hours into v_base from dev_hours_base b where b.id = true;

  return query select
    v_base,
    v_launcher_secs,
    v_site_secs,
    v_games_secs,
    v_base + (v_launcher_secs + v_site_secs + v_games_secs)::numeric / 3600.0;
end;
$$;
grant execute on function public.get_dev_hours_total() to authenticated;

-- ---- 4) Ajustement manuel de la base (admin uniquement) ----
create or replace function public.admin_set_dev_hours_base(p_hours numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from auth.users where id = auth.uid() and lower(email) = 'ferra.izacki@gmail.com'
  ) then
    raise exception 'unauthorized';
  end if;
  if p_hours < 0 then
    raise exception 'invalid_hours';
  end if;
  update public.dev_hours_base set base_hours = p_hours, updated_at = now() where id = true;
end;
$$;
grant execute on function public.admin_set_dev_hours_base(numeric) to authenticated;

-- ---- 5) Enregistrement d'un heartbeat (admin uniquement, RPC pratique) ----
-- Simple wrapper autour de l'insert direct (utilisable aussi bien depuis le
-- Launcher que depuis le site, mêmes vérifications que la policy RLS
-- ci-dessus mais encapsulées ici pour un appel .rpc() en une ligne).
create or replace function public.log_dev_time(p_source text, p_secs int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_source not in ('launcher', 'site') then
    raise exception 'invalid_source';
  end if;
  if p_secs <= 0 or p_secs > 900 then
    raise exception 'invalid_secs';
  end if;
  if not exists (
    select 1 from auth.users where id = auth.uid() and lower(email) = 'ferra.izacki@gmail.com'
  ) then
    raise exception 'unauthorized';
  end if;
  insert into public.dev_time_sessions (source, user_id, duration_secs)
    values (p_source, auth.uid(), p_secs);
end;
$$;
grant execute on function public.log_dev_time(text, int) to authenticated;
