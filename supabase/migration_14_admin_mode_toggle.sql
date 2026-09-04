-- ============================================================
-- Izacki — Migration 14 : bascule mode Admin sur le site (05/09/2026,
-- demande explicite : "on est directement en mode Administrateur qui
-- pareil peut être désactivé dans l'onglet paramètre du site... si on
-- désactive pour réactiver il faut mettre un mdp").
--
-- Désactiver ne demande PAS de mot de passe (juste couper l'affichage
-- admin quand on veut naviguer "normalement") ; réactiver EN demande un —
-- vérifié côté serveur (voir supabase/functions/verify-admin-password),
-- jamais en clair dans le JS du site.
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

alter table public.profiles
  add column if not exists admin_mode_disabled boolean not null default false;
