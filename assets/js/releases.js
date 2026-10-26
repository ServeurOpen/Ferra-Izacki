(function () {
  'use strict';

  var doc = document;
  var ATTRS = '[data-launcher-version],[data-launcher-date],[data-game-version],[data-game-date],[data-changelog],[data-releases-feed]';
  if (!doc.querySelector(ATTRS)) return;

  var script = doc.currentScript;
  var own = script && script.getAttribute('src');
  var prefix = own && /assets\/js\/releases\.js/.test(own) ? own.replace(/assets\/js\/releases\.js.*$/, '') : '';
  var SVG = 'http://www.w3.org/2000/svg';
  var NAMES = { ferra: 'FERRA', 'tower-defense': 'Tower Défense Infini' };
  var dates = [];

  function lang() {
    if (typeof ferraI18nCurrentLang === 'function') return ferraI18nCurrentLang();
    return doc.documentElement.lang || 'fr';
  }

  function isoDate(value) {
    var m = /^(\d{4}-\d{2}-\d{2})/.exec(typeof value === 'string' ? value : '');
    return m ? m[1] : '';
  }

  function format(iso) {
    try {
      return new Intl.DateTimeFormat(lang(), { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(iso + 'T00:00:00Z'));
    } catch (err) {
      return iso;
    }
  }

  function paintDate(el, iso) {
    if (!iso) {
      el.textContent = '';
      el.hidden = true;
      return;
    }
    el.hidden = false;
    el.setAttribute('datetime', iso);
    el.textContent = format(iso);
    if (dates.indexOf(el) < 0) dates.push(el);
  }

  function reformat() {
    dates.forEach(function (el) {
      var iso = el.getAttribute('datetime');
      if (iso) el.textContent = format(iso);
    });
  }

  function load(file) {
    return fetch(prefix + file, { cache: 'no-cache' }).then(function (res) {
      if (!res.ok) throw new Error('indisponible');
      return res.json();
    }).then(function (data) {
      return data && typeof data === 'object' ? data : null;
    }).catch(function () {
      return null;
    });
  }

  function el(tag, className, text) {
    var node = doc.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  }

  function entriesOf(changelog, key) {
    var list = changelog && Array.isArray(changelog[key]) ? changelog[key].slice() : [];
    return list.filter(function (e) { return e && e.version; }).sort(function (a, b) { return String(b.version).localeCompare(String(a.version), undefined, { numeric: true }); });
  }

  function entryFor(changelog, manifest, key) {
    var version = manifest && manifest[key];
    var found = entriesOf(changelog, key).filter(function (e) { return e.version === version; });
    return found.length ? found[0] : null;
  }

  function buildChangelog(box, entries) {
    box.textContent = '';
    entries.forEach(function (entry, index) {
      var details = el('details');
      if (index === 0) details.open = true;
      var summary = el('summary');
      var sum = el('span', 'acc__sum');
      sum.appendChild(el('span', 'badge badge--plain', 'v' + entry.version));
      sum.appendChild(el('span', '', entry.title || ''));
      var right = el('span', 'acc__right');
      var iso = isoDate(entry.date);
      if (iso) {
        var meta = el('span', 'meta');
        var time = el('time');
        paintDate(time, iso);
        meta.appendChild(time);
        right.appendChild(meta);
      }
      var svg = doc.createElementNS(SVG, 'svg');
      svg.setAttribute('class', 'icon');
      svg.setAttribute('aria-hidden', 'true');
      svg.setAttribute('focusable', 'false');
      var use = doc.createElementNS(SVG, 'use');
      use.setAttribute('href', prefix + 'assets/img/icons.svg#plus');
      svg.appendChild(use);
      right.appendChild(svg);
      summary.appendChild(sum);
      summary.appendChild(right);
      var body = el('div', 'acc__body');
      var list = el('ul', 'prose');
      (Array.isArray(entry.notes) ? entry.notes : []).forEach(function (note) {
        list.appendChild(el('li', '', note));
      });
      body.appendChild(list);
      details.appendChild(summary);
      details.appendChild(body);
      box.appendChild(details);
    });
  }

  function releaseRow(name, href, version, iso, title, text) {
    var li = el('li', 'release');
    var nameBox = el('div', 'release__name');
    var link = el('a', '', name);
    link.setAttribute('href', prefix + href);
    nameBox.appendChild(link);
    var meta = el('div', 'release__meta');
    meta.appendChild(el('span', 'release__ver', version));
    if (iso) {
      var time = el('time', 'release__date');
      paintDate(time, iso);
      meta.appendChild(time);
    }
    var body = el('div', 'release__body');
    if (title) body.appendChild(el('h3', '', title));
    if (text) body.appendChild(el('p', '', text));
    li.appendChild(nameBox);
    li.appendChild(meta);
    li.appendChild(body);
    return { node: li, iso: iso };
  }

  function buildFeed(list, latest, manifest, changelog) {
    var rows = [];
    if (latest && latest.version) {
      rows.push(releaseRow('Launcher Izacki', 'launcher.html', latest.version, isoDate(latest.pub_date), '', typeof latest.notes === 'string' ? latest.notes : ''));
    }
    [['tower-defense', 'games/tower-defense.html'], ['ferra', 'games/ferra.html']].forEach(function (game) {
      var version = manifest && manifest[game[0]];
      if (!version) return;
      var entry = entryFor(changelog, manifest, game[0]);
      var notes = entry && Array.isArray(entry.notes) ? entry.notes : [];
      rows.push(releaseRow(NAMES[game[0]], game[1], version, entry ? isoDate(entry.date) : '', entry ? entry.title : '', notes[0] || ''));
    });
    if (!rows.length) return;
    rows.sort(function (a, b) { return a.iso < b.iso ? 1 : a.iso > b.iso ? -1 : 0; });
    list.textContent = '';
    rows.forEach(function (row) { list.appendChild(row.node); });
  }

  function each(selector, fn) {
    Array.prototype.forEach.call(doc.querySelectorAll(selector), fn);
  }

  function run() {
    var has = function (selector) { return doc.querySelector(selector) !== null; };
    Promise.all([
      has('[data-launcher-version],[data-launcher-date],[data-releases-feed]') ? load('games/files/latest.json') : null,
      has('[data-game-version],[data-game-date],[data-releases-feed]') ? load('games/files/manifest.json') : null,
      has('[data-game-date],[data-changelog],[data-releases-feed]') ? load('games/files/changelog.json') : null,
    ]).then(function (data) {
      var latest = data[0];
      var manifest = data[1];
      var changelog = data[2];
      if (latest) {
        each('[data-launcher-version]', function (node) {
          if (latest.version) node.textContent = latest.version;
        });
        each('[data-launcher-date]', function (node) { paintDate(node, isoDate(latest.pub_date)); });
      }
      if (manifest) {
        each('[data-game-version]', function (node) {
          var version = manifest[node.getAttribute('data-game-version')];
          if (version) node.textContent = version;
        });
      }
      if (manifest && changelog) {
        each('[data-game-date]', function (node) {
          var entry = entryFor(changelog, manifest, node.getAttribute('data-game-date'));
          paintDate(node, entry ? isoDate(entry.date) : '');
        });
      }
      if (changelog) {
        each('[data-changelog]', function (box) {
          var entries = entriesOf(changelog, box.getAttribute('data-changelog'));
          var limit = parseInt(box.getAttribute('data-limit'), 10);
          if (limit > 0) entries = entries.slice(0, limit);
          if (entries.length) buildChangelog(box, entries);
        });
      }
      if (latest && manifest && changelog) each('[data-releases-feed]', function (list) { buildFeed(list, latest, manifest, changelog); });
    });
  }

  doc.addEventListener('ferra:i18n', reformat);
  run();
})();
