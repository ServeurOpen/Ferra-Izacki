-- ============================================================
-- FERRA — Schéma du forum (Supabase / Postgres)
-- À exécuter UNE FOIS dans Supabase : Dashboard -> SQL Editor -> New query
-- -> colle tout ce fichier -> Run.
-- ============================================================

-- ---- Profils joueurs (1 par compte, créé automatiquement à l'inscription) ----
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "Les profils sont visibles par tous"
  on public.profiles for select
  using (true);

create policy "Un joueur peut modifier son propre profil"
  on public.profiles for update
  using (auth.uid() = id);

-- Crée automatiquement un profil quand quelqu'un s'inscrit (le pseudo est
-- passé depuis le site au moment de l'inscription, voir assets/js/auth.js).
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, username)
  values (new.id, coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)));
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ---- Catégories du forum ----
create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name text not null,
  description text,
  icon text not null default '💬',
  sort_order int not null default 0
);

alter table public.categories enable row level security;

create policy "Les catégories sont visibles par tous"
  on public.categories for select
  using (true);

-- Catégories de départ — modifiables/ajoutables ensuite depuis le Table
-- Editor de Supabase, aucun code à toucher.
insert into public.categories (slug, name, description, icon, sort_order) values
  ('annonces',   'Annonces',           'Les nouvelles officielles de FERRA.',                 '📣', 0),
  ('general',    'Discussion générale', 'Parle du jeu, partage tes parties, pose tes questions.', '💬', 1),
  ('support',    'Support & bugs',     'Un souci au lancement ou en jeu ? Décris-le ici.',    '🛠️', 2),
  ('idees',      'Idées & suggestions', 'Propose ce que tu aimerais voir dans FERRA.',         '💡', 3)
on conflict (slug) do nothing;

-- ---- Sujets ----
create table if not exists public.threads (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.categories(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  created_at timestamptz not null default now(),
  pinned boolean not null default false
);

alter table public.threads enable row level security;

create policy "Les sujets sont visibles par tous"
  on public.threads for select
  using (true);

create policy "Un joueur connecté peut créer un sujet"
  on public.threads for insert
  with check (auth.uid() = author_id);

-- ---- Messages (le premier message d'un sujet ET toutes les réponses) ----
create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.threads(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  content text not null,
  created_at timestamptz not null default now()
);

alter table public.posts enable row level security;

create policy "Les messages sont visibles par tous"
  on public.posts for select
  using (true);

create policy "Un joueur connecté peut répondre"
  on public.posts for insert
  with check (auth.uid() = author_id);

-- Index utiles (listes de sujets/messages triées par date, souvent filtrées par sujet/catégorie).
create index if not exists idx_threads_category on public.threads(category_id, created_at desc);
create index if not exists idx_posts_thread on public.posts(thread_id, created_at asc);
