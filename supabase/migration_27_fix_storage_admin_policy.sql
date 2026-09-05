-- ============================================================
-- Izacki — Migration 27 : correctif "permission denied for table users"
-- lors de la soumission d'un jeu (05/09/2026) — la policy "Admin lit tous
-- les fichiers de jeu soumis" (migration_26) interrogeait directement
-- auth.users depuis une policy RLS classique, évaluée avec les droits du
-- rôle appelant ("authenticated") — qui n'a PAS la permission de lire
-- cette table (contrairement à une fonction "security definer", qui
-- s'exécute avec les droits du propriétaire de la fonction). Résultat :
-- même le vendeur qui uploade SON PROPRE fichier se prenait l'erreur,
-- car Postgres évalue TOUTES les policies applicables et une erreur dans
-- l'une d'elles fait échouer toute la vérification.
-- Fix : passer par une fonction "security definer" (comme partout
-- ailleurs dans le projet) au lieu d'un accès direct à auth.users dans la
-- policy elle-même.
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

create or replace function public.is_current_user_admin()
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from auth.users where id = auth.uid() and lower(trim(email)) = 'ferra.izacki@gmail.com'
  );
$$;
grant execute on function public.is_current_user_admin() to authenticated;

drop policy if exists "Admin lit tous les fichiers de jeu soumis" on storage.objects;
create policy "Admin lit tous les fichiers de jeu soumis"
  on storage.objects for select
  using (bucket_id = 'game-submission-files' and public.is_current_user_admin());
