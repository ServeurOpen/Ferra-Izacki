-- ============================================================
-- Izacki — Migration 10 :
--   1) Active le Realtime sur friendships/group_members (sans ça, le
--      Launcher ne peut pas détecter en direct une demande d'ami reçue —
--      il fallait relancer l'app).
--   2) Chat de groupe (table group_messages) — pour parler "tous
--      ensemble" avec les membres d'un groupe d'amis.
--   3) Invitations à jouer (table game_invites) — inviter un ami à
--      lancer le même jeu que soi (chacun de son côté, pas de vraie
--      partie commune pour l'instant).
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_3_amis_groupes.sql.
-- ============================================================

-- ---- 1) Realtime sur les tables amis/groupes ----
-- Sans ceci, aucun postgres_changes n'est jamais émis pour ces tables,
-- quel que soit le filtre côté client.
alter publication supabase_realtime add table public.friendships;
alter publication supabase_realtime add table public.group_members;

-- ---- 2) Chat de groupe ----
create table if not exists public.group_messages (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);

alter table public.group_messages enable row level security;

create policy "Les membres du groupe lisent ses messages"
  on public.group_messages for select
  using (exists (
    select 1 from public.group_members gm
    where gm.group_id = group_messages.group_id and gm.user_id = auth.uid()
  ));

create policy "Les membres du groupe peuvent poster"
  on public.group_messages for insert
  with check (
    auth.uid() = user_id
    and exists (
      select 1 from public.group_members gm
      where gm.group_id = group_messages.group_id and gm.user_id = auth.uid()
    )
  );

alter publication supabase_realtime add table public.group_messages;

-- ---- 3) Invitations à jouer ----
create table if not exists public.game_invites (
  id uuid primary key default gen_random_uuid(),
  from_user_id uuid not null references public.profiles(id) on delete cascade,
  to_user_id uuid not null references public.profiles(id) on delete cascade,
  game_id text not null,
  status text not null default 'pending' check (status in ('pending','seen','dismissed')),
  created_at timestamptz not null default now()
);

alter table public.game_invites enable row level security;

create policy "Voir mes invitations recues ou envoyees"
  on public.game_invites for select
  using (auth.uid() = from_user_id or auth.uid() = to_user_id);

-- On ne peut inviter qu'un ami accepté (pas n'importe quel user_id) —
-- évite le spam d'invitations à des inconnus.
create policy "Envoyer une invitation a un ami accepte"
  on public.game_invites for insert
  with check (
    auth.uid() = from_user_id
    and exists (
      select 1 from public.friendships f
      where f.status = 'accepted'
        and ((f.requester_id = auth.uid() and f.addressee_id = to_user_id)
          or (f.addressee_id = auth.uid() and f.requester_id = to_user_id))
    )
  );

create policy "Le destinataire met a jour le statut de son invitation"
  on public.game_invites for update
  using (auth.uid() = to_user_id)
  with check (auth.uid() = to_user_id);

create policy "L'expediteur peut retirer son invitation"
  on public.game_invites for delete
  using (auth.uid() = from_user_id);

alter publication supabase_realtime add table public.game_invites;
