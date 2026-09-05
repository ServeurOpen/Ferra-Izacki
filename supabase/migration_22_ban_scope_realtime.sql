-- ============================================================
-- Izacki — Migration 22 : portée du ban + temps réel (05/09/2026, retours
-- du joueur après test de la migration 21 : "il doit redémarrer le
-- launcher, c'est pas direct" / "le site peut ban site et launcher, le
-- launcher que launcher").
--
-- 1) Ajoute une "portée" (scope) au bannissement : 'launcher' (bloque
--    uniquement le Launcher — seul choix possible depuis le Launcher),
--    'site' (bloque uniquement le site) ou 'both' (bloque les deux —
--    choix possibles uniquement depuis le panel DU SITE). Un ban existant
--    (migration_21) ne bloquait que le Launcher : les lignes déjà en base
--    passent donc par défaut à scope='launcher' pour ne rien changer à
--    leur comportement actuel.
-- 2) Ajoute credit_gift_notifications et user_bans à la publication
--    Realtime, pour que le Launcher affiche le pop up de don / l'écran de
--    ban INSTANTANÉMENT (voir setupFriendsRealtime dans main.ts, même
--    pattern) au lieu d'attendre le prochain redémarrage.
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

alter table public.user_bans add column if not exists scope text not null default 'launcher';
alter table public.user_bans drop constraint if exists user_bans_scope_check;
alter table public.user_bans add constraint user_bans_scope_check check (scope in ('launcher', 'site', 'both'));

create or replace function public.admin_ban_user(p_target_user_id uuid, p_reason text, p_duration_hours int default null, p_scope text default 'launcher')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_email text;
  v_until timestamptz;
begin
  select email into v_caller_email from auth.users where id = auth.uid();
  if v_caller_email is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;
  if p_scope not in ('launcher', 'site', 'both') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_scope');
  end if;

  v_until := case when p_duration_hours is null then null else now() + (p_duration_hours || ' hours')::interval end;

  insert into public.user_bans (user_id, reason, banned_until, banned_by, scope, created_at)
    values (p_target_user_id, trim(p_reason), v_until, auth.uid(), p_scope, now())
    on conflict (user_id) do update
      set reason = excluded.reason, banned_until = excluded.banned_until,
          banned_by = excluded.banned_by, scope = excluded.scope, created_at = now();

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_ban_user(uuid, text, int, text) to authenticated;

create or replace function public.admin_list_bans()
returns table(user_id uuid, email text, reason text, banned_until timestamptz, banned_by uuid, created_at timestamptz, scope text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select email from auth.users where id = auth.uid()) is distinct from 'ferra.izacki@gmail.com' then
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

-- ---- Realtime (05/09/2026, demande explicite : ça doit être instantané,
-- pas besoin de redémarrer). Si ces tables sont déjà couvertes par la
-- publication (par ex. si "supabase_realtime" est en FOR ALL TABLES chez
-- toi), Postgres renvoie une erreur du style "relation ... is already
-- member of publication" ou "cannot add relation to a FOR ALL TABLES
-- publication" — dans ce cas ignore juste cette erreur précise, ça
-- fonctionne déjà. ----
alter publication supabase_realtime add table public.user_bans;
alter publication supabase_realtime add table public.credit_gift_notifications;
