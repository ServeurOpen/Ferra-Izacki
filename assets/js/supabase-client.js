(function () {
  const cfg = window.FERRA_CONFIG || {};
  if (!cfg.SUPABASE_URL || cfg.SUPABASE_URL.includes('VOTRE-PROJET')) {
    console.warn('Les services du compte ne sont pas configurés.');
  }
  window.supabaseClient = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY);
})();
