-- ============================================================
-- Izacki — Migration 12 : consentement email (05/09/2026, demande explicite)
-- Ajoute 2 colonnes à profiles :
--   - email_opt_in : vrai/faux, coché par défaut (comme la case de
--     l'installateur qui sera pré-cochée) — le joueur peut le désactiver.
--   - email_consent_asked : vrai dès que le popup "Autorisez FERRA à vous
--     envoyer des emails..." a été montré une fois pour ce compte, pour ne
--     plus jamais le remontrer ensuite (le Launcher lit ce flag à la
--     connexion, voir showApp() dans main.ts).
-- À exécuter UNE FOIS dans Supabase : Dashboard -> SQL Editor -> New query
-- -> colle tout ce fichier -> Run.
-- ============================================================

alter table public.profiles
  add column if not exists email_opt_in boolean not null default true,
  add column if not exists email_consent_asked boolean not null default false;

-- Un joueur doit pouvoir lire/modifier SON PROPRE consentement (déjà permis
-- par les policies "select"/"update" existantes de profiles, qui portent
-- sur toute la ligne — aucune nouvelle policy nécessaire ici).
