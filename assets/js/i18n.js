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

// prefix : '' depuis une page à la racine, '../' depuis games/ ou forum/ —
// même convention que ferraRenderNavAuth.
async function ferraI18nInit(prefix) {
  prefix = prefix || '';
  let saved = 'fr';
  try { saved = localStorage.getItem('ferra_lang') || 'fr'; } catch {}
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
