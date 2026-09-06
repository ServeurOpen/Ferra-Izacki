-- ============================================================
-- Izacki — Migration 36 : bannière optionnelle par jeu soumis
-- (06/09/2026, demande explicite : "fais en sorte que les joueurs
-- puissent mettre une bannière, sinon ça met un truc prédéfini par le
-- launcher") — nouvelle colonne nullable, aucun changement de policy
-- nécessaire : le fichier est stocké dans le même bucket/dossier que les
-- captures d'écran (game-submission-screenshots/<seller_id>/<game_id>/
-- banner.<ext>), déjà couvert par la policy storage existante
-- (migration_26 : auth.uid()::text = premier segment du chemin).
-- ============================================================

alter table public.submitted_games add column if not exists banner_path text;
