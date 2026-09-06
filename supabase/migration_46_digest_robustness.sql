-- ============================================================
-- Izacki — Migration 46 : renforce le correctif digest() (06/09/2026,
-- trouvé par une revue de code adversariale, pas un bug signalé) —
-- migration_44 avait qualifié l'appel en dur en `extensions.digest(...)`,
-- ce qui est en réalité MOINS robuste que prévu : si pgcrypto se
-- retrouvait un jour installé ailleurs que dans le schéma `extensions`
-- (ex. `public`, sur un projet Supabase différent ou après une migration
-- future), cet appel qualifié échouerait quand même, alors qu'un appel
-- NON qualifié aurait été retrouvé par `search_path = public, extensions`
-- peu importe lequel des deux schémas l'héberge réellement. Retire donc
-- la qualification en dur — le search_path étendu suffit à lui seul et
-- couvre les deux cas.
-- Remarque : d'après le bug initial (migration_43 échouait avec
-- search_path=public seul), pgcrypto est bien dans `extensions` sur CE
-- projet — migration_44 fonctionne donc déjà correctement en pratique ;
-- ce correctif est une amélioration de robustesse, pas un bug actif.
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_45.
-- ============================================================

create or replace function public._verify_admin_passphrase(p_passphrase text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_state record;
  v_hash text := 'e7ca2a5d63e1f60f867c8339fb87031bafd2052593abf66bb4069070a91ae670';
begin
  if not public.is_current_user_admin() then
    raise exception 'forbidden';
  end if;
  select * into v_state from public.admin_passphrase_state where id = true for update;
  if v_state.locked_until is not null and v_state.locked_until > now() then
    return jsonb_build_object('ok', false, 'reason', 'locked', 'lockedUntil', v_state.locked_until);
  end if;
  -- Appel NON qualifié (contrairement à migration_44) : le search_path
  -- ci-dessus (public, extensions) le retrouve peu importe dans lequel
  -- des deux schémas pgcrypto vit réellement.
  if encode(digest(trim(coalesce(p_passphrase, '')), 'sha256'), 'hex') = v_hash then
    update public.admin_passphrase_state set failed_count = 0, locked_until = null where id = true;
    return jsonb_build_object('ok', true);
  else
    update public.admin_passphrase_state
      set failed_count = failed_count + 1,
          locked_until = case when failed_count + 1 >= 5 then now() + interval '15 minutes' else locked_until end
      where id = true;
    return jsonb_build_object('ok', false, 'reason', 'wrong_passphrase');
  end if;
end;
$$;
grant execute on function public._verify_admin_passphrase(text) to authenticated;
