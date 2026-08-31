-- ============================================================
-- Izacki — Migration 3 : amis + groupes (Launcher)
-- À exécuter UNE FOIS dans Supabase (SQL Editor -> New query -> colle ->
-- Run) EN PLUS de schema.sql et migration_2_comptes.sql déjà exécutés.
-- Base pour un futur système de jeu en ligne (groupes = futures "lobbies").
-- ============================================================

-- ---- Amitiés (une ligne par relation, orientée demandeur -> destinataire) ----
create table if not exists public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete cascade,
  addressee_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint friendships_no_self check (requester_id <> addressee_id),
  unique (requester_id, addressee_id)
);

alter table public.friendships enable row level security;

create policy "Voir ses propres demandes/amities (envoyees ou recues)"
  on public.friendships for select
  using (auth.uid() = requester_id or auth.uid() = addressee_id);

create policy "Envoyer une demande d'ami"
  on public.friendships for insert
  with check (auth.uid() = requester_id);

create policy "Accepter/refuser/annuler une demande"
  on public.friendships for update
  using (auth.uid() = requester_id or auth.uid() = addressee_id);

create policy "Supprimer une amitie ou annuler sa propre demande"
  on public.friendships for delete
  using (auth.uid() = requester_id or auth.uid() = addressee_id);

create index if not exists idx_friendships_requester on public.friendships(requester_id, status);
create index if not exists idx_friendships_addressee on public.friendships(addressee_id, status);

-- ---- Groupes (base pour de futurs lobbies de jeu en ligne) ----
create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.groups enable row level security;

create policy "Voir les groupes dont on est membre"
  on public.groups for select
  using (exists (
    select 1 from public.group_members gm
    where gm.group_id = groups.id and gm.user_id = auth.uid()
  ));

create policy "Creer un groupe (on en devient le proprietaire)"
  on public.groups for insert
  with check (auth.uid() = owner_id);

create policy "Le proprietaire peut renommer/supprimer son groupe"
  on public.groups for update
  using (auth.uid() = owner_id);

create policy "Le proprietaire peut supprimer son groupe"
  on public.groups for delete
  using (auth.uid() = owner_id);

-- ---- Membres de groupe ----
create table if not exists public.group_members (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','member')),
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

alter table public.group_members enable row level security;

create policy "Voir les membres d'un groupe dont on fait partie"
  on public.group_members for select
  using (exists (
    select 1 from public.group_members gm2
    where gm2.group_id = group_members.group_id and gm2.user_id = auth.uid()
  ));

-- Deux cas d'insertion valides : (1) se rajouter soi-meme comme owner
-- juste apres avoir cree le groupe, (2) un membre existant qui invite
-- quelqu'un d'autre.
create policy "S'ajouter comme proprietaire ou inviter un ami dans son groupe"
  on public.group_members for insert
  with check (
    (user_id = auth.uid() and exists (
      select 1 from public.groups g where g.id = group_id and g.owner_id = auth.uid()
    ))
    or exists (
      select 1 from public.group_members gm3
      where gm3.group_id = group_members.group_id and gm3.user_id = auth.uid()
    )
  );

create policy "Quitter un groupe ou en retirer un membre (proprietaire)"
  on public.group_members for delete
  using (
    user_id = auth.uid()
    or exists (select 1 from public.groups g where g.id = group_id and g.owner_id = auth.uid())
  );

create index if not exists idx_group_members_user on public.group_members(user_id);

-- ---- Fonction pratique : rechercher un profil par pseudo exact (pour
-- l'ajout d'ami depuis le launcher) ----
create or replace function public.find_profile_by_username(p_username text)
returns table (id uuid, username text)
language sql
security definer
set search_path = public
as $$
  select id, username from public.profiles where lower(username) = lower(p_username) limit 1;
$$;

grant execute on function public.find_profile_by_username(text) to authenticated;
