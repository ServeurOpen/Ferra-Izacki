-- ============================================================
-- Suivi d'erreurs léger (type Sentry) — demandé le 06/09/2026 lors de
-- l'état des lieux "prêt pour le grand public", cadré le 07/09/2026.
--
-- Choix fait (pas de service externe type Sentry.io, pour rester
-- gratuit et tout garder dans le même Supabase déjà utilisé) : une
-- simple table + lecture via le panel admin, exactement comme le reste
-- des stats admin de ce projet (jamais de lecture cross-joueurs en
-- direct côté client, toujours via une fonction Edge/service role).
--
-- Capture : erreurs JS non gérées + promesses rejetées côté Launcher
-- (webview), et panics du process Rust (écrits dans un fichier au
-- moment du crash, puis envoyés ici au lancement suivant — voir
-- take_pending_crash_report côté Rust). Pas encore les jeux eux-mêmes
-- (volume potentiel trop incertain pour commencer) — extensible plus
-- tard si besoin.
-- ============================================================

create table if not exists public.error_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  source text not null check (source in ('launcher_js', 'launcher_rust')),
  message text not null,
  stack text,
  app_version text,
  os_info text,
  created_at timestamptz not null default now()
);
create index if not exists error_reports_created_idx on public.error_reports (created_at desc);

alter table public.error_reports enable row level security;

-- Un joueur connecté peut ENVOYER un rapport (jamais lire/modifier ceux
-- des autres — exactement comme game_purchases, migration_29).
drop policy if exists "Un joueur peut envoyer un rapport d'erreur" on public.error_reports;
create policy "Un joueur peut envoyer un rapport d'erreur"
  on public.error_reports for insert
  with check (auth.uid() = user_id);

notify pgrst, 'reload schema';
