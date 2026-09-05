-- ============================================================
-- Izacki — Migration 28 : le prix d'un jeu soumis est en CRÉDITS, pas en
-- euros (05/09/2026, demande explicite : "le prix doit être en crédit").
-- Simplifie énormément la Phase 2 (achat) : plus besoin de Stripe Connect
-- ni de compte bancaire par vendeur — un achat déplace juste des crédits
-- (déjà achetés via Stripe côté joueur) du solde de l'acheteur vers celui
-- du vendeur, moins la commission de 3%, en une transaction interne.
-- À exécuter UNE FOIS dans Supabase.
-- ============================================================

alter table public.submitted_games rename column price_cents to price_credits;

drop function if exists public.admin_list_pending_games();
create function public.admin_list_pending_games()
returns table(
  id uuid, seller_id uuid, seller_email text, title text, description text,
  price_credits int, file_type text, file_path text, file_size_bytes bigint,
  screenshot_paths text[], created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select lower(trim(au.email)) from auth.users au where au.id = auth.uid()) is distinct from 'ferra.izacki@gmail.com' then
    raise exception 'forbidden';
  end if;
  return query
    select sg.id, sg.seller_id, u.email::text, sg.title, sg.description, sg.price_credits,
           sg.file_type, sg.file_path, sg.file_size_bytes, sg.screenshot_paths, sg.created_at
    from public.submitted_games sg
    join auth.users u on u.id = sg.seller_id
    where sg.status = 'pending'
    order by sg.created_at asc;
end;
$$;
grant execute on function public.admin_list_pending_games() to authenticated;
