-- ============================================================
-- Izacki — Retrait de crédits admin (07/09/2026, demande explicite :
-- "fais moi une touche admin dans le panel launcher pour retirer des
-- crédits avec le même long mdp"). admin_grant_credits() (migration_43)
-- acceptait déjà un montant NÉGATIF sans le bloquer — pas besoin d'une
-- nouvelle fonction, juste un nouveau bouton côté Launcher qui envoie un
-- montant négatif. Seul ajout ici : un plancher à 0 (jamais de solde
-- négatif, même si l'admin retire plus que ce que le joueur possède) —
-- même signature, donc pas de "drop function" nécessaire (voir la règle
-- habituelle : seul un changement de signature/type de retour l'exige).
-- ============================================================

create or replace function public.admin_grant_credits(p_target_user_id uuid, p_amount int, p_reason text default 'concours', p_passphrase text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_email text;
  v_new_balance int;
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

  update public.profiles
    set credits = greatest(0, credits + p_amount)
    where id = p_target_user_id
    returning credits into v_new_balance;

  if v_new_balance is null then
    return jsonb_build_object('ok', false, 'reason', 'user_not_found');
  end if;

  insert into public.credit_transactions (user_id, amount, reason)
    values (p_target_user_id, p_amount, coalesce(nullif(trim(p_reason), ''), 'concours'));

  if p_amount > 0 then
    insert into public.credit_gift_notifications (target_user_id, amount)
      values (p_target_user_id, p_amount);
  end if;

  return jsonb_build_object('ok', true, 'newBalance', v_new_balance);
end;
$$;
grant execute on function public.admin_grant_credits(uuid, int, text, text) to authenticated;

notify pgrst, 'reload schema';
