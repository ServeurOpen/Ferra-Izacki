// ============================================================
// FERRA — Configuration du forum
// C'est le SEUL fichier à modifier pour brancher le forum sur ton propre
// projet Supabase. Vois le README.md à la racine du site pour le guide
// complet, étape par étape.
//
// 1. Crée un compte gratuit sur https://supabase.com puis un nouveau projet.
// 2. Dans le projet : Project Settings -> API.
// 3. Copie "Project URL" dans SUPABASE_URL ci-dessous.
// 4. Copie la clé "anon public" dans SUPABASE_ANON_KEY ci-dessous.
//    (Cette clé est PUBLIQUE par design chez Supabase — normal qu'elle
//    apparaisse dans le code du site, elle ne donne aucun accès admin.)
// 5. Dans Supabase : SQL Editor -> New query -> colle le contenu de
//    supabase/schema.sql -> Run. Ça crée toutes les tables du forum.
// ============================================================

window.FERRA_CONFIG = {
  SUPABASE_URL: 'https://wesfskxcvfidltnmnrsg.supabase.co',
  SUPABASE_ANON_KEY: 'sb_publishable_aNQ7hYz-5LzuzDgnmF8E1g_Z186Vms4',
};
