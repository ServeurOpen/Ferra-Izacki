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
      .select('id, username, admin_mode_disabled')
      .eq('id', user.id)
      .single();
    return { user, profile };
  } catch (err) {
    console.error('[FERRA] ferraGetSession a échoué (Supabase non configuré ou hors ligne) :', err);
    return null;
  }
}

// ============================================================
// Mode Admin sur le site (05/09/2026, demande explicite : "on est
// directement en mode Administrateur qui pareil peut être désactivé dans
// l'onglet paramètre du site... si on désactive pour réactiver il faut
// mettre un mdp") — même compte/mêmes principes que le Launcher :
//   - ferra.izacki@gmail.com est TOUJOURS en mode admin par défaut
//     (visuel violet + badge), sauf s'il l'a désactivé lui-même
//     (admin_mode_disabled=true en base, voir migration_14).
//   - Désactiver ne demande rien (juste un update de son propre profil).
//   - Réactiver EXIGE le bon mot de passe, vérifié côté serveur (voir
//     supabase/functions/verify-admin-password) — jamais en clair ici.
// ============================================================
const FERRA_ADMIN_EMAILS = ['ferra.izacki@gmail.com'];
function ferraIsAdminEmail(session) {
  return !!session && FERRA_ADMIN_EMAILS.includes((session.user.email || '').trim().toLowerCase());
}
function ferraIsAdminModeActive(session) {
  return ferraIsAdminEmail(session) && !session.profile?.admin_mode_disabled;
}
// Appelée sur CHAQUE page (voir ferraRenderNavAuth) — retinte tout le site
// d'un coup via les 2 variables CSS d'accent déjà utilisées partout (voir
// body.admin-mode dans style.css), pas besoin de retoucher un composant.
function ferraApplyAdminModeStyling(session) {
  document.body.classList.toggle('admin-mode', ferraIsAdminModeActive(session));
}
async function ferraDisableAdminMode(userId) {
  await window.supabaseClient.from('profiles').update({ admin_mode_disabled: true }).eq('id', userId);
}
// Renvoie true si le mot de passe était bon (et réactive alors le mode
// admin sur le profil), false sinon — jamais lancé côté client seul.
async function ferraReenableAdminMode(userId, password) {
  const { data: { session: authSession } } = await window.supabaseClient.auth.getSession();
  const token = authSession?.access_token;
  if (!token) return false;
  try {
    const res = await fetch(`${window.FERRA_CONFIG.SUPABASE_URL}/functions/v1/verify-admin-password`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ password }),
    });
    if (!res.ok) return false;
    const body = await res.json();
    if (!body.valid) return false;
    await window.supabaseClient.from('profiles').update({ admin_mode_disabled: false }).eq('id', userId);
    return true;
  } catch (err) {
    console.error('[FERRA] ferraReenableAdminMode a échoué :', err);
    return false;
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

// Vérifie si un pseudo est déjà pris (insensible à la casse — "Test" et
// "test" comptent comme le même pseudo, cf. la contrainte SQL + la
// comparaison lower() de get_email_by_username). Utilisée AVANT
// l'inscription pour donner un message clair tout de suite : le message
// d'erreur renvoyé par Supabase quand le pseudo est en doublon est un
// générique "Database error saving new user" (le trigger handle_new_user
// échoue sur la contrainte unique de profiles.username) qui ne dit pas du
// tout à l'utilisateur ce qui a coincé.
async function ferraUsernameTaken(username) {
  const { data } = await window.supabaseClient
    .from('profiles')
    .select('id')
    .ilike('username', username)
    .limit(1)
    .maybeSingle();
  return !!data;
}

async function ferraSignUp(email, password, username, displayName) {
  if (!ferraValidateUsername(username)) {
    return { error: { message: 'invalid_username' } };
  }
  if (await ferraUsernameTaken(username)) {
    return { error: { message: 'username_taken' } };
  }
  return window.supabaseClient.auth.signUp({
    email,
    password,
    options: { data: { username, display_name: (displayName || '').trim() || undefined } },
  });
}

async function ferraSignIn(email, password) {
  return window.supabaseClient.auth.signInWithPassword({ email, password });
}

// ============================================================
// Parrainage (05/09/2026) — voir migration_18_parrainage.sql. Le tag du
// parrain (format "Pseudo#123") n'est associé qu'APRÈS un signUp() réussi
// (il faut déjà une session pour appeler set_referral, en security
// definer) — jamais au moment du formulaire lui-même. `referralTag` peut
// être vide (inscription sans parrainage), c'est le cas normal.
// ============================================================
function ferraGetDeviceId() {
  try {
    let id = localStorage.getItem('ferra_device_id');
    if (!id) {
      id = 'dev_' + Math.random().toString(36).slice(2) + Date.now().toString(36);
      localStorage.setItem('ferra_device_id', id);
    }
    return id;
  } catch {
    return null;
  }
}

// Jamais bloquant pour l'inscription : chaque étape est dans son propre
// try/catch silencieux, un souci ici ne doit jamais empêcher le compte
// tout neuf de fonctionner normalement.
async function ferraApplyReferral(referralTag) {
  try {
    const deviceId = ferraGetDeviceId();
    if (deviceId) await window.supabaseClient.rpc('record_signup_device', { p_device_id: deviceId });
  } catch (err) {
    console.error('[FERRA] record_signup_device a échoué :', err);
  }
  try {
    const { data: { session } } = await window.supabaseClient.auth.getSession();
    const token = session?.access_token;
    if (token && window.FERRA_CONFIG) {
      await fetch(`${window.FERRA_CONFIG.SUPABASE_URL}/functions/v1/record-signup-ip`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}` },
      });
    }
  } catch (err) {
    console.error('[FERRA] record-signup-ip a échoué :', err);
  }
  try {
    const match = referralTag ? /^(.+)#(\d+)$/.exec(referralTag.trim()) : null;
    if (match) {
      const [, username, numberStr] = match;
      await window.supabaseClient.rpc('set_referral', { p_username: username.trim(), p_number: Number(numberStr) });
    }
  } catch (err) {
    console.error('[FERRA] set_referral a échoué :', err);
  }
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
  await ferraSignOutTo('index.html');
}

// Déconnexion générique avec redirection paramétrable — utilisée par le
// widget de connexion du menu (ferraRenderNavAuth), présent sur TOUTES les
// pages du site (pas que le forum), donc 'index.html' seul ne suffit pas :
// depuis games/ferra.html par exemple, il faut '../index.html'.
async function ferraSignOutTo(redirectPath) {
  await window.supabaseClient.auth.signOut();
  window.location.href = redirectPath;
}

// ============================================================
// Statistiques du site — visite (05/09/2026, demande explicite : "nombre de
// visite sur le site"). Volontairement discret : un simple insert
// fire-and-forget (jamais attendu, jamais bloquant pour l'affichage de la
// page, et une erreur réseau/RLS ne doit jamais casser le rendu du menu qui
// l'appelle) — voir migration_16_site_analytics.sql pour ce qui est
// réellement stocké (juste le chemin, l'heure, et l'id du compte SI
// connecté). Appelée une seule fois par page depuis ferraRenderNavAuth
// (déjà exécutée sur TOUTES les pages), pas besoin d'un script séparé à
// ajouter partout.
// ============================================================
function ferraLogVisit(session) {
  try {
    window.supabaseClient
      .from('site_visits')
      .insert({ path: location.pathname, user_id: session?.user?.id || null })
      .then(() => {}, () => {});
  } catch (err) {
    // Silencieux à dessein — une visite non comptée n'est jamais une
    // raison de perturber le joueur.
  }
}

// Widget compact "Connexion / Inscription" affiché en haut à droite du menu
// sur TOUTES les pages du site (voir .nav-auth dans style.css) — même
// compte que le forum et, à terme, le Launcher : plus besoin d'aller sur le
// forum juste pour se connecter. `prefix` vaut '' depuis une page à la
// racine du site, '../' depuis une page dans un sous-dossier (games/, forum/).
async function ferraRenderNavAuth(elId, prefix) {
  const el = document.getElementById(elId);
  if (!el) return;
  prefix = prefix || '';
  const session = await ferraGetSession();
  ferraApplyAdminModeStyling(session);
  ferraLogVisit(session);
  if (session) {
    const adminBadge = ferraIsAdminModeActive(session) ? `<span class="admin-mode-badge">🛡️ Admin</span>` : '';
    // Lien Panel (05/09/2026) — visible UNIQUEMENT en mode admin actif,
    // jamais pour un joueur normal même si son email était par erreur dans
    // FERRA_ADMIN_EMAILS (impossible ici, mais même logique de prudence que
    // partout ailleurs) : la vraie protection reste côté serveur
    // (admin-site-stats revérifie l'email), ce lien n'est qu'un raccourci.
    const panelLink = ferraIsAdminModeActive(session)
      ? `<a href="${prefix}panel.html" class="nav-link">${ferraT('nav.panel', '📊 Panel')}</a>`
      : '';
    el.innerHTML = `
      <span class="nav-auth-user">👤 <b>${ferraEscape(session.profile?.username || ferraT('nav.defaultPlayer', 'Joueur'))}</b>${adminBadge}</span>
      ${panelLink}
      <a href="${prefix}parametres.html" class="nav-link">${ferraT('nav.settings', '⚙ Paramètres')}</a>
      <button class="nav-auth-logout" id="ferraNavLogoutBtn">${ferraT('nav.logout', 'Déconnexion')}</button>
    `;
    document.getElementById('ferraNavLogoutBtn').addEventListener('click', () => ferraSignOutTo(prefix + 'index.html'));
  } else {
    el.innerHTML = `
      <a href="${prefix}forum/login.html" class="nav-link">${ferraT('nav.connexion', 'Connexion')}</a>
      <a href="${prefix}forum/signup.html" class="nav-auth-signup">${ferraT('nav.inscription', 'Inscription')}</a>
    `;
  }
}

// Petit widget "connecté en tant que X / Se connecter" affiché en haut de
// chaque page du forum (voir #forumUserWidget dans le HTML) — un seul point
// de rendu, réutilisé partout pour ne jamais désynchroniser l'affichage.
async function ferraRenderUserWidget(elId) {
  const el = document.getElementById(elId);
  if (!el) return null;
  const session = await ferraGetSession();
  ferraApplyAdminModeStyling(session);
  if (session) {
    el.innerHTML = `
      <span class="forum-user">👤 ${ferraT('forum.connectedAs', 'Connecté en tant que')} <b>${ferraEscape(session.profile?.username || ferraT('nav.defaultPlayer', 'Joueur'))}</b></span>
      <button class="btn btn-ghost btn-sm" id="ferraLogoutBtn">${ferraT('forum.logout', 'Se déconnecter')}</button>
    `;
    document.getElementById('ferraLogoutBtn').addEventListener('click', ferraSignOut);
  } else {
    el.innerHTML = `
      <a href="${ferraForumPath('login.html')}" class="btn btn-ghost btn-sm">${ferraT('nav.login', 'Se connecter')}</a>
      <a href="${ferraForumPath('signup.html')}" class="btn btn-primary btn-sm">${ferraT('nav.signup', 'Créer un compte')}</a>
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
