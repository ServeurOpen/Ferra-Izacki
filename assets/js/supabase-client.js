// ============================================================
// FERRA — Initialisation du client Supabase (bibliothèque chargée via CDN,
// voir la balise <script> dans chaque page du forum). Un seul client
// partagé par toutes les pages, construit à partir de assets/js/config.js.
// ============================================================
(function () {
  const cfg = window.FERRA_CONFIG || {};
  if (!cfg.SUPABASE_URL || cfg.SUPABASE_URL.includes('VOTRE-PROJET')) {
    console.warn('[FERRA] Forum non configuré — voir assets/js/config.js et le README.md.');
  }
  window.supabaseClient = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY);
})();
