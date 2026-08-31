// ============================================================
// FERRA — Authentification du forum (inscription/connexion/déconnexion),
// partagée par toutes les pages du forum. Repose sur Supabase Auth
// (email + mot de passe) — voir assets/js/supabase-client.js.
// ============================================================

// Récupère l'utilisateur connecté (ou null) + son profil (pseudo) associé.
// Utilisé par chaque page du forum pour savoir qui écrit/répond.
// Volontairement protégée par un try/catch : tant que Supabase n'est pas
// configuré (ou en cas de coupure réseau), l'appel réseau échoue — sans
// ça, chaque page appelante plantait en entier (voir ferraRenderUserWidget,
// appelée sans garde en tête de chaque page du forum) au lieu d'afficher
// son propre message "pas encore configuré/erreur de chargement".
async function ferraGetSession() {
  try {
    const { data: { user } } = await window.supabaseClient.auth.getUser();
    if (!user) return null;
    const { data: profile } = await window.supabaseClient
      .from('profiles')
      .select('id, username')
      .eq('id', user.id)
      .single();
    return { user, profile };
  } catch (err) {
    console.error('[FERRA] ferraGetSession a échoué (Supabase non configuré ou hors ligne) :', err);
    return null;
  }
}

async function ferraSignUp(email, password, username) {
  return window.supabaseClient.auth.signUp({
    email,
    password,
    options: { data: { username } },
  });
}

async function ferraSignIn(email, password) {
  return window.supabaseClient.auth.signInWithPassword({ email, password });
}

async function ferraSignOut() {
  await window.supabaseClient.auth.signOut();
  window.location.href = 'index.html';
}

// Petit widget "connecté en tant que X / Se connecter" affiché en haut de
// chaque page du forum (voir #forumUserWidget dans le HTML) — un seul point
// de rendu, réutilisé partout pour ne jamais désynchroniser l'affichage.
async function ferraRenderUserWidget(elId) {
  const el = document.getElementById(elId);
  if (!el) return null;
  const session = await ferraGetSession();
  if (session) {
    el.innerHTML = `
      <span class="forum-user">👤 Connecté en tant que <b>${ferraEscape(session.profile?.username || 'Joueur')}</b></span>
      <button class="btn btn-ghost btn-sm" id="ferraLogoutBtn">Se déconnecter</button>
    `;
    document.getElementById('ferraLogoutBtn').addEventListener('click', ferraSignOut);
  } else {
    el.innerHTML = `
      <a href="${ferraForumPath('login.html')}" class="btn btn-ghost btn-sm">Se connecter</a>
      <a href="${ferraForumPath('signup.html')}" class="btn btn-primary btn-sm">Créer un compte</a>
    `;
  }
  return session;
}

// Échappement HTML minimal — TOUT contenu utilisateur (pseudo, titre de
// sujet, message) passe par ici avant d'être injecté en innerHTML, pour
// qu'un joueur ne puisse jamais casser la mise en page (ou pire) avec du
// HTML dans son message.
function ferraEscape(str) {
  const div = document.createElement('div');
  div.textContent = str == null ? '' : String(str);
  return div.innerHTML;
}

// Les pages du forum vivent à 2 profondeurs différentes (forum/index.html
// vs forum/thread.html, qui restent au même niveau en réalité) — gardé en
// fonction à part au cas où la structure bougerait plus tard.
function ferraForumPath(page) {
  return page;
}
