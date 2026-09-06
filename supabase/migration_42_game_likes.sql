-- ============================================================
-- Izacki — Migration 42 : likes sur les jeux du marketplace (06/09/2026,
-- demande explicite) — cœur cliquable (blanc = pas liké, rouge = liké),
-- compteur visible par tous sur la carte du jeu (Boutique/Mes jeux).
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_41.
-- ============================================================

create table if not exists public.game_likes (
  user_id uuid not null references auth.users(id) on delete cascade,
  game_id uuid not null references public.submitted_games(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, game_id)
);
create index if not exists game_likes_game_idx on public.game_likes (game_id);
alter table public.game_likes enable row level security;
drop policy if exists "Les likes sont visibles par tous" on public.game_likes;
create policy "Les likes sont visibles par tous"
  on public.game_likes for select
  using (true);
-- Pas de policy insert/delete pour "authenticated" : seule
-- toggle_game_like (security definer) écrit ici.

create or replace function public.toggle_game_like(p_game_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_liked boolean;
  v_count int;
begin
  if exists (select 1 from public.game_likes where user_id = auth.uid() and game_id = p_game_id) then
    delete from public.game_likes where user_id = auth.uid() and game_id = p_game_id;
    v_liked := false;
  else
    if not exists (select 1 from public.submitted_games where id = p_game_id and status = 'approved') then
      return jsonb_build_object('ok', false, 'reason', 'game_not_found');
    end if;
    insert into public.game_likes (user_id, game_id) values (auth.uid(), p_game_id);
    v_liked := true;
  end if;
  select count(*) into v_count from public.game_likes where game_id = p_game_id;
  return jsonb_build_object('ok', true, 'liked', v_liked, 'count', v_count);
end;
$$;
grant execute on function public.toggle_game_like(uuid) to authenticated;

-- ---- Realtime (même principe que les tickets) — pour voir le compteur
-- bouger en direct chez les autres joueurs aussi. ----
do $$
begin
  alter publication supabase_realtime add table public.game_likes;
exception when duplicate_object then null;
end $$;

-- ---- Solde de crédits en temps réel (06/09/2026, retour joueur : "j'ai
-- refusé un paiement PayPal, j'ai dû redémarrer le Launcher pour ravoir
-- mon argent, c'est pas possible en realtime ?") — jusqu'ici `profiles`
-- n'était pas dans la publication Realtime : un retrait refusé/un
-- remboursement traité changeait bien le solde en base, mais le Launcher
-- ne le voyait qu'au prochain rafraîchissement explicite (boot...). ----
do $$
begin
  alter publication supabase_realtime add table public.profiles;
exception when duplicate_object then null;
end $$;
