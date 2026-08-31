// ============================================================
// FERRA — Accès aux données du forum (catégories/sujets/messages), voir
// supabase/schema.sql pour la structure des tables. Chaque fonction
// renvoie directement les données (ou lève une erreur Supabase) — les
// pages appelantes gèrent l'affichage/les erreurs à leur façon.
// ============================================================

async function ferraFetchCategories() {
  const { data: categories, error } = await window.supabaseClient
    .from('categories')
    .select('*')
    .order('sort_order', { ascending: true });
  if (error) throw error;

  // Nombre de sujets par catégorie — un compte séparé par catégorie (peu
  // de catégories, largement acceptable plutôt qu'une jointure complexe).
  const withCounts = await Promise.all(categories.map(async (cat) => {
    const { count } = await window.supabaseClient
      .from('threads')
      .select('id', { count: 'exact', head: true })
      .eq('category_id', cat.id);
    return { ...cat, threadCount: count || 0 };
  }));
  return withCounts;
}

async function ferraFetchCategoryBySlug(slug) {
  const { data, error } = await window.supabaseClient
    .from('categories')
    .select('*')
    .eq('slug', slug)
    .single();
  if (error) throw error;
  return data;
}

async function ferraFetchThreads(categoryId) {
  const { data: threads, error } = await window.supabaseClient
    .from('threads')
    .select('id, title, created_at, pinned, author_id, profiles(username)')
    .eq('category_id', categoryId)
    .order('pinned', { ascending: false })
    .order('created_at', { ascending: false });
  if (error) throw error;

  const withCounts = await Promise.all(threads.map(async (t) => {
    const { count } = await window.supabaseClient
      .from('posts')
      .select('id', { count: 'exact', head: true })
      .eq('thread_id', t.id);
    return { ...t, replyCount: Math.max(0, (count || 1) - 1) };
  }));
  return withCounts;
}

async function ferraFetchThread(threadId) {
  const { data, error } = await window.supabaseClient
    .from('threads')
    .select('id, title, created_at, category_id, author_id, profiles(username), categories(name, slug)')
    .eq('id', threadId)
    .single();
  if (error) throw error;
  return data;
}

async function ferraFetchPosts(threadId) {
  const { data, error } = await window.supabaseClient
    .from('posts')
    .select('id, content, created_at, author_id, profiles(username)')
    .eq('thread_id', threadId)
    .order('created_at', { ascending: true });
  if (error) throw error;
  return data;
}

// Crée un sujet ET son tout premier message en une seule opération —
// jamais un sujet vide sans message d'ouverture.
async function ferraCreateThread(categoryId, authorId, title, firstMessage) {
  const { data: thread, error: threadErr } = await window.supabaseClient
    .from('threads')
    .insert({ category_id: categoryId, author_id: authorId, title })
    .select()
    .single();
  if (threadErr) throw threadErr;

  const { error: postErr } = await window.supabaseClient
    .from('posts')
    .insert({ thread_id: thread.id, author_id: authorId, content: firstMessage });
  if (postErr) throw postErr;

  return thread;
}

async function ferraCreatePost(threadId, authorId, content) {
  const { data, error } = await window.supabaseClient
    .from('posts')
    .insert({ thread_id: threadId, author_id: authorId, content })
    .select()
    .single();
  if (error) throw error;
  return data;
}

function ferraFormatDate(iso) {
  const d = new Date(iso);
  return d.toLocaleDateString('fr-FR', { day: 'numeric', month: 'short', year: 'numeric' }) +
    ' à ' + d.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });
}

function ferraInitials(name) {
  return (name || '?').trim().slice(0, 2).toUpperCase();
}
