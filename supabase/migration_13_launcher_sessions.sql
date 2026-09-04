-- ============================================================
-- Izacki — Migration 13 : sessions Launcher (05/09/2026, demande
-- explicite : "savoir qui vient qui part et quand", "graphique des
-- connexions au launcher total/quotidien").
--
-- Une ligne = une session Launcher ouverte (started_at) jusqu'à sa
-- fermeture propre (ended_at) OU jusqu'au dernier signe de vie reçu
-- (last_heartbeat, rafraîchi toutes les 60s côté Launcher tant qu'il
-- tourne) — sert de filet si l'appli est tuée/plante avant de pouvoir
-- écrire ended_at proprement : la durée réelle est alors estimée par
-- last_heartbeat - started_at plutôt que perdue.
--
-- Le temps de jeu PAR JEU existe déjà (voir public.game_stats,
-- migration_5) — cette table couvre le temps sur le LAUNCHER lui-même,
-- une notion différente (le Launcher peut rester ouvert sans qu'aucun jeu
-- ne tourne).
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

create table if not exists public.launcher_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  started_at timestamptz not null default now(),
  last_heartbeat timestamptz not null default now(),
  ended_at timestamptz
);

create index if not exists launcher_sessions_user_idx on public.launcher_sessions (user_id);
create index if not exists launcher_sessions_started_idx on public.launcher_sessions (started_at);

alter table public.launcher_sessions enable row level security;

-- Un joueur peut voir/écrire UNIQUEMENT ses propres sessions — la vue
-- d'ensemble "tous les joueurs" du panel admin passe par une fonction Edge
-- à privilège de service (voir supabase/functions/admin-stats), jamais par
-- une lecture directe côté client.
create policy "Un joueur gere uniquement ses propres sessions"
  on public.launcher_sessions for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
