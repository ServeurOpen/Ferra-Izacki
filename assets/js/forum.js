
async function ferraFetchCategories() {
  const { data: categories, error } = await window.supabaseClient
    .from('categories')
    .select('*')
    .order('sort_order', { ascending: true });
  if (error) throw error;

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
  const lang = (typeof ferraI18nCurrentLang === 'function') ? ferraI18nCurrentLang() : 'fr';
  const locale = { fr: 'fr-FR', en: 'en-US', es: 'es-ES' }[lang] || 'fr-FR';
  const joiner = { fr: 'à', en: 'at', es: 'a las' }[lang] || 'à';
  return d.toLocaleDateString(locale, { day: 'numeric', month: 'short', year: 'numeric' }) +
    ' ' + joiner + ' ' + d.toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit' });
}

function ferraInitials(name) {
  return (name || '?').trim().slice(0, 2).toUpperCase();
}

function ferraCategoryIcon(slug) {
  const icons = { annonces: 'megaphone', general: 'chat', support: 'help', idees: 'bulb' };
  return Object.prototype.hasOwnProperty.call(icons, slug) ? icons[slug] : 'chat';
}

function ferraStateHtml(title, text, opts) {
  const o = opts || {};
  const icon = o.icon || (o.err ? 'error' : 'box');
  const action = o.action ? `<div class="actions"><a class="btn btn--outline btn--sm" href="${o.action.href}">${o.action.label}</a></div>` : '';
  return `<div class="state${o.err ? ' state--err' : ''}"><div class="state__icon">${ferraIconHtml(icon)}</div><div><h2 class="t-h3">${title}</h2>${text ? `<p>${text}</p>` : ''}${action}</div></div>`;
}

function ferraCategoryHtml(cat, name, desc, word) {
  return `<li class="topic"><a class="topic__link" href="category.html?slug=${encodeURIComponent(cat.slug)}"><span class="topic__icon">${ferraIconHtml(ferraCategoryIcon(cat.slug))}</span><span class="topic__main"><span class="topic__title">${ferraEscape(name)}</span>${desc ? `<span class="topic__desc">${ferraEscape(desc)}</span>` : ''}</span><span class="topic__count"><b>${cat.threadCount}</b>${word}</span></a></li>`;
}

function ferraTopicHtml(thread, by, pinned, word) {
  const who = ferraEscape(thread.profiles?.username || ferraT('nav.defaultPlayer', 'Joueur'));
  const badge = thread.pinned ? `<span class="badge badge--info badge--plain">${pinned}</span>` : '';
  return `<li class="topic topic--thread"><a class="topic__link" href="thread.html?id=${encodeURIComponent(thread.id)}"><span class="topic__main"><span class="topic__title">${ferraEscape(thread.title)}${badge}</span><span class="topic__meta"><span>${by} ${who}</span><span>${ferraFormatDate(thread.created_at)}</span></span></span><span class="topic__count"><b>${thread.replyCount}</b>${word}</span></a></li>`;
}

function ferraPostHtml(post) {
  const name = post.profiles?.username || ferraT('nav.defaultPlayer', 'Joueur');
  return `<article class="post"><div class="post__who"><span class="avatar avatar--lg" aria-hidden="true">${ferraEscape(ferraInitials(post.profiles?.username))}</span><span class="post__name">${ferraEscape(name)}</span></div><div class="post__body"><time class="post__date" datetime="${ferraEscape(post.created_at)}">${ferraFormatDate(post.created_at)}</time><div class="post__text">${ferraEscape(post.content)}</div></div></article>`;
}
