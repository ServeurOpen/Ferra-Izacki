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

// Règle des pseudos (compte site = compte forum, un seul et même pseudo
// partout) : lettres/chiffres/underscore uniquement — donc jamais
// d'espace ni de caractère bizarre — et au moins une majuscule. La même
// règle est appliquée côté base de données (voir
// supabase/migration_2_comptes.sql) en filet de sécurité.
const FERRA_USERNAME_REGEX = /^(?=.*[A-Z])[A-Za-z0-9_]{3,24}$/;
const FERRA_USERNAME_RULES = "3 à 24 caractères, lettres/chiffres/underscore uniquement (pas d'espace ni d'accent), avec au moins 1 majuscule.";
function ferraValidateUsername(username) {
  return FERRA_USERNAME_REGEX.test(username || '');
}

async function ferraSignUp(email, password, username) {
  if (!ferraValidateUsername(username)) {
    return { error: { message: 'invalid_username' } };
  }
  return window.supabaseClient.auth.signUp({
    email,
    password,
    options: { data: { username } },
  });
}

async function ferraSignIn(email, password) {
  return window.supabaseClient.auth.signInWithPassword({ email, password });
}

// Connexion par EMAIL OU PSEUDO — un seul champ "identifiant" côté
// formulaire (voir forum/login.html). Un pseudo ne contenant jamais de
// "@" (voir FERRA_USERNAME_REGEX), la présence de "@" suffit à distinguer
// les deux cas sans ambiguïté.
async function ferraSignInWithIdentifier(identifier, password) {
  identifier = (identifier || '').trim();
  let email = identifier;
  if (!identifier.includes('@')) {
    const { data, error } = await window.supabaseClient.rpc('get_email_by_username', { p_username: identifier });
    if (error || !data) {
      // Message volontairement identique à un mot de passe incorrect —
      // ne pas révéler si c'est le pseudo ou le mot de passe qui est faux.
      return { error: { message: 'Invalid login credentials' } };
    }
    email = data;
  }
  return ferraSignIn(email, password);
}

// Mot de passe oublié — étape 1 : envoie un email contenant un lien de
// réinitialisation. Le lien pointe vers reset-password.html, qui contient
// un jeton temporaire dans l'URL ; supabase-js le détecte automatiquement
// à l'ouverture de la page (detectSessionInUrl, activé par défaut) et
// ouvre une session "recovery" le temps de choisir un nouveau mot de passe.
async function ferraSendPasswordReset(email) {
  const redirectTo = window.location.origin + window.location.pathname.replace(/forgot-password\.html$/, 'reset-password.html');
  return window.supabaseClient.auth.resetPasswordForEmail(email, { redirectTo });
}

// Mot de passe oublié — étape 2 : appelée depuis reset-password.html une
// fois que le joueur a choisi son nouveau mot de passe. Nécessite la
// session "recovery" ouverte par le lien reçu par email (voir ci-dessus).
async function ferraUpdatePassword(newPassword) {
  return window.supabaseClient.auth.updateUser({ password: newPassword });
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
