-- ============================================================
-- Izacki — Migration 49 : corrige "Créditer TOUT LE MONDE" (06/09/2026,
-- bug signalé : "Échec : UPDATE requires a WHERE clause").
--
-- Cause réelle : ce projet Supabase a la protection "pg-safeupdate"
-- active (bloque tout UPDATE/DELETE sans clause WHERE, pour éviter les
-- accidents) — hors ici, mettre à jour TOUT LE MONDE sans exception est
-- précisément le but de cette fonction ("Créditer tout le monde"), donc
-- un vrai WHERE n'a pas de sens. `where true` satisfait la protection
-- (elle vérifie juste la présence du mot-clé) sans rien changer au
-- comportement — toujours 100% des profils, exactement comme avant.
-- Corps par ailleurs identique à migration_43 (mot de passe de passage
-- inchangé).
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_47 (et migration_48
-- si pas déjà fait).
-- ============================================================

create or replace function public.admin_grant_credits_all(p_amount int, p_reason text default 'cadeau', p_passphrase text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_email text;
  v_count int;
  v_check jsonb;
begin
  select lower(trim(email)) into v_caller_email from auth.users where id = auth.uid();
  if v_caller_email is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  v_check := public._verify_admin_passphrase(p_passphrase);
  if not coalesce((v_check->>'ok')::boolean, false) then
    return v_check;
  end if;
  if p_amount = 0 then
    return jsonb_build_object('ok', false, 'reason', 'amount_zero');
  end if;

  update public.profiles set credits = credits + p_amount where true;
  get diagnostics v_count = row_count;

  insert into public.credit_transactions (user_id, amount, reason)
    select id, p_amount, coalesce(nullif(trim(p_reason), ''), 'cadeau') from public.profiles;

  if p_amount > 0 then
    insert into public.credit_gift_notifications (target_user_id, amount)
      values (null, p_amount);
  end if;

  return jsonb_build_object('ok', true, 'count', v_count);
end;
$$;
grant execute on function public.admin_grant_credits_all(int, text, text) to authenticated;
