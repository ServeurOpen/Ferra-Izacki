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
//
// --- Formulaire de contact (page contact.html) ---
// Utilise EmailJS (gratuit) pour envoyer directement les messages des
// joueurs sur ton adresse email, sans backend. Voir le README.md,
// section "Formulaire de contact", pour le guide complet.
// 1. Crée un compte gratuit sur https://www.emailjs.com
// 2. Email Services -> Add New Service -> connecte ta boîte mail ->
//    copie le "Service ID" dans EMAILJS_SERVICE_ID ci-dessous.
// 3. Email Templates -> Create New Template (voir README pour le
//    contenu exact) -> copie le "Template ID" dans EMAILJS_TEMPLATE_ID.
// 4. Account -> General -> copie la "Public Key" dans EMAILJS_PUBLIC_KEY.
// ============================================================

window.FERRA_CONFIG = {
  SUPABASE_URL: 'https://wesfskxcvfidltnmnrsg.supabase.co',
  SUPABASE_ANON_KEY: 'sb_publishable_aNQ7hYz-5LzuzDgnmF8E1g_Z186Vms4',

  EMAILJS_PUBLIC_KEY: 'PCnj87nh3gvT_HnRX',
  EMAILJS_SERVICE_ID: 'service_l296tdx',
  EMAILJS_TEMPLATE_ID: 'template_6ucelvn',
};
