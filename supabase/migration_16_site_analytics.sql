-- ============================================================
-- Izacki — Migration 16 : statistiques du SITE web (05/09/2026, demande
-- explicite : "panel sur le site en mode admin, nombre de téléchargement
-- launcher, nombre de visite sur le site, les gens connectés/inscrits, les
-- gens non [rien]... des graphiques comparé à hier").
--
-- Volontairement minimal et anonyme : on ne loggue QUE le chemin de page et
-- l'heure (+ l'id du compte SI connecté, jamais forcé, jamais une IP ou une
-- empreinte navigateur) — largement suffisant pour des tendances de trafic,
-- sans construire un vrai système de tracking. Écriture ouverte à tous
-- (visiteurs anonymes compris, sinon impossible de compter leur venue) mais
-- LECTURE réservée à la fonction Edge à privilège de service
-- (admin-site-stats) : aucune policy select ne les rend lisibles
-- directement depuis le client, même pour l'auteur de la ligne.
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

create table if not exists public.site_visits (
  id bigint generated always as identity primary key,
  path text not null,
  user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists site_visits_created_idx on public.site_visits (created_at);

alter table public.site_visits enable row level security;

-- `user_id is not distinct from auth.uid()` accepte : un visiteur anonyme
-- qui insère user_id=null (auth.uid() vaut aussi null hors connexion), OU
-- un joueur connecté qui insère SON PROPRE id — jamais l'id de quelqu'un
-- d'autre, même en trafiquant l'appel réseau.
create policy "Logger une visite (visiteur ou joueur connecte)"
  on public.site_visits for insert
  with check (user_id is not distinct from auth.uid());

create table if not exists public.launcher_downloads (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now()
);
create index if not exists launcher_downloads_created_idx on public.launcher_downloads (created_at);

alter table public.launcher_downloads enable row level security;

create policy "Logger un telechargement (public)"
  on public.launcher_downloads for insert
  with check (true);
