
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
    console.error('[FERRA] ferraReenableAdminMode a échoué :', err);
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
    console.error('[FERRA] vérification de ban échouée :', err);
  }
}

function ferraFormatBanCountdown(untilIso) {
  const ms = new Date(untilIso).getTime() - Date.now();
  if (ms <= 0) return '0s';
  const totalSec = Math.floor(ms / 1000);
  const days = Math.floor(totalSec / 86400);
  const hours = Math.floor((totalSec % 86400) / 3600);
  const mins = Math.floor((totalSec % 3600) / 60);
  const secs = totalSec % 60;
  const parts = [];
  if (days > 0) parts.push(`${days}j`);
  if (days > 0 || hours > 0) parts.push(`${hours}h`);
  parts.push(`${mins}min`);
  parts.push(`${secs}s`);
  return parts.join(' ');
}

function ferraShowBanOverlay(ban) {
  const overlay = document.createElement('div');
  overlay.className = 'ferra-ban-overlay';
  overlay.innerHTML = `
    <div class="ferra-ban-card">
      <div class="ferra-ban-icon">⛔</div>
      <h1 class="ferra-ban-title">Compte suspendu</h1>
      <div class="ferra-ban-reason-label">Raison :</div>
      <div class="ferra-ban-reason"></div>
      <div class="ferra-ban-countdown"></div>
      <button class="ferra-ban-contest-btn" type="button">📩 Contester ce bannissement</button>
      <div class="ferra-ban-contest-form" style="display:none;">
        <textarea placeholder="Explique ta situation en quelques lignes…" maxlength="4000" rows="5"></textarea>
        <div class="ferra-ban-contest-actions">
          <button class="ferra-ban-contest-send" type="button">Envoyer à l'administrateur</button>
        </div>
        <div class="ferra-ban-contest-status"></div>
      </div>
    </div>
  `;
  overlay.querySelector('.ferra-ban-reason').textContent = ban.reason;
  document.documentElement.appendChild(overlay);
  document.body.style.overflow = 'hidden';

  const countdownEl = overlay.querySelector('.ferra-ban-countdown');
  if (ban.banned_until) {
    const tick = () => {
      const remaining = new Date(ban.banned_until).getTime() - Date.now();
      if (remaining <= 0) { location.reload(); return; }
      countdownEl.textContent = `⏳ Débloqué dans ${ferraFormatBanCountdown(ban.banned_until)}`;
    };
    tick();
    setInterval(tick, 1000);
  } else {
    countdownEl.textContent = '🔒 Bannissement définitif';
  }

  overlay.querySelector('.ferra-ban-contest-btn').addEventListener('click', () => {
    const form = overlay.querySelector('.ferra-ban-contest-form');
    form.style.display = form.style.display === 'none' ? 'block' : 'none';
  });
  overlay.querySelector('.ferra-ban-contest-send').addEventListener('click', async () => {
    const messageInput = overlay.querySelector('.ferra-ban-contest-form textarea');
    const statusEl = overlay.querySelector('.ferra-ban-contest-status');
    const sendBtn = overlay.querySelector('.ferra-ban-contest-send');
    const message = messageInput.value.trim();
    if (!message) {
      statusEl.textContent = "Écris un message avant d'envoyer.";
      statusEl.className = 'ferra-ban-contest-status err';
      return;
    }
    sendBtn.disabled = true;
    statusEl.textContent = 'Envoi en cours…';
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
        statusEl.textContent = "✅ Message envoyé à l'administrateur.";
        statusEl.className = 'ferra-ban-contest-status ok';
        messageInput.value = '';
      } else {
        statusEl.textContent = body.error === 'too_soon'
          ? '❌ Tu as déjà contesté récemment — réessaie plus tard.'
          : "❌ Échec de l'envoi, réessaie plus tard.";
        statusEl.className = 'ferra-ban-contest-status err';
      }
    } catch (err) {
      statusEl.textContent = "❌ Échec de l'envoi, réessaie plus tard.";
      statusEl.className = 'ferra-ban-contest-status err';
    }
    sendBtn.disabled = false;
  });
}

async function ferraRenderNavAuth(elId, prefix) {
  const el = document.getElementById(elId);
  if (!el) return;
  prefix = prefix || '';
  const session = await ferraGetSession();
  ferraApplyAdminModeStyling(session);
  ferraLogVisit(session);
  ferraCheckBanAndBlock(session);
  ferraStartDevHoursHeartbeat(session);
  if (session) {
    const adminBadge = ferraIsAdminModeActive(session) ? `<span class="admin-mode-badge">🛡️ Admin</span>` : '';
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

async function ferraRenderUserWidget(elId) {
  const el = document.getElementById(elId);
  if (!el) return null;
  const session = await ferraGetSession();
  ferraApplyAdminModeStyling(session);
  ferraCheckBanAndBlock(session);
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

function ferraEscape(str) {
  const div = document.createElement('div');
  div.textContent = str == null ? '' : String(str);
  return div.innerHTML;
}

function ferraForumPath(page) {
  return page;
}
