(function () {
  'use strict';

  var doc = document;
  var root = doc.documentElement;
  var DESKTOP = '(min-width:72rem)';
  var TOC_WIDE = '(min-width:62rem)';

  function each(list, fn) {
    Array.prototype.forEach.call(list, fn);
  }

  function listen(query, fn) {
    if (!window.matchMedia) return null;
    var mq = window.matchMedia(query);
    if (mq.addEventListener) mq.addEventListener('change', fn);
    else if (mq.addListener) mq.addListener(fn);
    return mq;
  }

  function label(key, fallback) {
    return typeof ferraT === 'function' ? ferraT(key, fallback) : fallback;
  }

  var header = doc.querySelector('.site-header');
  var menuBtn = doc.querySelector('.menu-btn');

  function setSprite(button, name) {
    var use = button.querySelector('use');
    if (!use) return;
    var href = use.getAttribute('href') || '';
    use.setAttribute('href', href.split('#')[0] + '#' + name);
  }

  function menuIsOpen() {
    return !!header && header.classList.contains('nav-open');
  }

  function syncMenuButton() {
    if (!menuBtn) return;
    var open = menuIsOpen();
    menuBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
    menuBtn.setAttribute('aria-label', open ? label('shell.menu.close', 'Fermer le menu') : label('shell.menu.open', 'Ouvrir le menu'));
    setSprite(menuBtn, open ? 'close' : 'menu');
  }

  var inerted = [];

  function setPageInert(on) {
    if (!doc.body) return;
    if (!on) {
      inerted.forEach(function (el) { el.removeAttribute('inert'); });
      inerted = [];
      return;
    }
    each(doc.body.children, function (el) {
      if (el.contains(header) || el.hasAttribute('inert') || /^(SCRIPT|STYLE|LINK|TEMPLATE|NOSCRIPT)$/.test(el.tagName)) return;
      el.setAttribute('inert', '');
      inerted.push(el);
    });
  }

  function setMenu(open) {
    if (!header) return;
    header.classList.toggle('nav-open', open);
    root.classList.toggle('has-nav-open', open);
    setPageInert(open);
    syncMenuButton();
  }

  function closeMenu() {
    if (menuIsOpen()) setMenu(false);
  }

  if (header && menuBtn) {
    menuBtn.addEventListener('click', function () {
      setMenu(!menuIsOpen());
    });
    var panel = header.querySelector('.nav-panel');
    if (panel) {
      panel.addEventListener('click', function (e) {
        if (e.target.closest && e.target.closest('a[href]')) closeMenu();
      });
    }
    listen(DESKTOP, function (e) {
      if (e.matches) closeMenu();
    });
  }

  var navItems = doc.querySelectorAll('.nav > li');

  function hoveredNavItem() {
    var found = null;
    each(navItems, function (li) {
      if (li.matches(':hover')) found = li;
    });
    return found;
  }

  each(navItems, function (li) {
    li.addEventListener('mouseleave', function () {
      if (!li.contains(doc.activeElement)) li.removeAttribute('data-dismissed');
    });
    li.addEventListener('focusout', function (e) {
      if (li.contains(e.relatedTarget) || li.matches(':hover')) return;
      li.removeAttribute('data-dismissed');
    });
  });

  function closeAccountMenus(except) {
    var closed = null;
    each(doc.querySelectorAll('.menu.is-open'), function (menu) {
      if (menu === except) return;
      menu.classList.remove('is-open');
      var toggle = menu.querySelector('[data-menu-toggle]');
      if (toggle) {
        toggle.setAttribute('aria-expanded', 'false');
        closed = toggle;
      }
    });
    return closed;
  }

  doc.addEventListener('click', function (e) {
    var toggle = e.target.closest ? e.target.closest('[data-menu-toggle]') : null;
    if (toggle) {
      var menu = toggle.closest('.menu');
      if (!menu) return;
      closeAccountMenus(menu);
      var open = menu.classList.toggle('is-open');
      toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
      return;
    }
    if (!e.target.closest || !e.target.closest('.menu.is-open')) closeAccountMenus(null);
  });

  doc.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape' && e.key !== 'Esc') return;
    var toggle = closeAccountMenus(null);
    if (toggle) {
      toggle.focus();
      return;
    }
    if (menuIsOpen()) {
      closeMenu();
      if (menuBtn) menuBtn.focus();
      return;
    }
    var active = doc.activeElement;
    var item = (active && active.closest ? active.closest('.nav > li') : null) || hoveredNavItem();
    if (item && item.querySelector('.nav-sub')) {
      item.setAttribute('data-dismissed', '');
      var top = item.querySelector(':scope > a');
      if (top && active && active !== top && item.contains(active)) top.focus();
    }
  });

  function syncLangButtons(lang) {
    each(doc.querySelectorAll('.lang button[data-lang]'), function (btn) {
      btn.setAttribute('aria-pressed', btn.getAttribute('data-lang') === lang ? 'true' : 'false');
    });
  }

  function currentLang() {
    return typeof ferraI18nCurrentLang === 'function' ? ferraI18nCurrentLang() : (root.lang || 'fr');
  }

  function stripLangParam() {
    var page = doc.body && doc.body.getAttribute('data-page');
    if (page === 'forum-reset-password' || !window.history || !history.replaceState) return;
    var parts = location.search.replace(/^\?/, '').split('&');
    var kept = parts.filter(function (part) {
      return part && part.split('=')[0] !== 'lang';
    });
    if (kept.length === parts.filter(Boolean).length) return;
    try {
      history.replaceState(history.state, '', location.pathname + (kept.length ? '?' + kept.join('&') : '') + location.hash);
    } catch (err) {}
  }

  var langBusy = false;

  doc.addEventListener('click', function (e) {
    var btn = e.target.closest ? e.target.closest('.lang [data-lang]') : null;
    if (!btn || langBusy || typeof ferraI18nSetLang !== 'function') return;
    var lang = btn.getAttribute('data-lang');
    langBusy = true;
    stripLangParam();
    Promise.resolve(ferraI18nSetLang(lang)).then(function () {
      ferraI18nApply();
      syncLangButtons(currentLang());
      if (doc.body && doc.body.hasAttribute('data-i18n-reload')) location.reload();
    }).catch(function () {
      console.warn('Changement de langue impossible.');
    }).then(function () {
      langBusy = false;
    });
  });

  doc.addEventListener('ferra:i18n', function (e) {
    syncLangButtons(e.detail && e.detail.lang ? e.detail.lang : currentLang());
    syncMenuButton();
  });

  syncLangButtons(currentLang());

  each(doc.querySelectorAll('.tabs'), function (group) {
    var tabs = Array.prototype.slice.call(group.querySelectorAll('[role="tab"]'));
    function select(tab, focus) {
      tabs.forEach(function (t) {
        var on = t === tab;
        t.setAttribute('aria-selected', on ? 'true' : 'false');
        t.tabIndex = on ? 0 : -1;
        var target = doc.getElementById(t.getAttribute('aria-controls'));
        if (target) target.hidden = !on;
      });
      if (focus) tab.focus();
    }
    tabs.forEach(function (tab, i) {
      tab.addEventListener('click', function () { select(tab, false); });
      tab.addEventListener('keydown', function (e) {
        var next = null;
        if (e.key === 'ArrowRight') next = tabs[(i + 1) % tabs.length];
        else if (e.key === 'ArrowLeft') next = tabs[(i - 1 + tabs.length) % tabs.length];
        else if (e.key === 'Home') next = tabs[0];
        else if (e.key === 'End') next = tabs[tabs.length - 1];
        if (next) {
          e.preventDefault();
          select(next, true);
        }
      });
    });
  });

  function openModal(id) {
    var dlg = typeof id === 'string' ? doc.getElementById(id) : id;
    if (dlg && typeof dlg.showModal === 'function' && !dlg.open) dlg.showModal();
  }

  each(doc.querySelectorAll('[data-modal-open]'), function (opener) {
    opener.addEventListener('click', function () {
      openModal(opener.getAttribute('data-modal-open'));
    });
  });

  each(doc.querySelectorAll('dialog.modal'), function (dlg) {
    dlg.addEventListener('click', function (e) {
      if (e.target === dlg) dlg.close();
    });
    each(dlg.querySelectorAll('[data-modal-close]'), function (closer) {
      closer.addEventListener('click', function () { dlg.close(); });
    });
  });

  each(doc.querySelectorAll('[data-dismiss]'), function (button) {
    button.addEventListener('click', function () {
      var target = button.closest(button.getAttribute('data-dismiss'));
      if (target) target.hidden = true;
    });
  });

  var tocLinks = doc.querySelectorAll('.toc a[href^="#"]');
  if (tocLinks.length) {
    var tocMap = {};
    var markToc = function (link) {
      each(tocLinks, function (a) { a.removeAttribute('aria-current'); });
      if (link) link.setAttribute('aria-current', 'true');
    };
    each(tocLinks, function (a) {
      var id = a.getAttribute('href').slice(1);
      try { id = decodeURIComponent(id); } catch (err) {}
      tocMap[id] = a;
      a.addEventListener('click', function () { markToc(a); });
    });
    var tocHash = location.hash.slice(1);
    try { tocHash = decodeURIComponent(tocHash); } catch (err) {}
    markToc(tocMap[tocHash] || tocLinks[0]);
    if ('IntersectionObserver' in window) {
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (en) {
          if (en.isIntersecting && tocMap[en.target.id]) markToc(tocMap[en.target.id]);
        });
      }, { rootMargin: '-20% 0px -70% 0px' });
      Object.keys(tocMap).forEach(function (id) {
        var el = doc.getElementById(id);
        if (el) io.observe(el);
      });
    }
  }

  var tocDetails = doc.querySelector('details.toc-details');
  if (tocDetails) {
    var tocWide = listen(TOC_WIDE, function (e) {
      tocDetails.open = e.matches;
    });
    tocDetails.open = tocWide ? tocWide.matches : true;
  }

  function revealAnchor(initial) {
    var id = location.hash.slice(1);
    if (!id) return;
    try { id = decodeURIComponent(id); } catch (err) {}
    var target = doc.getElementById(id);
    if (!target) return;
    var opened = false;
    var node = target;
    while (node) {
      if (node.tagName === 'DETAILS' && !node.open) {
        node.open = true;
        opened = true;
      }
      node = node.parentElement ? node.parentElement.closest('details') : null;
    }
    if (opened) target.scrollIntoView({ block: 'start', behavior: initial ? 'instant' : 'auto' });
  }

  revealAnchor(true);
  window.addEventListener('hashchange', function () { revealAnchor(false); });

  each(doc.querySelectorAll('a[target="_blank"]'), function (a) {
    if (!a.hasAttribute('rel')) a.setAttribute('rel', 'noopener noreferrer');
  });

  window.ferraShell = { closeMenu: closeMenu, openModal: openModal };
})();
