-- ============================================================
-- FERRA — Migration 2 : comptes unifiés site/forum + connexion par pseudo
-- À exécuter UNE FOIS dans Supabase (SQL Editor -> New query -> colle ->
-- Run) EN PLUS du schema.sql déjà exécuté. Voir le README.md, section
-- "Comptes joueurs".
-- ============================================================

-- Règle des pseudos : lettres/chiffres/underscore uniquement (donc jamais
-- d'espace ni de caractère bizarre), et au moins une majuscule. Appliquée
-- aussi côté site (assets/js/auth.js) AVANT l'inscription, cette contrainte
-- est le filet de sécurité côté base de données.
alter table public.profiles drop constraint if exists profiles_username_format;
alter table public.profiles add constraint profiles_username_format
  check (username ~ '^[A-Za-z0-9_]{3,24}$' and username ~ '[A-Z]');

-- Permet de se connecter avec son PSEUDO en plus de son email : cette
-- fonction retrouve l'email associé à un pseudo, en gardant l'accès à la
-- table auth.users (normalement invisible) restreint à ce seul usage.
create or replace function public.get_email_by_username(p_username text)
returns text
language sql
security definer
set search_path = public, auth
as $$
  select u.email
  from auth.users u
  join public.profiles p on p.id = u.id
  where lower(p.username) = lower(p_username)
  limit 1;
$$;

grant execute on function public.get_email_by_username(text) to anon, authenticated;
