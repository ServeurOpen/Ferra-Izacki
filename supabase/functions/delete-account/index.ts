// ============================================================
// Izacki — Fonction Edge : suppression de compte / droit à l'oubli
// (RGPD), cadrée et validée le 07/09/2026.
//
// Appelée par le JOUEUR LUI-MÊME depuis Paramètres (jamais par un admin
// sur un autre compte) après avoir retapé son mot de passe côté client.
// Fait deux choses, dans cet ordre :
//   1) Anonymise le profil (pseudo, avatar, bannière, IP/appareil
//      d'inscription) via anonymize_my_account() — voir migration_52.
//      Appelé avec le token du JOUEUR (pas la service role) pour que
//      auth.uid() résolve bien vers lui à l'intérieur de la fonction SQL.
//   2) Verrouille le compte pour de vrai côté Auth : email remplacé par
//      une adresse non-réutilisable (libère l'email d'origine), mot de
//      passe remplacé par une valeur aléatoire, connexion bannie
//      (100 ans). On ne supprime JAMAIS la ligne auth.users elle-même —
//      elle est référencée en CASCADE par game_purchases/submitted_games
//      (voir migration_29) : la supprimer casserait l'accès des
//      ACHETEURS aux jeux de ce créateur. Ses jeux restent donc en vente,
//      anonymisés (demande explicite : "tu les laisse publique tqt").
//
// Déploiement : Dashboard Supabase -> Edge Functions -> Create a new
// function -> nom "delete-account" -> coller ce fichier -> Deploy.
// Aucun secret supplémentaire à ajouter (utilise les mêmes
// SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY que les
// autres fonctions Edge de ce projet).
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), { status: 405, headers: CORS_HEADERS });
  }

  const authHeader = req.headers.get("Authorization") || "";
  if (!authHeader.startsWith("Bearer ")) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: CORS_HEADERS });
  }

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
  const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Client "au nom du joueur" (son propre token) — pour que
  // anonymize_my_account() voie le bon auth.uid().
  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: callerData, error: callerErr } = await callerClient.auth.getUser();
  const userId = callerData?.user?.id;
  if (callerErr || !userId) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: CORS_HEADERS });
  }

  // 1) Anonymisation du profil (avec le token du joueur, pas la service role).
  const { error: anonErr } = await callerClient.rpc("anonymize_my_account");
  if (anonErr) {
    console.error("[delete-account] anonymize_my_account a échoué :", anonErr);
    return new Response(JSON.stringify({ error: "anonymize_failed" }), { status: 500, headers: CORS_HEADERS });
  }

  // 2) Verrouillage réel du compte côté Auth (nécessite la service role).
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const randomPassword = crypto.randomUUID() + crypto.randomUUID();
  const { error: lockErr } = await admin.auth.admin.updateUserById(userId, {
    email: `deleted-${userId}@izacki.deleted`,
    password: randomPassword,
    ban_duration: "876000h", // ~100 ans, effectivement définitif
    user_metadata: {},
  });
  if (lockErr) {
    // Le profil est déjà anonymisé à ce stade — cas rare à surveiller
    // manuellement (voir logs), mais on ne relance jamais automatiquement
    // pour éviter tout effet de bord.
    console.error("[delete-account] verrouillage Auth échoué (profil déjà anonymisé) :", lockErr);
    return new Response(JSON.stringify({ error: "lock_failed_but_anonymized" }), { status: 500, headers: CORS_HEADERS });
  }

  return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
});
