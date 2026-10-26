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
    console.warn('Connexion au compte indisponible.');
    return null;
  }
}

const FERRA_ADMIN_EMAILS = ['ferra.izacki@gmail.com'];
function ferraIsAdminEmail(session) {
  return !!session && FERRA_ADMIN_EMAILS.includes((session.user.email || '').trim().toLowerCase());
}
function ferraIsAdminModeActive(session) {
  return ferraIsAdminEmail(session) && !session.profile?.admin_mode_disabled;
}
function ferraApplyAdminModeStyling(session) {
  document.body.classList.toggle('admin-mode', ferraIsAdminModeActive(session));
}
async function ferraDisableAdminMode(userId) {
  await window.supabaseClient.from('profiles').update({ admin_mode_disabled: true }).eq('id', userId);
}
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
    console.warn('Réactivation impossible pour le moment.');
    return false;
  }
}

const FERRA_USERNAME_REGEX = /^(?=.*[A-Z])[A-Za-z0-9_]{3,24}$/;
const FERRA_USERNAME_RULES = "3 à 24 caractères, lettres/chiffres/underscore uniquement (pas d'espace ni d'accent), avec au moins 1 majuscule.";
function ferraValidateUsername(username) {
  return FERRA_USERNAME_REGEX.test(username || '');
}

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

async function ferraSignInWithIdentifier(identifier, password) {
  identifier = (identifier || '').trim();
  let email = identifier;
  if (!identifier.includes('@')) {
    const { data, error } = await window.supabaseClient.rpc('get_email_by_username', { p_username: identifier });
    if (error || !data) {
      return { error: { message: 'Invalid login credentials' } };
    }
    email = data;
  }
  return ferraSignIn(email, password);
}

async function ferraSendPasswordReset(email) {
  const redirectTo = window.location.origin + window.location.pathname.replace(/forgot-password\.html$/, 'reset-password.html');
  return window.supabaseClient.auth.resetPasswordForEmail(email, { redirectTo });
}

async function ferraUpdatePassword(newPassword) {
  return window.supabaseClient.auth.updateUser({ password: newPassword });
}

async function ferraSignOut() {
  await ferraSignOutTo('index.html');
}

async function ferraSignOutTo(redirectPath) {
  await window.supabaseClient.auth.signOut();
  window.location.href = redirectPath;
}

function ferraLogVisit(session) {
  try {
    window.supabaseClient
      .from('site_visits')
      .insert({ path: location.pathname, user_id: session?.user?.id || null })
      .then(() => {}, () => {});
  } catch (err) {
  }
}

let ferraDevHoursTimer = null;
function ferraStartDevHoursHeartbeat(session) {
  if (ferraDevHoursTimer) clearInterval(ferraDevHoursTimer);
  if (!ferraIsAdminModeActive(session)) return;
  ferraDevHoursTimer = setInterval(() => {
    window.supabaseClient.rpc('log_dev_time', { p_source: 'site', p_secs: 60 }).then(() => {}, () => {});
  }, 60_000);
}

function ferraAssetPrefix() {
  return (window.FERRA_I18N && window.FERRA_I18N.prefix) || ferraNavAuthState.prefix || '';
}

function ferraAuthInitials(name) {
  return (name || '?').trim().slice(0, 2).toUpperCase();
}

function ferraIconHtml(name) {
  return `<svg class="icon" aria-hidden="true" focusable="false"><use href="${ferraAssetPrefix()}assets/img/icons.svg#${name}"/></svg>`;
}

let ferraBanOverlayShown = false;
async function ferraCheckBanAndBlock(session) {
  if (!session || ferraBanOverlayShown) return;
  try {
    const { data } = await window.supabaseClient
      .from('user_bans')
      .select('reason, banned_until, scope')
      .eq('user_id', session.user.id)
      .maybeSingle();
    if (!data) return;
    if (data.scope !== 'site' && data.scope !== 'both') return;
    if (data.banned_until && new Date(data.banned_until).getTime() <= Date.now()) return;
    ferraBanOverlayShown = true;
    ferraShowBanOverlay(data);
  } catch (err) {
    console.warn('Vérification du compte indisponible.');
  }
}

function ferraFormatBanCountdown(untilIso) {
  const unit = (key, fallback) => ' ' + ferraT('ban.unit.' + key, fallback);
  const ms = new Date(untilIso).getTime() - Date.now();
  if (ms <= 0) return '0' + unit('s', 's');
  const totalSec = Math.floor(ms / 1000);
  const days = Math.floor(totalSec / 86400);
  const hours = Math.floor((totalSec % 86400) / 3600);
  const mins = Math.floor((totalSec % 3600) / 60);
  const secs = totalSec % 60;
  const parts = [];
  if (days > 0) parts.push(days + unit('d', 'j'));
  if (days > 0 || hours > 0) parts.push(hours + unit('h', 'h'));
  parts.push(mins + unit('min', 'min'));
  parts.push(secs + unit('s', 's'));
  return parts.join(' ');
}

function ferraShowBanOverlay(ban) {
  const overlay = document.createElement('div');
  overlay.className = 'ferra-ban-overlay';
  overlay.innerHTML = `
    <div class="ferra-ban-card" role="alertdialog" aria-modal="true" aria-labelledby="ferraBanTitle" aria-describedby="ferraBanReason">
      <div class="ferra-ban-icon">${ferraIconHtml('ban')}</div>
      <h2 class="ferra-ban-title" id="ferraBanTitle" tabindex="-1"></h2>
      <div class="ferra-ban-reason-label label"></div>
      <div class="ferra-ban-reason" id="ferraBanReason"></div>
      <div class="ferra-ban-countdown"></div>
      <button class="ferra-ban-contest-btn btn btn--outline" type="button" aria-expanded="false" aria-controls="ferraBanContestForm"></button>
      <div class="ferra-ban-contest-form" id="ferraBanContestForm" style="display:none;">
        <textarea class="textarea" maxlength="4000" rows="5"></textarea>
        <div class="ferra-ban-contest-actions">
          <button class="ferra-ban-contest-send btn btn--primary" type="button"></button>
        </div>
        <div class="ferra-ban-contest-status" role="status"></div>
      </div>
    </div>
  `;
  overlay.querySelector('.ferra-ban-title').textContent = ferraT('ban.title', 'Compte suspendu');
  overlay.querySelector('.ferra-ban-reason-label').textContent = ferraT('ban.reasonLabel', 'Raison');
  overlay.querySelector('.ferra-ban-reason').textContent = ban.reason;
  overlay.querySelector('.ferra-ban-contest-btn').textContent = ferraT('ban.contest', 'Contester ce bannissement');
  overlay.querySelector('.ferra-ban-contest-send').textContent = ferraT('ban.send', "Envoyer à l'administrateur");
  const textarea = overlay.querySelector('.ferra-ban-contest-form textarea');
  textarea.setAttribute('placeholder', ferraT('ban.placeholder', 'Explique ta situation en quelques lignes…'));
  textarea.setAttribute('aria-label', ferraT('ban.yourSituation', 'Ta situation'));
  document.documentElement.appendChild(overlay);
  document.body.style.overflow = 'hidden';
  document.body.inert = true;
  overlay.querySelector('.ferra-ban-title').focus();

  const countdownEl = overlay.querySelector('.ferra-ban-countdown');
  if (ban.banned_until) {
    const tick = () => {
      const remaining = new Date(ban.banned_until).getTime() - Date.now();
      if (remaining <= 0) { location.reload(); return; }
      countdownEl.textContent = `${ferraT('ban.unlockIn', 'Débloqué dans')} ${ferraFormatBanCountdown(ban.banned_until)}`;
    };
    tick();
    setInterval(tick, 1000);
  } else {
    countdownEl.textContent = ferraT('ban.permanent', 'Bannissement définitif');
  }

  const contestBtn = overlay.querySelector('.ferra-ban-contest-btn');
  const contestForm = overlay.querySelector('.ferra-ban-contest-form');
  const setContestOpen = (open) => {
    contestForm.style.display = open ? 'block' : 'none';
    contestBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
  };
  contestBtn.addEventListener('click', () => {
    const open = contestForm.style.display === 'none';
    setContestOpen(open);
    if (open) textarea.focus();
  });
  overlay.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' || e.key === 'Esc') {
      if (contestForm.style.display !== 'none') {
        setContestOpen(false);
        contestBtn.focus();
      }
      return;
    }
    if (e.key !== 'Tab') return;
    const items = Array.from(overlay.querySelectorAll('button:not([disabled]), textarea:not([disabled])'))
      .filter((el) => el.getClientRects().length > 0);
    if (!items.length) return;
    const at = items.indexOf(document.activeElement);
    if (e.shiftKey && at <= 0) {
      e.preventDefault();
      items[items.length - 1].focus();
    } else if (!e.shiftKey && at === items.length - 1) {
      e.preventDefault();
      items[0].focus();
    }
  });
  overlay.querySelector('.ferra-ban-contest-send').addEventListener('click', async () => {
    const messageInput = overlay.querySelector('.ferra-ban-contest-form textarea');
    const statusEl = overlay.querySelector('.ferra-ban-contest-status');
    const sendBtn = overlay.querySelector('.ferra-ban-contest-send');
    const message = messageInput.value.trim();
    if (!message) {
      statusEl.textContent = ferraT('ban.writeFirst', "Écris un message avant d'envoyer.");
      statusEl.className = 'ferra-ban-contest-status err';
      return;
    }
    sendBtn.disabled = true;
    statusEl.textContent = ferraT('ban.sending', 'Envoi en cours…');
    statusEl.className = 'ferra-ban-contest-status';
    try {
      const { data: { session: authSession } } = await window.supabaseClient.auth.getSession();
      const token = authSession?.access_token;
      const res = await fetch(`${window.FERRA_CONFIG.SUPABASE_URL}/functions/v1/contest-ban`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ message }),
      });
      const body = await res.json().catch(() => ({}));
      if (res.ok) {
        statusEl.textContent = ferraT('ban.sent', "Message envoyé à l'administrateur.");
        statusEl.className = 'ferra-ban-contest-status ok';
        messageInput.value = '';
      } else {
        statusEl.textContent = body.error === 'too_soon'
          ? ferraT('ban.tooSoon', 'Tu as déjà contesté récemment. Réessaie plus tard.')
          : ferraT('ban.failed', "Échec de l'envoi, réessaie plus tard.");
        statusEl.className = 'ferra-ban-contest-status err';
      }
    } catch (err) {
      statusEl.textContent = ferraT('ban.failed', "Échec de l'envoi, réessaie plus tard.");
      statusEl.className = 'ferra-ban-contest-status err';
    }
    sendBtn.disabled = false;
  });
}

const ferraNavAuthState = { el: null, prefix: '', session: undefined };

function ferraPaintNavAuth() {
  const { el, prefix, session } = ferraNavAuthState;
  if (!el || session === undefined) return;
  if (session) {
    const name = session.profile?.username || ferraT('nav.defaultPlayer', 'Joueur');
    const admin = ferraIsAdminModeActive(session);
    el.innerHTML = `
      <span class="menu auth__menu">
        <button class="menu__toggle" type="button" aria-expanded="false" aria-controls="authMenuPanel" data-menu-toggle>
          <span class="avatar" aria-hidden="true">${ferraEscape(ferraAuthInitials(name))}</span><span class="auth__name">${ferraEscape(name)}</span>
          ${admin ? `<span class="badge badge--solid badge--plain auth__admin">${ferraEscape(ferraT('nav.admin', 'Admin'))}</span>` : ''}
          ${ferraIconHtml('chevron-down')}
        </button>
        <div class="menu__panel" id="authMenuPanel">
          <div class="auth__who"><span class="avatar" aria-hidden="true">${ferraEscape(ferraAuthInitials(name))}</span><span class="auth__who-name">${ferraEscape(name)}</span>${admin ? `<span class="badge badge--solid badge--plain">${ferraEscape(ferraT('nav.admin', 'Admin'))}</span>` : ''}</div>
          ${admin ? `<a class="menu__item" href="${prefix}panel.html">${ferraIconHtml('shield')}${ferraEscape(ferraT('nav.panel', 'Panel'))}</a>` : ''}
          <a class="menu__item" href="${prefix}parametres.html">${ferraIconHtml('gear')}${ferraEscape(ferraT('nav.settings', 'Paramètres'))}</a>
          <a class="menu__item" href="${prefix}solde.html">${ferraIconHtml('wallet')}${ferraEscape(ferraT('nav.credits', 'Recharger mes crédits'))}</a>
          <button class="menu__item" id="ferraNavLogoutBtn" type="button">${ferraIconHtml('logout')}${ferraEscape(ferraT('nav.logout', 'Déconnexion'))}</button>
        </div>
      </span>
    `;
    el.querySelector('.menu__toggle').setAttribute('aria-label', `${ferraT('nav.account', 'Compte')}, ${name}`);
    document.getElementById('ferraNavLogoutBtn').addEventListener('click', () => ferraSignOutTo(prefix + 'index.html'));
    el.setAttribute('data-state', 'in');
  } else {
    el.innerHTML = `
      <a class="auth__link" href="${prefix}forum/login.html">${ferraEscape(ferraT('nav.connexion', 'Connexion'))}</a>
      <a class="btn btn--outline btn--sm btn--nowrap" href="${prefix}forum/signup.html">${ferraEscape(ferraT('nav.inscription', 'Inscription'))}</a>
    `;
    el.setAttribute('data-state', 'out');
  }
}

document.addEventListener('ferra:i18n', ferraPaintNavAuth);

async function ferraRenderNavAuth(elId, prefix) {
  const el = document.getElementById(elId);
  if (!el) return;
  prefix = prefix || '';
  ferraNavAuthState.el = el;
  ferraNavAuthState.prefix = prefix;
  const session = await ferraGetSession();
  ferraApplyAdminModeStyling(session);
  ferraLogVisit(session);
  ferraCheckBanAndBlock(session);
  ferraStartDevHoursHeartbeat(session);
  ferraNavAuthState.session = session;
  ferraPaintNavAuth();
}

async function ferraRenderUserWidget(elId) {
  const el = document.getElementById(elId);
  if (!el) return null;
  const session = await ferraGetSession();
  ferraApplyAdminModeStyling(session);
  ferraCheckBanAndBlock(session);
  if (session) {
    const name = session.profile?.username || ferraT('nav.defaultPlayer', 'Joueur');
    el.innerHTML = `
      <span class="forum-user__who"><span class="avatar" aria-hidden="true">${ferraEscape(ferraAuthInitials(name))}</span><span><span data-forum-connected>${ferraEscape(ferraT('forum.connectedAs', 'Connecté en tant que'))}</span> <b>${ferraEscape(name)}</b></span></span>
      <button class="btn btn--outline btn--sm" id="ferraLogoutBtn" type="button">${ferraEscape(ferraT('forum.logout', 'Se déconnecter'))}</button>
    `;
    document.getElementById('ferraLogoutBtn').addEventListener('click', ferraSignOut);
  } else {
    el.innerHTML = `
      <a class="btn btn--outline btn--sm" href="${ferraForumPath('login.html')}">${ferraEscape(ferraT('nav.login', 'Se connecter'))}</a>
      <a class="btn btn--primary btn--sm" href="${ferraForumPath('signup.html')}">${ferraEscape(ferraT('nav.signup', 'Créer un compte'))}</a>
    `;
  }
  return session;
}

function ferraEscape(str) {
  const div = document.createElement('div');
  div.textContent = str == null ? '' : String(str);
  return div.innerHTML;
}

function ferraForumPath(page) {
  return page;
}
