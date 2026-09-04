// ============================================================
// FERRA — Système de traduction (05/09/2026, demande explicite : "dans
// l'onglet paramètre on puisse changer de langue anglais, français,
// espagnol").
//
// Convention : chaque texte traduisible porte data-i18n="cle.imbriquee"
// (contenu HTML — les dictionnaires sont ÉCRITS PAR NOUS, jamais du
// contenu joueur, donc innerHTML est sûr ici, contrairement au reste du
// site qui passe tout texte joueur par ferraEscape) et data-i18n-placeholder
// pour un attribut placeholder de champ de formulaire. Le français reste
// la langue de référence (site écrit directement en français) : le
// dictionnaire fr.json en est la copie exacte, pour qu'un retour explicite
// au français réapplique la bonne version plutôt que de compter sur le
// texte d'origine encore présent dans le DOM.
//
// Persisté en localStorage (par navigateur, pas par compte) — un visiteur
// non connecté doit pouvoir changer de langue tout autant qu'un joueur
// connecté.
// ============================================================

const FERRA_I18N_CACHE = {};

async function ferraI18nLoadDict(lang, prefix) {
  const cacheKey = lang;
  if (FERRA_I18N_CACHE[cacheKey]) return FERRA_I18N_CACHE[cacheKey];
  try {
    const res = await fetch(`${prefix || ''}assets/i18n/${lang}.json`);
    const data = await res.json();
    FERRA_I18N_CACHE[cacheKey] = data;
    return data;
  } catch (err) {
    console.error('[FERRA] i18n : échec de chargement de', lang, err);
    return {};
  }
}

// ============================================================
// Sélecteur de langue plein écran à la toute première visite (05/09/2026,
// demande explicite : "une page pleine tout l'écran... 3 drapeaux
// français/anglais/espagnol... Choisissez votre langue (Français par
// défaut)... et un Valider. C'est l'entrée du site.") — ne s'affiche QUE si
// 'ferra_lang' n'existe pas encore en localStorage (jamais choisi), donc
// une seule fois par navigateur, quelle que soit la page d'arrivée (pas que
// l'accueil : un lien direct vers un sujet du forum, par exemple, doit
// aussi la déclencher si c'est la toute première visite).
// Couleurs/polices reprises des variables CSS déjà définies dans style.css
// (voir :root) pour rester cohérent avec le reste du site sans dupliquer la
// palette ici.
// ============================================================
const FERRA_LANG_GATE_OPTIONS = [
  { code: 'fr', flag: '🇫🇷', label: 'Français' },
  { code: 'en', flag: '🇬🇧', label: 'English' },
  { code: 'es', flag: '🇪🇸', label: 'Español' },
];

function ferraShowLanguageGate() {
  return new Promise((resolve) => {
    let selected = 'fr';
    const overlay = document.createElement('div');
    overlay.id = 'ferraLangGate';
    overlay.innerHTML = `
      <style>
        #ferraLangGate{
          position:fixed;inset:0;z-index:99999;display:flex;align-items:center;justify-content:center;
          background:
            radial-gradient(ellipse 900px 500px at 15% -10%, rgba(242,164,90,0.10), transparent 60%),
            radial-gradient(ellipse 800px 500px at 90% 10%, rgba(107,214,127,0.06), transparent 55%),
            var(--bg-void, #0d0f13);
          font-family:'Oswald',sans-serif;
        }
        #ferraLangGate .fg-brand{
          position:absolute;top:40px;left:50%;transform:translateX(-50%);
          font-family:'Rajdhani',sans-serif;font-weight:700;font-size:22px;letter-spacing:4px;color:var(--text,#e7e9ee);
        }
        #ferraLangGate .fg-brand span{color:var(--copper-glow,#f2a45a);}
        #ferraLangGate .fg-card{max-width:540px;width:92vw;text-align:center;padding:20px;}
        #ferraLangGate h1{
          font-family:'Rajdhani',sans-serif;font-size:30px;font-weight:700;margin:0 0 10px;color:var(--text,#e7e9ee);
        }
        #ferraLangGate .fg-sub{color:var(--text-dim,#8890a0);font-size:13px;margin:0 0 38px;letter-spacing:0.3px;}
        #ferraLangGate .fg-flags{display:flex;gap:16px;justify-content:center;margin-bottom:38px;flex-wrap:wrap;}
        #ferraLangGate .fg-flag-btn{
          display:flex;flex-direction:column;align-items:center;gap:10px;padding:22px 28px;border-radius:16px;
          background:rgba(255,255,255,0.03);border:2px solid var(--panel-edge,#262b34);cursor:pointer;
          transition:border-color .15s,background .15s,transform .15s;min-width:112px;font-family:inherit;
        }
        #ferraLangGate .fg-flag-btn:hover{transform:translateY(-2px);border-color:rgba(242,164,90,0.45);}
        #ferraLangGate .fg-flag-btn.sel{border-color:var(--copper-glow,#f2a45a);background:rgba(242,164,90,0.10);}
        #ferraLangGate .fg-flag-emoji{font-size:40px;line-height:1;}
        #ferraLangGate .fg-flag-label{font-family:'Rajdhani',sans-serif;font-size:13px;font-weight:700;color:var(--text,#e7e9ee);}
        #ferraLangGate .fg-validate{
          padding:14px 50px;border-radius:999px;border:none;font-family:'Rajdhani',sans-serif;
          font-weight:700;font-size:15px;letter-spacing:0.4px;cursor:pointer;color:var(--bg-void,#0d0f13);
          background:linear-gradient(135deg,var(--gold,#e8c15c),var(--copper-dark,#b5691f));
          box-shadow:0 10px 28px rgba(242,164,90,0.28);transition:transform .12s,filter .15s;
        }
        #ferraLangGate .fg-validate:hover{filter:brightness(1.08);transform:translateY(-1px);}
        @media (max-width:480px){
          #ferraLangGate .fg-flag-btn{padding:16px 18px;min-width:88px;}
          #ferraLangGate h1{font-size:24px;}
        }
      </style>
      <div class="fg-brand">FER<span>RA</span></div>
      <div class="fg-card">
        <h1>Choisissez votre langue</h1>
        <p class="fg-sub">Choose your language · Elige tu idioma</p>
        <div class="fg-flags">
          ${FERRA_LANG_GATE_OPTIONS.map((l) => `
            <button type="button" class="fg-flag-btn${l.code === 'fr' ? ' sel' : ''}" data-lang="${l.code}">
              <span class="fg-flag-emoji">${l.flag}</span><span class="fg-flag-label">${l.label}</span>
            </button>`).join('')}
        </div>
        <button type="button" class="fg-validate" id="ferraLangGateValidate">Valider</button>
      </div>
    `;
    document.body.appendChild(overlay);
    const prevOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';

    overlay.querySelectorAll('.fg-flag-btn').forEach((btn) => {
      btn.addEventListener('click', () => {
        selected = btn.dataset.lang;
        overlay.querySelectorAll('.fg-flag-btn').forEach((b) => b.classList.toggle('sel', b === btn));
      });
    });
    overlay.querySelector('#ferraLangGateValidate').addEventListener('click', () => {
      overlay.remove();
      document.body.style.overflow = prevOverflow;
      resolve(selected);
    });
  });
}

// prefix : '' depuis une page à la racine, '../' depuis games/ ou forum/ —
// même convention que ferraRenderNavAuth.
async function ferraI18nInit(prefix) {
  prefix = prefix || '';
  let saved = null;
  try { saved = localStorage.getItem('ferra_lang'); } catch {}
  if (!saved) {
    saved = await ferraShowLanguageGate();
    try { localStorage.setItem('ferra_lang', saved); } catch {}
  }
  window.FERRA_I18N = { lang: saved, prefix, dict: await ferraI18nLoadDict(saved, prefix) };
}

function ferraI18nCurrentLang() {
  return (window.FERRA_I18N && window.FERRA_I18N.lang) || 'fr';
}

async function ferraI18nSetLang(lang) {
  try { localStorage.setItem('ferra_lang', lang); } catch {}
  const prefix = (window.FERRA_I18N && window.FERRA_I18N.prefix) || '';
  window.FERRA_I18N = { lang, prefix, dict: await ferraI18nLoadDict(lang, prefix) };
}

function ferraI18nLookup(dict, key) {
  return key.split('.').reduce((o, k) => (o && o[k] != null ? o[k] : undefined), dict);
}

// Pour le contenu généré en JS (innerHTML dynamique, ex. le widget de
// connexion du menu — voir ferraRenderNavAuth dans auth.js) : contrairement
// à data-i18n, ce texte n'existe pas encore dans le DOM au moment du
// balayage de ferraI18nApply(), impossible de le cibler après coup.
// `fallback` (toujours le texte français) est renvoyé si le dictionnaire
// n'est pas encore chargé, pour ne jamais afficher une clé brute.
function ferraT(key, fallback) {
  const dict = (window.FERRA_I18N && window.FERRA_I18N.dict) || {};
  const val = ferraI18nLookup(dict, key);
  return val != null ? val : fallback;
}

// Applique le dictionnaire courant à toute la page — à rappeler après
// chaque changement de langue (voir ferraI18nSetLang) ET une fois au
// chargement de chaque page.
function ferraI18nApply() {
  const dict = (window.FERRA_I18N && window.FERRA_I18N.dict) || {};
  document.querySelectorAll('[data-i18n]').forEach((el) => {
    const val = ferraI18nLookup(dict, el.dataset.i18n);
    if (val != null) el.innerHTML = val;
  });
  document.querySelectorAll('[data-i18n-placeholder]').forEach((el) => {
    const val = ferraI18nLookup(dict, el.dataset.i18nPlaceholder);
    if (val != null) el.setAttribute('placeholder', val);
  });
  document.documentElement.lang = ferraI18nCurrentLang();
}
