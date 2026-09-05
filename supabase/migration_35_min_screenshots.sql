-- ============================================================
-- Izacki — Migration 35 : minimum 3 captures d'écran par jeu soumis
-- (05/09/2026, demande explicite) — garde-fou CÔTÉ SERVEUR en plus de la
-- vérification déjà faite dans le Launcher, au cas où quelqu'un contourne
-- l'appli (appel direct à l'API). NOT VALID : ne s'applique qu'aux
-- nouvelles lignes / modifications, ne casse pas les jeux déjà soumis
-- avec moins de 3 captures avant cette règle.
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

alter table public.submitted_games drop constraint if exists submitted_games_min_screenshots;
alter table public.submitted_games
  add constraint submitted_games_min_screenshots
  check (array_length(screenshot_paths, 1) >= 3) not valid;
