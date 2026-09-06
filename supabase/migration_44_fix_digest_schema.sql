-- ============================================================
-- Izacki — Migration 44 : correctif urgent — "Échec : function digest
-- (text, unknown) does not exist" lors d'un don de crédits (06/09/2026).
--
-- Cause : Supabase installe pgcrypto dans le schéma `extensions`, PAS
-- `public` — la fonction _verify_admin_passphrase() (migration_43) avait
-- `set search_path = public`, qui ne voit donc jamais digest(), même si
-- l'extension est bien activée. Corrigé en ajoutant `extensions` au
-- search_path ET en qualifiant l'appel explicitement (double sécurité,
-- fonctionne peu importe où l'extension a été installée).
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_43.
-- ============================================================

-- Garantit que pgcrypto existe bien dans le schéma extensions (no-op si
-- déjà là, quel que soit l'endroit où le "create extension" précédent
-- avait fini par l'installer).
create extension if not exists pgcrypto with schema extensions;

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
  if encode(extensions.digest(trim(coalesce(p_passphrase, '')), 'sha256'), 'hex') = v_hash then
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
