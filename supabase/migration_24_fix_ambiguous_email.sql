-- ============================================================
-- Izacki — Migration 24 : correctif "column reference 'email' is
-- ambiguous" (05/09/2026) — admin_list_bans() déclare une colonne de
-- retour nommée "email" (RETURNS TABLE(..., email text, ...)), qui devient
-- une variable implicite du même nom dans TOUT le corps de la fonction.
-- La vérification admin faisait "select email from auth.users where id =
-- auth.uid()" SANS qualifier la table : Postgres ne savait plus s'il
-- s'agissait de la colonne auth.users.email ou de la variable de retour
-- "email" — d'où l'ambiguïté. Fix : qualifier explicitement (alias "au").
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

drop function if exists public.admin_list_bans();

create function public.admin_list_bans()
returns table(user_id uuid, email text, reason text, banned_until timestamptz, banned_by uuid, created_at timestamptz, scope text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select au.email from auth.users au where au.id = auth.uid()) is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  return query
    select ub.user_id, u.email::text, ub.reason, ub.banned_until, ub.banned_by, ub.created_at, ub.scope
    from public.user_bans ub
    join auth.users u on u.id = ub.user_id
    order by ub.created_at desc;
end;
$$;
grant execute on function public.admin_list_bans() to authenticated;

NOTIFY pgrst, 'reload schema';
