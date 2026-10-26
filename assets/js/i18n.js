const FERRA_I18N_CACHE = {};
const FERRA_I18N_LANGS = ['fr', 'en', 'es'];
const FERRA_I18N_SELECTOR = '[data-i18n],[data-i18n-placeholder],[data-i18n-content],[data-i18n-attr]';
let ferraI18nSeq = 0;

function ferraI18nPage() {
  return (document.body && document.body.getAttribute('data-page')) || '';
}

function ferraI18nIsText(value) {
  return typeof value === 'string' || typeof value === 'number';
}

function ferraI18nUrlLang() {
  if (ferraI18nPage() === 'forum-reset-password') return '';
  const match = /[?&]lang=(fr|en|es)(?:&|$)/.exec(location.search);
  return match ? match[1] : '';
}

function ferraI18nDetectLang() {
  let lang = ferraI18nUrlLang();
  if (!lang) {
    try { lang = localStorage.getItem('ferra_lang') || ''; } catch (e) { lang = ''; }
  }
  if (FERRA_I18N_LANGS.indexOf(lang) < 0) {
    const list = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || 'fr'];
    lang = 'fr';
    for (let i = 0; i < list.length; i++) {
      const code = String(list[i]).slice(0, 2).toLowerCase();
      if (FERRA_I18N_LANGS.indexOf(code) >= 0) { lang = code; break; }
    }
  }
  return lang;
}

function ferraI18nMerge(target, source) {
  Object.keys(source).forEach((key) => {
    if (key === '__proto__' || key === 'constructor' || key === 'prototype') return;
    const value = source[key];
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      if (!target[key] || typeof target[key] !== 'object') target[key] = {};
      ferraI18nMerge(target[key], value);
    } else {
      target[key] = value;
    }
  });
  return target;
}

async function ferraI18nFetchJson(url, optional) {
  try {
    const res = await fetch(url);
    if (!res.ok) {
      if (!(optional && res.status === 404)) console.warn('Traductions indisponibles :', url);
      return {};
    }
    const data = await res.json();
    return data && typeof data === 'object' ? data : {};
  } catch (err) {
    console.warn('Traductions indisponibles :', url);
    return {};
  }
}

async function ferraI18nLoadDict(lang, prefix) {
  prefix = prefix || '';
  const page = ferraI18nPage();
  const cacheKey = lang + '|' + prefix + '|' + page;
  if (FERRA_I18N_CACHE[cacheKey]) return FERRA_I18N_CACHE[cacheKey];
  const jobs = [
    ferraI18nFetchJson(prefix + 'assets/i18n/' + lang + '.json'),
    ferraI18nFetchJson(prefix + 'assets/i18n/pages/shell.' + lang + '.json'),
  ];
  if (page && page !== 'shell') jobs.push(ferraI18nFetchJson(prefix + 'assets/i18n/pages/' + page + '.' + lang + '.json', true));
  const parts = await Promise.all(jobs);
  const dict = parts.reduce((merged, part) => ferraI18nMerge(merged, part), {});
  if (Object.keys(dict).length) FERRA_I18N_CACHE[cacheKey] = dict;
  return dict;
}

async function ferraI18nInit(prefix) {
  prefix = prefix == null ? '' : String(prefix);
  const lang = ferraI18nDetectLang();
  if (ferraI18nUrlLang()) {
    try { localStorage.setItem('ferra_lang', lang); } catch (e) {}
  }
  const seq = ++ferraI18nSeq;
  const dict = await ferraI18nLoadDict(lang, prefix);
  if (seq !== ferraI18nSeq) return;
  window.FERRA_I18N = { lang, prefix, page: ferraI18nPage(), dict };
  document.documentElement.lang = lang;
}

function ferraI18nCurrentLang() {
  const lang = window.FERRA_I18N && window.FERRA_I18N.lang;
  if (lang) return lang;
  const attr = document.documentElement.lang;
  return FERRA_I18N_LANGS.indexOf(attr) >= 0 ? attr : 'fr';
}

async function ferraI18nSetLang(lang) {
  if (FERRA_I18N_LANGS.indexOf(lang) < 0) return;
  try { localStorage.setItem('ferra_lang', lang); } catch (e) {}
  const prefix = (window.FERRA_I18N && window.FERRA_I18N.prefix) || '';
  const seq = ++ferraI18nSeq;
  const dict = await ferraI18nLoadDict(lang, prefix);
  if (seq !== ferraI18nSeq) return;
  window.FERRA_I18N = { lang, prefix, page: ferraI18nPage(), dict };
}

function ferraI18nLookup(dict, key) {
  if (!dict || typeof key !== 'string') return undefined;
  return key.split('.').reduce((node, part) => (
    node != null && typeof node === 'object' && Object.prototype.hasOwnProperty.call(node, part) ? node[part] : undefined
  ), dict);
}

function ferraT(key, fallback) {
  const dict = (window.FERRA_I18N && window.FERRA_I18N.dict) || {};
  const value = ferraI18nLookup(dict, key);
  return ferraI18nIsText(value) ? String(value) : fallback;
}

function ferraI18nApply(root) {
  const dict = (window.FERRA_I18N && window.FERRA_I18N.dict) || {};
  const scope = root && root.querySelectorAll ? root : document;
  const nodes = Array.prototype.slice.call(scope.querySelectorAll(FERRA_I18N_SELECTOR));
  if (scope !== document && scope.matches && scope.matches(FERRA_I18N_SELECTOR)) nodes.unshift(scope);
  nodes.forEach((el) => {
    const key = el.getAttribute('data-i18n');
    if (key) {
      const value = ferraI18nLookup(dict, key);
      if (ferraI18nIsText(value)) {
        if (el.tagName === 'TITLE') el.textContent = value;
        else el.innerHTML = value;
      }
    }
    const placeholder = el.getAttribute('data-i18n-placeholder');
    if (placeholder) {
      const value = ferraI18nLookup(dict, placeholder);
      if (ferraI18nIsText(value)) el.setAttribute('placeholder', value);
    }
    const content = el.getAttribute('data-i18n-content');
    if (content) {
      const value = ferraI18nLookup(dict, content);
      if (ferraI18nIsText(value)) el.setAttribute('content', value);
    }
    const pairs = el.getAttribute('data-i18n-attr');
    if (pairs) {
      pairs.split(';').forEach((pair) => {
        const cut = pair.indexOf(':');
        if (cut < 1) return;
        const value = ferraI18nLookup(dict, pair.slice(cut + 1).trim());
        if (ferraI18nIsText(value)) el.setAttribute(pair.slice(0, cut).trim(), value);
      });
    }
  });
  if (scope !== document) return;
  const lang = ferraI18nCurrentLang();
  document.documentElement.lang = lang;
  document.documentElement.classList.remove('i18n-pending');
  document.dispatchEvent(new CustomEvent('ferra:i18n', { detail: { lang } }));
}
