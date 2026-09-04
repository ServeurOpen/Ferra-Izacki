-- ============================================================
-- Izacki — Migration 17 : le reste des façons de gagner des crédits
-- (05/09/2026, demande explicite : "tout ce comment on peut gagner des
-- crédits tu l'implémentes, sauf le parrainage").
--
-- Parrainage volontairement PAS ici — voir la discussion en chat du
-- 05/09/2026 : sans vérification par SMS (payante), un champ déclaratif
-- seul est trivialement contournable (créer plusieurs comptes avec des
-- emails jetables pour se parrainer soi-même). Pistes envisageables sans
-- SMS si on y revient un jour : n'accorder la récompense qu'une fois le
-- compte parrainé arrivé à un vrai palier (ex. jour 3 de récompense
-- quotidienne, pas juste "créé"), plafonner le nombre de parrainages
-- récompensés par IP/appareil, et plafonner le total par semaine — aucune
-- de ces pistes n'est parfaite, mais combinées elles rendent la fraude
-- plus coûteuse que ce qu'elle rapporte pour un petit jeu indé. À
-- rediscuter si le parrainage redevient une priorité.
--
-- Couvre les 2 méthodes restantes de la liste d'origine :
--  1. Marquer nos emails en "Non-Spam" (+2 crédits, une fois) — sur
--     l'honneur, impossible à vérifier techniquement (ce qui se passe
--     dans la boîte mail du joueur n'est observable par personne), donc
--     ACCEPTÉ comme tel : montant volontairement faible (2 crédits) pour
--     qu'une fausse déclaration ne rapporte pas grand-chose. Ne devient
--     réellement pertinent QUE le jour où de vrais emails partent vers
--     tous les joueurs (actuellement bloqué faute de domaine, voir
--     migration_15) — visible dans le menu dès maintenant quand même,
--     pour que le joueur admin puisse au moins le tester lui-même.
--  2. Concours pendant des événements — pas d'auto-attribution possible
--     (aucun mécanisme de "concours" n'existe dans le jeu), donc géré par
--     une fonction que SEUL l'admin peut appeler pour créditer
--     manuellement un gagnant.
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_15.
-- ============================================================

alter table public.profiles add column if not exists spam_report_claimed boolean not null default false;

-- ---- 1) Marquer les emails en non-spam : +2 crédits, une fois ----
create or replace function public.claim_spam_report_bonus()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_already boolean;
  v_amount int := 2;
  v_new_balance int;
begin
  select spam_report_claimed into v_already from public.profiles where id = auth.uid();
  if v_already is null then
    return jsonb_build_object('claimed', false, 'reason', 'no_profile');
  end if;
  if v_already then
    return jsonb_build_object('claimed', false, 'reason', 'already_claimed');
  end if;

  update public.profiles
    set credits = credits + v_amount, spam_report_claimed = true
    where id = auth.uid()
    returning credits into v_new_balance;

  insert into public.credit_transactions (user_id, amount, reason)
    values (auth.uid(), v_amount, 'spam_report');

  return jsonb_build_object('claimed', true, 'amount', v_amount, 'newBalance', v_new_balance);
end;
$$;
grant execute on function public.claim_spam_report_bonus() to authenticated;

-- ---- 2) Concours : crédit manuel par l'admin uniquement ----
-- Revérifie ICI, côté base, que l'appelant est bien ferra.izacki@gmail.com
-- (jamais fié au seul JS du Launcher) — un joueur normal qui tente
-- d'appeler cette fonction reçoit une exception, aucun crédit accordé.
create or replace function public.admin_grant_credits(p_target_user_id uuid, p_amount int, p_reason text default 'concours')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_email text;
  v_new_balance int;
begin
  select email into v_caller_email from auth.users where id = auth.uid();
  if v_caller_email is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  if p_amount = 0 then
    return jsonb_build_object('ok', false, 'reason', 'amount_zero');
  end if;

  update public.profiles
    set credits = credits + p_amount
    where id = p_target_user_id
    returning credits into v_new_balance;

  if v_new_balance is null then
    return jsonb_build_object('ok', false, 'reason', 'user_not_found');
  end if;

  insert into public.credit_transactions (user_id, amount, reason)
    values (p_target_user_id, p_amount, coalesce(nullif(trim(p_reason), ''), 'concours'));

  return jsonb_build_object('ok', true, 'newBalance', v_new_balance);
end;
$$;
grant execute on function public.admin_grant_credits(uuid, int, text) to authenticated;
