-- ============================================================
-- Izacki — Migration 4 : tag numérique du pseudo (façon Discord)
-- À exécuter UNE FOIS dans Supabase, APRÈS toutes les migrations
-- précédentes. Chaque joueur devient "Pseudo#N", N = son rang de
-- création de compte (le tout premier compte = #1, le suivant #2, etc.).
-- Sert à ajouter un ami sans ambiguïté même si deux joueurs choisissent
-- le même pseudo.
-- ============================================================

alter table public.profiles add column if not exists player_number bigint;

-- Numérote tous les comptes déjà existants dans leur ordre de création.
with numbered as (
  select id, row_number() over (order by created_at asc, id asc) as rn
  from public.profiles
  where player_number is null
)
update public.profiles p
set player_number = n.rn
from numbered n
where p.id = n.id;

-- Séquence pour numéroter automatiquement tous les FUTURS comptes,
-- reprise juste après le plus grand numéro déjà attribué.
create sequence if not exists public.profiles_player_number_seq;
select setval('public.profiles_player_number_seq', coalesce((select max(player_number) from public.profiles), 0), true);

alter table public.profiles alter column player_number set default nextval('public.profiles_player_number_seq');
alter table public.profiles alter column player_number set not null;

alter table public.profiles drop constraint if exists profiles_player_number_unique;
alter table public.profiles add constraint profiles_player_number_unique unique (player_number);

-- Recherche d'un profil par tag complet "Pseudo#Numero" (ajout d'ami
-- depuis le launcher) — insensible à la casse sur le pseudo.
create or replace function public.find_profile_by_tag(p_username text, p_number bigint)
returns table (id uuid, username text, player_number bigint)
language sql
security definer
set search_path = public
as $$
  select id, username, player_number
  from public.profiles
  where lower(username) = lower(p_username) and player_number = p_number
  limit 1;
$$;

grant execute on function public.find_profile_by_tag(text, bigint) to authenticated;
