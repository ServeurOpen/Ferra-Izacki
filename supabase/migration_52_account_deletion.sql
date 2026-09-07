-- ============================================================
-- Suppression de compte / droit à l'oubli (RGPD) — demandée le 06/09/2026
-- lors de l'état des lieux "prêt pour le grand public", cadrée et validée
-- le 07/09/2026 :
--   - Anonymisation plutôt que suppression physique totale (validé :
--     "oui je valide") — nécessaire car `game_purchases`/`submitted_games`
--     référencent auth.users(id) : supprimer VRAIMENT la ligne casserait
--     l'accès des ACHETEURS aux jeux d'un créateur qui se supprime.
--   - Les jeux publiés par un créateur qui se supprime restent en vente
--     (validé : "tu les laisse publique tqt") — juste attribués à
--     "Compte supprimé" au lieu de son vrai pseudo.
--   - Bouton dans Paramètres (validé : "oui paramètre"), avec retape du
--     mot de passe pour confirmer avant d'appeler ceci.
--
-- Cette fonction fait la partie "base de données" (anonymise le profil).
-- La partie "verrouille le compte pour de vrai" (email, mot de passe,
-- bannissement de connexion) est faite par la fonction Edge
-- delete-account, qui appelle CETTE fonction puis utilise l'API Admin
-- Auth (nécessite la service role key, indisponible en SQL pur).
-- ============================================================

alter table public.profiles add column if not exists deleted_at timestamptz;

drop function if exists public.anonymize_my_account();
create or replace function public.anonymize_my_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_player_number bigint;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select player_number into v_player_number from public.profiles where id = v_uid;

  -- Pseudo technique rendu unique via player_number (déjà unique par
  -- construction, migration_4_tag_pseudo.sql) — `username` a une
  -- contrainte UNIQUE globale (schema.sql), impossible de mettre la même
  -- valeur littérale pour tout le monde. `display_name` (pas contraint,
  -- affiché en priorité partout via coalesce(display_name, username, ...))
  -- porte le texte lisible "Compte supprimé".
  update public.profiles
    set username = 'compte-supprime-' || coalesce(v_player_number::text, v_uid::text),
        display_name = 'Compte supprimé',
        avatar_url = null,
        banner_url = null,
        signup_device_id = null,
        signup_ip = null,
        is_private = true,
        deleted_at = now()
    where id = v_uid;

  -- Nettoyage d'une éventuelle demande de retrait PayPal encore visible
  -- (l'email PayPal est une donnée personnelle) — l'historique du
  -- montant/statut reste (comptabilité), seul l'email est effacé.
  update public.withdrawal_requests set paypal_email = 'compte-supprime@izacki.local' where seller_id = v_uid;
end;
$$;
grant execute on function public.anonymize_my_account() to authenticated;

notify pgrst, 'reload schema';
