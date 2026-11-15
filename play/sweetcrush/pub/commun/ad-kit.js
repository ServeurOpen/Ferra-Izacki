/* ============================================================
   Izacki — boîte à outils commune des pubs animées (canvas 1080×1920, vertical).
   Une pub = un dossier avec pub.html qui charge ce fichier, définit draw(t) puis appelle runAd(draw, DUREE, { images }).
   Contrat : window.Ad = { dur, FPS, ready, seek(t) }  (déterministe : sert au direct ET à un futur export MP4).
   ?static&t=3  → dessine UNE image à t=3 s · ?once → joue une fois et envoie postMessage({ad:"done"}) au parent · sinon boucle.
   ============================================================ */
const W = 1080, H = 1920;
const cv = document.getElementById("c"), g = cv.getContext("2d");
const Q = new URLSearchParams(location.search);
const C = { bg:"#0c0d0f", panel:"#1b1e21", line:"#2b3036", text:"#eceef1", dim:"#a4acb7", orange:"#f5a55a", orangeHi:"#ffc17f", teal:"#4fd8cb", pink:"#ff5fa8", violet:"#8b5cff", blue:"#4aa3ff", gold:"#ffd24a" };
const FONT = '"Barlow Condensed","Bahnschrift","Arial Narrow","Roboto Condensed",Impact,sans-serif';
const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x)), lerp = (a, b, k) => a + (b - a) * k;
const seg = (t, a, b) => clamp((t - a) / (b - a));
const eOut = k => 1 - Math.pow(1 - k, 3), eIO = k => k < .5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2;
const eBack = k => { const c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * Math.pow(k - 1, 3) + c1 * Math.pow(k - 1, 2); };
const eElastic = k => k <= 0 ? 0 : k >= 1 ? 1 : Math.pow(2, -10 * k) * Math.sin((k * 10 - .75) * (2 * Math.PI / 3)) + 1;
function prng(seed) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }
/* images */
const IMG = {}; let _ready = false;
function loadImgs(map, cb) { const ks = Object.keys(map); let n = 0; if (!ks.length) return cb(); for (const k of ks) { const i = new Image(); i.onload = i.onerror = () => { if (++n === ks.length) cb(); }; i.src = (window.__IMGDATA && window.__IMGDATA[map[k].split("/").pop()]) || map[k]; IMG[k] = i; } }
const ok = k => IMG[k] && IMG[k].complete && IMG[k].naturalWidth;
function rr(x, y, w, h, r) { g.beginPath(); g.moveTo(x + r, y); g.arcTo(x + w, y, x + w, y + h, r); g.arcTo(x + w, y + h, x, y + h, r); g.arcTo(x, y + h, x, y, r); g.arcTo(x, y, x + w, y, r); g.closePath(); }
function txt(s, x, y, size, color, o = {}) {
  g.save(); const base = g.globalAlpha, maxW = o.maxW || 1020, sp = o.sp || 0; g.font = (o.weight || 800) + ' ' + size + 'px ' + FONT;
  const measure = () => [...s].reduce((a, ch) => a + g.measureText(ch).width, 0) + sp * (s.length - 1);
  if (measure() > maxW) { size = Math.floor(size * maxW / measure()); g.font = (o.weight || 800) + ' ' + size + 'px ' + FONT; }
  g.textAlign = o.align || 'center'; g.textBaseline = o.base || 'middle'; g.fillStyle = color;
  if (o.shadow) { g.shadowColor = o.shadow; g.shadowBlur = o.blur || 20; }
  if (o.stroke) { g.lineWidth = o.strokeW || 8; g.strokeStyle = o.stroke; g.lineJoin = 'round'; }
  const al = base * (o.alpha == null ? 1 : o.alpha);
  if (sp) {
    const ws = [...s].map(ch => g.measureText(ch).width), tot = ws.reduce((a, b) => a + b, 0) + sp * (ws.length - 1); let px = x - (o.align === 'left' ? 0 : o.align === 'right' ? tot : tot / 2);
    g.textAlign = 'left'; [...s].forEach((ch, i) => { g.globalAlpha = al * (o.stag ? clamp((o.stagT - i * o.stag) / .25) : 1); if (o.stroke) g.strokeText(ch, px, y); g.fillText(ch, px, y); px += ws[i] + sp; });
  } else { g.globalAlpha = al; if (o.stroke) g.strokeText(s, x, y); g.fillText(s, x, y); }
  g.restore();
}
/* image « cover » dans un rectangle arrondi, avec zoom / déplacement (effet Ken Burns) */
function cover(k, x, y, w, h, r, zoom = 1, px = 0, py = 0) {
  if (!ok(k)) { g.save(); rr(x, y, w, h, r); g.fillStyle = C.panel; g.fill(); g.restore(); return; }
  const im = IMG[k], s = Math.max(w / im.naturalWidth, h / im.naturalHeight) * zoom, dw = im.naturalWidth * s, dh = im.naturalHeight * s;
  g.save(); rr(x, y, w, h, r); g.clip(); g.drawImage(im, x + (w - dw) / 2 + px * (dw - w) / 2, y + (h - dh) / 2 + py * (dh - h) / 2, dw, dh); g.restore();
}
/* même placement que cover() : renvoie (u,v) → [X,Y] (u,v = position 0..1 dans l'image) et la largeur affichée de l'image, pour poser des effets EXACTEMENT sur un détail de la capture */
function coverMap(k, x, y, w, h, zoom = 1, px = 0, py = 0) {
  if (!ok(k)) return { at:(u, v) => [x + u * w, y + v * h], dw:w };
  const im = IMG[k], s = Math.max(w / im.naturalWidth, h / im.naturalHeight) * zoom, dw = im.naturalWidth * s, dh = im.naturalHeight * s, ox = x + (w - dw) / 2 + px * (dw - w) / 2, oy = y + (h - dh) / 2 + py * (dh - h) / 2;
  return { at:(u, v) => [ox + u * dw, oy + v * dh], dw };
}
/* fond sombre vivant : dégradé + lueurs qui dérivent + grille + particules */
const _PR = prng(11), _PARTS = Array.from({ length: 80 }, () => ({ x:_PR() * W, y:_PR() * H, r:2 + _PR() * 5, v:30 + _PR() * 90, ph:_PR() * 6.28, a:.15 + _PR() * .5, o:_PR() < .35 }));
function bgDark(t, glows, opt = {}) {
  const gr = g.createLinearGradient(0, 0, 0, H); gr.addColorStop(0, opt.top || "#101215"); gr.addColorStop(1, opt.bot || "#08090a"); g.fillStyle = gr; g.fillRect(0, 0, W, H);
  (glows || [[.2, .25, 700, "245,165,90", .5], [.85, .6, 800, "245,165,90", .35], [.4, .95, 650, "79,216,203", .45]]).forEach(([cx, cy, rad, col, sp]) => {
    const x = (cx + Math.sin(t * sp + cx * 9) * .12) * W, y = (cy + Math.cos(t * sp * .8 + cy * 7) * .08) * H, r = g.createRadialGradient(x, y, 0, x, y, rad);
    r.addColorStop(0, "rgba(" + col + ",.22)"); r.addColorStop(1, "rgba(" + col + ",0)"); g.fillStyle = r; g.fillRect(0, 0, W, H);
  });
  if (!opt.noGrid) { g.save(); g.strokeStyle = "rgba(236,238,241,.05)"; g.lineWidth = 2; const off = (t * 60) % 120; for (let y = -120 + off; y < H; y += 120) { g.beginPath(); g.moveTo(0, y); g.lineTo(W, y); g.stroke(); } for (let x = -((t * 25) % 120); x < W; x += 120) { g.beginPath(); g.moveTo(x, 0); g.lineTo(x, H); g.stroke(); } g.restore(); }
  for (const p of _PARTS) { const y = ((p.y - t * p.v) % (H + 40) + H + 40) % (H + 40) - 20, x = p.x + Math.sin(t * .9 + p.ph) * 40; g.globalAlpha = p.a * (.6 + .4 * Math.sin(t * 2 + p.ph)); g.fillStyle = p.o ? (opt.pc || C.orange) : C.text; g.beginPath(); g.arc(x, y, p.r, 0, 7); g.fill(); }
  g.globalAlpha = 1;
}
/* logo Izacki (carré cerclé + carré orange) */
function mark(cx, cy, s, t, prog = 1) {
  g.save(); g.translate(cx, cy); g.rotate(Math.sin(t * 1.1) * .03); g.scale(s, s);
  g.lineWidth = 12; g.lineJoin = "miter"; g.strokeStyle = C.text; g.shadowColor = "rgba(245,165,90,.5)"; g.shadowBlur = 30 * prog;
  const S = 110, per = 8 * S; g.setLineDash([per * eOut(clamp(prog * 1.5)), per]); g.strokeRect(-S, -S, 2 * S, 2 * S); g.setLineDash([]);
  const k = eBack(clamp((prog - .35) / .5)); g.fillStyle = C.orange; g.shadowBlur = 40 * clamp(k); g.fillRect(S * (1 - k) * .5, S * (1 - k) * .5, S * k, S * k);
  g.restore();
}
/* bandeau diagonal qui balaie l'écran (transition) autour de l'instant tb */
function wipe(t, tb, color, color2) {
  const k0 = seg(t, tb - .32, tb + .05), k1 = seg(t, tb - .05, tb + .32); if (k0 <= 0 || k1 >= 1) return;
  const x1 = lerp(-420, W + 420, eIO(k0)), x0 = lerp(-420, W + 420, eIO(k1)), sk = 360;
  g.save(); g.beginPath(); g.moveTo(x0 + sk, 0); g.lineTo(x1 + sk, 0); g.lineTo(x1 - sk, H); g.lineTo(x0 - sk, H); g.closePath();
  const gr = g.createLinearGradient(x0, 0, x1, 0); gr.addColorStop(0, color); gr.addColorStop(1, color2 || color); g.fillStyle = gr; g.fill(); g.restore();
}
/* cartes qui défilent sans fin (jaquettes) */
function marquee(keys, t, y, h, alpha, speed = 150) {
  const w = h * 2.5, gap = 36, n = keys.length, tot = n * (w + gap), off = (t * speed) % tot;
  g.save(); g.globalAlpha = alpha; g.beginPath(); g.rect(0, y - 20, W, h + 40); g.clip();
  for (let i = -1; i < n * 2 + 2; i++) {
    const k = ((i % n) + n) % n, x = i * (w + gap) - off - gap, c = x + w / 2, d = Math.abs(c - W / 2) / W, sc = 1 - d * .22;
    g.save(); g.translate(c, y + h / 2); g.scale(sc, sc); g.shadowColor = "rgba(0,0,0,.6)"; g.shadowBlur = 30; g.shadowOffsetY = 14;
    rr(-w / 2, -h / 2, w, h, 26); g.fillStyle = C.panel; g.fill(); g.shadowColor = "transparent"; g.save(); rr(-w / 2, -h / 2, w, h, 26); g.clip(); if (ok(keys[k])) g.drawImage(IMG[keys[k]], -w / 2, -h / 2, w, h); g.restore();
    g.lineWidth = 4; g.strokeStyle = "rgba(236,238,241,.18)"; rr(-w / 2, -h / 2, w, h, 26); g.stroke(); g.restore();
  }
  g.restore();
}
/* pastille « ✔ texte » qui rebondit */
function pill(label, x, y, k, t, o = {}) {
  if (k <= 0) return; const s = eBack(clamp(k)), w = o.w || 900, h = o.h || 112, col = o.color || C.orange;
  g.save(); g.translate(x, y + Math.sin(t * 2 + y) * 5); g.scale(s, s); g.globalAlpha = clamp(k * 2);
  g.shadowColor = "rgba(0,0,0,.5)"; g.shadowBlur = 30; g.shadowOffsetY = 10; rr(-w / 2, -h / 2, w, h, 30); g.fillStyle = C.panel; g.fill(); g.shadowColor = "transparent";
  g.lineWidth = 3; g.strokeStyle = col; g.globalAlpha *= .8; rr(-w / 2, -h / 2, w, h, 30); g.stroke(); g.globalAlpha = clamp(k * 2);
  g.fillStyle = col; g.beginPath(); g.arc(-w / 2 + 70, 0, 34, 0, 7); g.fill();
  g.strokeStyle = "#241405"; g.lineWidth = 9; g.lineCap = "round"; g.lineJoin = "round"; g.beginPath(); g.moveTo(-w / 2 + 54, 2); g.lineTo(-w / 2 + 66, 15); g.lineTo(-w / 2 + 90, -14); g.stroke();
  txt(label, -w / 2 + 130, 4, o.size || 46, C.text, { align:"left" }); g.restore();
}
/* bouton d'appel à l'action pulsant */
function ctaButton(label, x, y, k, t, color = C.orange, color2 = C.orangeHi) {
  if (k <= 0) return; const pulse = 1 + Math.sin(t * 6) * .035, s = eBack(clamp(k)) * pulse;
  g.save(); g.globalAlpha = clamp(k * 1.4); g.translate(x, y); g.scale(s, s);
  g.shadowColor = color; g.shadowBlur = 60 + Math.sin(t * 6) * 20; rr(-410, -85, 820, 170, 40); const bgr = g.createLinearGradient(0, -85, 0, 85); bgr.addColorStop(0, color2); bgr.addColorStop(1, color); g.fillStyle = bgr; g.fill(); g.shadowColor = "transparent";
  txt(label, 0, 6, 92, "#1f1206"); g.restore();
  g.save(); g.translate(x, y); const r2 = (t * 1.2) % 1; g.strokeStyle = color2; g.lineWidth = 5; g.globalAlpha = .5 * k * (1 - r2); rr(-410 - r2 * 120, -85 - r2 * 70, 820 + r2 * 240, 170 + r2 * 140, 40 + r2 * 40); g.stroke(); g.restore();
}
/* texte rempli par une image (mot « massif ») : hors-écran puis collé */
const _mk = document.createElement("canvas"); _mk.width = W; _mk.height = 420; const _mg = _mk.getContext("2d");
function maskText(word, imgKey, x, y, size, t, tint) {
  _mg.clearRect(0, 0, W, 420); _mg.font = "800 " + size + "px " + FONT; { const w0 = _mg.measureText(word).width; if (w0 > 980) { size = Math.floor(size * 980 / w0); _mg.font = "800 " + size + "px " + FONT; } } _mg.textAlign = "center"; _mg.textBaseline = "middle";
  const gr = _mg.createLinearGradient(0, 40, 0, 380); gr.addColorStop(0, '#ffffff'); gr.addColorStop(1, tint);
  _mg.fillStyle = gr; _mg.fillText(word, W / 2, 210); _mg.globalCompositeOperation = 'source-atop';
  if (ok(imgKey)) { const im = IMG[imgKey], s = Math.max(W / im.naturalWidth, 420 / im.naturalHeight) * 1.5, dw = im.naturalWidth * s, dh = im.naturalHeight * s; _mg.globalAlpha = .3; _mg.drawImage(im, (W - dw) / 2 + Math.sin(t * 2) * 60, (420 - dh) / 2, dw, dh); _mg.globalAlpha = 1; }
  _mg.globalCompositeOperation = 'source-over';
  g.save(); g.shadowColor = tint; g.shadowBlur = 50; g.drawImage(_mk, x - W / 2, y - 210); g.restore();
}
/* lancement : images → window.Ad → lecture / image fixe */
function runAd(draw, DUR, images, opt = {}) {
  const Ad = window.Ad = { dur:DUR, FPS:30, ready:false, t:0, seek(t) { Ad.t = t; g.clearRect(0, 0, W, H); draw(clamp(t, 0, DUR)); } };
  let t0 = 0, done = false;
  const start = () => {
    Ad.ready = true;
    if (Q.has("static")) { Ad.seek(+Q.get("t") || 0); return; }
    if (opt.onStart) opt.onStart();
    const loop = ts => {
      if (!t0) t0 = ts; let t = (ts - t0) / 1000; const c = opt.clock ? opt.clock() : null;      // c = position du son (s) : c'est LUI qui commande l'image
      if (c != null) { t = c; t0 = ts - c * 1000; }
      if (t >= DUR) { if (!done) { done = true; try { parent.postMessage({ ad:"done" }, "*"); } catch (e) {} } if (Q.has("once")) { Ad.seek(DUR); return; } t0 = ts; done = false; t = 0; if (opt.onLoop) opt.onLoop(); }
      Ad.seek(t);
      if (Q.has("debug")) { g.save(); g.fillStyle = "rgba(0,0,0,.7)"; g.fillRect(20, 20, 250, 70); g.fillStyle = "#fff"; g.font = "700 48px monospace"; g.textBaseline = "top"; g.fillText(t.toFixed(2) + " s", 34, 30); g.restore(); }
      if (opt.overlay) opt.overlay(t);
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
  };
  g.fillStyle = C.bg; g.fillRect(0, 0, W, H); loadImgs(images || {}, start);
}
