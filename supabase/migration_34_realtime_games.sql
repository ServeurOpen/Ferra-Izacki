-- ============================================================
-- Izacki — Migration 34 : mise à jour en temps réel de la liste des jeux
-- du marketplace (05/09/2026, demande explicite : "la liste des jeux ne
-- se met pas à jour en temps réel, il faut rouvrir l'onglet Boutique").
--
-- Ajoute submitted_games à la publication Realtime (même pattern que
-- user_bans/credit_gift_notifications, migration_22) — le Launcher
-- s'abonne aux changements et rafraîchit la grille automatiquement dès
-- qu'un jeu est approuvé/refusé/republié, sans redémarrer ni changer
-- d'onglet. RLS déjà en place (migration_26) fait le tri : un joueur ne
-- reçoit que les changements des jeux approuvés + les siens.
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

do $$
begin
  begin
    alter publication supabase_realtime add table public.submitted_games;
  exception when others then
    raise notice 'submitted_games déjà dans la publication (ou publication FOR ALL TABLES) : %', sqlerrm;
  end;
end $$;
