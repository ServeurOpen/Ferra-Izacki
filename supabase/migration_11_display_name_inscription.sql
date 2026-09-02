-- ============================================================
-- Izacki — Migration 11 : demander le Nom d'affichage dès l'inscription
-- (site + Launcher), pour qu'un joueur ait un vrai nom dans le classement
-- dès le départ plutôt que de retomber sur son pseudo/tag (voir
-- migration_9_classement_nom_fallback.sql pour ce fallback, qui reste en
-- place pour les comptes existants qui n'en ont pas défini).
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, username, display_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)),
    nullif(trim(new.raw_user_meta_data->>'display_name'), '')
  );
  return new;
end;
$$ language plpgsql security definer;
