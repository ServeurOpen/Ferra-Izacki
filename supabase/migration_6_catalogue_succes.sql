-- ============================================================
-- Izacki — Migration 6 : catalogue des succès par jeu (liste COMPLETE,
-- verrouillés + déverrouillés), pour que la fiche jeu du launcher puisse
-- afficher tous les succès existants et pas seulement ceux déjà débloqués.
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_5_profils_stylises.sql.
-- ============================================================

-- ---- Référentiel partagé (PAS une table par joueur) : chaque jeu pousse
-- sa propre liste complète de succès au démarrage (voir izacki-cloud.js ->
-- izackiRegisterCatalog, appelé par chaque jeu juste après la définition
-- de son tableau ACHIEVEMENTS). Un seul jeu est "propriétaire" de son
-- propre catalogue mais rien n'empêche l'upsert d'un autre compte connecté
-- au même jeu : c'est voulu, la définition d'un succès est identique pour
-- tout le monde, ce n'est pas une donnée par joueur.
create table if not exists public.game_achievement_catalog (
  game_id text not null,
  achievement_id text not null,
  name text,
  description text,
  icon text,
  tier text,
  updated_at timestamptz not null default now(),
  primary key (game_id, achievement_id)
);

alter table public.game_achievement_catalog enable row level security;

create policy "Le catalogue de succes est visible par tous"
  on public.game_achievement_catalog for select
  using (true);

-- Upsert en masse (un seul appel par lancement de jeu, quelle que soit la
-- taille du catalogue — Tower Défense en génère des dizaines par palier,
-- inutile de faire une requête par succès).
create or replace function public.register_achievement_catalog(p_game_id text, p_items jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.game_achievement_catalog (game_id, achievement_id, name, description, icon, tier, updated_at)
  select p_game_id, item->>'id', item->>'name', item->>'description', item->>'icon', item->>'tier', now()
  from jsonb_array_elements(p_items) as item
  where item->>'id' is not null
  on conflict (game_id, achievement_id) do update
    set name = excluded.name, description = excluded.description, icon = excluded.icon, tier = excluded.tier, updated_at = now();
end;
$$;

grant execute on function public.register_achievement_catalog(text, jsonb) to authenticated;
