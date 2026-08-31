-- ============================================================
-- Izacki — Correctif migration 3 : récursion infinie sur group_members
-- À exécuter UNE FOIS, APRÈS migration_3_amis_groupes.sql.
--
-- Cause : les policies de group_members interrogeaient group_members
-- elle-même dans leur propre condition USING/WITH CHECK — Postgres relance
-- la policy à chaque ligne consultée par la sous-requête, donc à l'infini
-- ("infinite recursion detected in policy for relation group_members").
-- Fix standard Postgres : une fonction SECURITY DEFINER (contourne RLS,
-- donc pas de boucle) que les policies appellent au lieu de requêter la
-- table directement.
-- ============================================================

create or replace function public.is_group_member(p_group_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.group_members
    where group_id = p_group_id and user_id = p_user_id
  );
$$;

grant execute on function public.is_group_member(uuid, uuid) to authenticated;

drop policy if exists "Voir les membres d'un groupe dont on fait partie" on public.group_members;
create policy "Voir les membres d'un groupe dont on fait partie"
  on public.group_members for select
  using (public.is_group_member(group_id, auth.uid()));

drop policy if exists "S'ajouter comme proprietaire ou inviter un ami dans son groupe" on public.group_members;
create policy "S'ajouter comme proprietaire ou inviter un ami dans son groupe"
  on public.group_members for insert
  with check (
    (user_id = auth.uid() and exists (
      select 1 from public.groups g where g.id = group_id and g.owner_id = auth.uid()
    ))
    or public.is_group_member(group_id, auth.uid())
  );
