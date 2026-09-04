-- ============================================================
-- Izacki — Migration 19 : dédoublonnage des visites connectées
-- (05/09/2026, demande explicite : "si le joueur revient 14 fois dans la
-- journée ça compte 1 fois pas 14, si il revient demain ça compte 1
-- fois. Les joueurs sans compte peuvent être comptés plusieurs fois, ce
-- n'est pas grave").
--
-- Approche : une vraie contrainte UNIQUE côté base (user_id, visit_day)
-- pour les visites connectées uniquement (user_id non nul) — pas un
-- bricolage côté client (localStorage), qui serait contournable en
-- vidant les données du navigateur et ne compterait pas les visites
-- depuis un autre appareil. `ferraLogVisit` (auth.js) continue de faire
-- un simple insert() à chaque page vue, SANS RIEN CHANGER côté code : dès
-- que la contrainte existe, les inserts en double du même jour échouent
-- silencieusement tout seuls (déjà avalés par le try/catch existant).
-- Les visiteurs anonymes (user_id NULL) ne sont PAS couverts par l'index
-- (partiel, `where user_id is not null`) — ils continuent de compter à
-- chaque page vue, comme demandé.
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_16.
-- ============================================================

-- Colonne calculée au moment de l'insert (DEFAULT current_date, évalué
-- par Postgres à l'écriture — pas une colonne GENERATED, donc aucune
-- contrainte d'immutabilité à respecter, contrairement à un index sur
-- une expression comme created_at::date qui aurait échoué).
alter table public.site_visits add column if not exists visit_day date;

-- Recalcule la vraie date (UTC) des lignes déjà existantes avant de poser
-- la contrainte, plutôt que de leur laisser toutes la date du jour où
-- cette migration tourne.
update public.site_visits
  set visit_day = (created_at at time zone 'utc')::date
  where visit_day is null;

alter table public.site_visits alter column visit_day set default current_date;
alter table public.site_visits alter column visit_day set not null;

-- Dédoublonnage des lignes déjà en base (sinon la contrainte UNIQUE
-- ci-dessous échouerait à la création s'il existe déjà plusieurs visites
-- du même joueur le même jour — le cas qu'on corrige justement) : ne
-- garde que la plus ancienne ligne par (joueur, jour).
delete from public.site_visits a
using public.site_visits b
where a.user_id is not null
  and a.user_id = b.user_id
  and a.visit_day = b.visit_day
  and a.id > b.id;

create unique index if not exists site_visits_user_day_uidx
  on public.site_visits (user_id, visit_day)
  where user_id is not null;
