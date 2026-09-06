-- ============================================================
-- Izacki — Migration 48 : économie de profil, tokens (06/09/2026, demande
-- explicite : "chaque minute jouée [...] donne des tokens au joueur [...]
-- catégorie PROFIL [...] on y dépense ses tokens pour acheter des
-- bannières/logos [...] plus moyen de les choisir librement [...] ni
-- d'importer sa propre image").
--
-- Prix retenus en chat le 06/09/2026 (différenciés, "un peu plus" que le
-- 1er jet de 50 — "50 tokens c'est 50min de jeu mais au moins 1h") :
--   Palier 1 : 75 tokens (~1h15)   Palier 2 : 120 tokens (~2h)
--   Palier 3 : 200 tokens (~3h20)
-- Appliqué identiquement aux 3 bannières et aux 3 avatars (dans l'ordre
-- où ils sont déjà proposés côté Launcher).
--
-- Rétrocompatibilité (demandée) : un joueur qui a DÉJÀ un preset équipé
-- aujourd'hui le garde acquis gratuitement (backfill ci-dessous) — seul
-- un CHANGEMENT vers un autre preset passera par la Boutique.
--
-- Tokens gagnés SEULEMENT à partir de maintenant (pas de rattrapage
-- rétroactif sur le temps déjà joué) : plus simple, et évite un windfall
-- initial déséquilibré. 1 token / minute, restes de secondes reportés
-- d'une session à l'autre (token_playtime_remainder_secs) pour ne jamais
-- perdre de temps de jeu entre 2 petites sessions.
-- À exécuter UNE FOIS dans Supabase, APRÈS migration_47.
-- ============================================================

alter table public.profiles add column if not exists tokens integer not null default 0;
alter table public.profiles add column if not exists token_playtime_remainder_secs integer not null default 0;

-- ---- Catalogue des visuels achetables — table de PROPRIÉTÉ (pas de
-- catalogue de prix ici, les prix sont volontairement codés en dur dans
-- purchase_profile_cosmetic ci-dessous pour ne jamais faire confiance à
-- un prix envoyé par le client). ----
create table if not exists public.profile_cosmetic_purchases (
  user_id uuid not null references auth.users(id) on delete cascade,
  asset_url text not null,
  purchased_at timestamptz not null default now(),
  primary key (user_id, asset_url)
);
alter table public.profile_cosmetic_purchases enable row level security;
drop policy if exists "Un joueur voit ses propres achats de visuels" on public.profile_cosmetic_purchases;
create policy "Un joueur voit ses propres achats de visuels"
  on public.profile_cosmetic_purchases for select
  using (auth.uid() = user_id);
-- Pas de policy insert/update : seule purchase_profile_cosmetic (security
-- definer) y écrit.

-- ---- Garde-fou : impossible d'équiper un visuel payant sans le
-- posséder, MÊME en passant par l'update direct de profiles utilisé
-- aujourd'hui par updateMyProfile() côté client (le trigger s'applique
-- quel que soit le chemin, RPC security definer inclus — il suffit que
-- purchase_profile_cosmetic() enregistre la propriété AVANT de faire
-- l'update pour que ce même trigger le laisse passer). ----
create or replace function public._check_profile_cosmetic_ownership()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_controlled_avatars text[] := array['presets/avatar-azure.svg', 'presets/avatar-emerald.svg', 'presets/avatar-crimson.svg'];
  v_controlled_banners text[] := array['presets/banner-copper.svg', 'presets/banner-forge.svg', 'presets/banner-nebula.svg'];
begin
  if new.avatar_url is distinct from old.avatar_url
     and new.avatar_url = any(v_controlled_avatars)
     and not exists (select 1 from public.profile_cosmetic_purchases where user_id = new.id and asset_url = new.avatar_url) then
    raise exception 'cosmetic_not_owned';
  end if;
  if new.banner_url is distinct from old.banner_url
     and new.banner_url = any(v_controlled_banners)
     and not exists (select 1 from public.profile_cosmetic_purchases where user_id = new.id and asset_url = new.banner_url) then
    raise exception 'cosmetic_not_owned';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_check_profile_cosmetic_ownership on public.profiles;
create trigger trg_check_profile_cosmetic_ownership
  before update of avatar_url, banner_url on public.profiles
  for each row execute function public._check_profile_cosmetic_ownership();

-- ---- Rétrocompatibilité : le preset actuellement équipé par chacun
-- devient "possédé" gratuitement (une seule fois, ci-dessous). ----
insert into public.profile_cosmetic_purchases (user_id, asset_url)
  select id, avatar_url from public.profiles
  where avatar_url in ('presets/avatar-azure.svg', 'presets/avatar-emerald.svg', 'presets/avatar-crimson.svg')
  on conflict do nothing;
insert into public.profile_cosmetic_purchases (user_id, asset_url)
  select id, banner_url from public.profiles
  where banner_url in ('presets/banner-copper.svg', 'presets/banner-forge.svg', 'presets/banner-nebula.svg')
  on conflict do nothing;

-- ---- add_playtime étendue : corps IDENTIQUE à migration_5 (cumul dans
-- game_stats), plus le versement de tokens. Signature inchangée, pas de
-- DROP nécessaire. ----
create or replace function public.add_playtime(p_game_id text, p_secs bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total_for_tokens bigint;
  v_new_tokens bigint;
  v_remainder bigint;
begin
  insert into public.game_stats (user_id, game_id, total_secs, last_played_at)
  values (auth.uid(), p_game_id, greatest(p_secs, 0), now())
  on conflict (user_id, game_id)
    do update set total_secs = public.game_stats.total_secs + greatest(p_secs, 0), last_played_at = now();

  select token_playtime_remainder_secs + greatest(p_secs, 0) into v_total_for_tokens
    from public.profiles where id = auth.uid();
  if v_total_for_tokens is not null then
    v_new_tokens := v_total_for_tokens / 60;
    v_remainder := v_total_for_tokens % 60;
    update public.profiles
      set tokens = tokens + v_new_tokens, token_playtime_remainder_secs = v_remainder
      where id = auth.uid();
  end if;
end;
$$;
grant execute on function public.add_playtime(text, bigint) to authenticated;

-- ---- Achat/équipement d'un visuel de la boutique PROFIL. Un visuel déjà
-- possédé s'équipe gratuitement (permet aussi de re-basculer entre 2
-- visuels déjà achetés sans repayer). ----
create or replace function public.purchase_profile_cosmetic(p_asset_url text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_price int;
  v_kind text;
  v_tokens int;
  v_already_owned boolean;
begin
  case p_asset_url
    when 'presets/avatar-azure.svg'   then v_price := 75;  v_kind := 'avatar';
    when 'presets/avatar-emerald.svg' then v_price := 120; v_kind := 'avatar';
    when 'presets/avatar-crimson.svg' then v_price := 200; v_kind := 'avatar';
    when 'presets/banner-copper.svg'  then v_price := 75;  v_kind := 'banner';
    when 'presets/banner-forge.svg'   then v_price := 120; v_kind := 'banner';
    when 'presets/banner-nebula.svg'  then v_price := 200; v_kind := 'banner';
    else return jsonb_build_object('ok', false, 'reason', 'unknown_cosmetic');
  end case;

  select exists(
    select 1 from public.profile_cosmetic_purchases where user_id = auth.uid() and asset_url = p_asset_url
  ) into v_already_owned;

  if not v_already_owned then
    select tokens into v_tokens from public.profiles where id = auth.uid();
    if coalesce(v_tokens, 0) < v_price then
      return jsonb_build_object('ok', false, 'reason', 'not_enough_tokens', 'needed', v_price, 'have', coalesce(v_tokens, 0));
    end if;
    update public.profiles set tokens = tokens - v_price where id = auth.uid();
    insert into public.profile_cosmetic_purchases (user_id, asset_url) values (auth.uid(), p_asset_url) on conflict do nothing;
  end if;

  if v_kind = 'avatar' then
    update public.profiles set avatar_url = p_asset_url where id = auth.uid();
  else
    update public.profiles set banner_url = p_asset_url where id = auth.uid();
  end if;

  select tokens into v_tokens from public.profiles where id = auth.uid();
  return jsonb_build_object('ok', true, 'alreadyOwned', v_already_owned, 'price', v_price, 'newTokenBalance', v_tokens);
end;
$$;
grant execute on function public.purchase_profile_cosmetic(text) to authenticated;

-- ---- Liste des visuels déjà possédés par l'appelant (Paramètres :
-- n'afficher que ceux-ci en équipement rapide gratuit). ----
create or replace function public.get_my_owned_cosmetics()
returns table(asset_url text)
language sql
security definer
set search_path = public
as $$
  select asset_url from public.profile_cosmetic_purchases where user_id = auth.uid();
$$;
grant execute on function public.get_my_owned_cosmetics() to authenticated;

NOTIFY pgrst, 'reload schema';
