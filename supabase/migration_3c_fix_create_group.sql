-- ============================================================
-- Izacki — Correctif migration 3 (bis) : création de groupe bloquée par RLS
-- À exécuter APRÈS migration_3_amis_groupes.sql et migration_3b_fix_recursion.sql.
--
-- Cause : la création se faisait en 2 requêtes séparées côté launcher
-- (1. insert dans groups + relire la ligne créée, 2. insert dans
-- group_members). Juste après l'étape 1, aucune ligne group_members
-- n'existe encore pour ce groupe → la policy de lecture de "groups"
-- (is_group_member) refuse de renvoyer la ligne qu'on vient de créer,
-- ce que PostgREST rapporte comme "new row violates row-level security
-- policy". Fix : une fonction unique qui fait les deux insertions
-- d'un coup, sans jamais relire "groups" entre les deux.
-- ============================================================

create or replace function public.create_group(p_name text, p_owner uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id uuid;
begin
  if p_owner <> auth.uid() then
    raise exception 'Non autorisé';
  end if;
  insert into public.groups (name, owner_id) values (p_name, p_owner) returning id into v_group_id;
  insert into public.group_members (group_id, user_id, role) values (v_group_id, p_owner, 'owner');
  return v_group_id;
end;
$$;

grant execute on function public.create_group(text, uuid) to authenticated;
