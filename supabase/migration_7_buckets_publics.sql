-- ============================================================
-- Izacki — Migration 7 : force les buckets avatars/banners en lecture
-- publique, au cas où ils auraient été créés (par migration_5, ou
-- manuellement avant) avec public=false — auquel cas l'upload d'une
-- bannière/avatar perso "réussissait" côté stockage mais l'image ne
-- s'affichait jamais ensuite (URL publique renvoyant une erreur d'accès).
-- migration_5_profils_stylises.sql utilisait "on conflict (id) do nothing",
-- qui ne corrige pas un bucket déjà existant en privé.
-- Sans risque à ré-exécuter plusieurs fois.
-- ============================================================

update storage.buckets set public = true where id in ('avatars', 'banners');
