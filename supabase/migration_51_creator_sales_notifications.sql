-- ============================================================
-- Notification de ventes pour les créateurs (demande explicite du
-- 06/09/2026) : "vérifie que le joueur recois bien les crédits de c'est
-- jeux acheté même si il était pas co et a sa connexion au lui de lui
-- faire ouvrir un part un. Lui faire un pop up exemple: 5000 crédits
-- gagnés. Puis récap de chaque crédit par achat de ses jeux et du
-- joueur qui a acheté. [...] Ce sera mieux pour les créateurs de gardé
-- le contrôle sur les fonds. Bien inscrire qu'il ont accès a tout sa
-- gratuitement avant même qui le voye par eux même."
--
-- Les crédits sont déjà versés en temps réel dès l'achat (purchase_game,
-- migration_29) — ce n'était donc pas un bug de versement, juste
-- l'ABSENCE de notification pour le créateur si l'acheteur a payé
-- pendant qu'il n'était pas connecté. Ici : un système "vu/pas vu" par
-- créateur (comme les dons du créateur, migration_?/credit_gift_notifications,
-- mais agrégé au lieu d'un pop-up par vente pour ne pas spammer quelqu'un
-- qui a fait 40 ventes pendant son absence).
--
-- IMPORTANT (rappel de la règle posée dans migration_29) : le vendeur ne
-- doit JAMAIS voir l'identité confidentielle de l'acheteur (email, etc.)
-- — seulement son pseudo public "Nom#1234", exactement comme partout
-- ailleurs dans le launcher (classement, amis...).
-- ============================================================

alter table public.profiles add column if not exists sales_last_seen_at timestamptz;

-- Backfill à NOW() pour tous les comptes déjà existants : sans ça, le
-- premier créateur à se reconnecter après cette migration se prendrait
-- d'un coup TOUT son historique de ventes passées comme si c'était
-- "nouveau". Seules les ventes futures (après cette migration) seront
-- notifiées.
update public.profiles set sales_last_seen_at = now() where sales_last_seen_at is null;

drop function if exists public.get_my_unseen_sales();
create or replace function public.get_my_unseen_sales()
returns table (
  purchase_id uuid,
  game_id uuid,
  game_title text,
  amount int,
  buyer_name text,
  purchased_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_since timestamptz;
begin
  select coalesce(sales_last_seen_at, created_at, 'epoch'::timestamptz)
    into v_since
    from public.profiles where id = auth.uid();

  return query
    select
      gp.id,
      gp.game_id,
      sg.title,
      gp.price_credits,
      coalesce(buyer.display_name, buyer.username, 'Joueur') || '#' || buyer.player_number,
      gp.purchased_at
    from public.game_purchases gp
    join public.submitted_games sg on sg.id = gp.game_id
    join public.profiles buyer on buyer.id = gp.buyer_id
    where gp.seller_id = auth.uid()
      and gp.price_credits > 0
      and gp.purchased_at > v_since
    order by gp.purchased_at asc;
end;
$$;
grant execute on function public.get_my_unseen_sales() to authenticated;

drop function if exists public.mark_sales_seen();
create or replace function public.mark_sales_seen()
returns void
language sql
security definer
set search_path = public
as $$
  update public.profiles set sales_last_seen_at = now() where id = auth.uid();
$$;
grant execute on function public.mark_sales_seen() to authenticated;

notify pgrst, 'reload schema';
