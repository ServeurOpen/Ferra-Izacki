// ============================================================
// Izacki — Fonction Edge : vérifie le mot de passe de réactivation du mode
// Admin (05/09/2026, demande explicite : "si on désactive pour réactiver
// il faut mettre un mdp").
//
// Le mot de passe ne vit NULLE PART dans le code du site/Launcher (visible
// par n'importe qui via "Afficher le code source") — uniquement ici, en
// secret Edge Function (ADMIN_REENABLE_PASSWORD), comparé côté serveur.
// Cette fonction ne fait QUE répondre oui/non ; c'est le client qui écrit
// ensuite admin_mode_disabled=false sur SON PROPRE profil (déjà autorisé
// par les policies normales de profiles, pas besoin de privilège de
// service ici).
//
// Déploiement : Dashboard Supabase -> Edge Functions -> Create a new
// function -> nom "verify-admin-password" -> coller ce fichier -> Deploy.
// Puis Edge Functions -> Secrets -> ajouter ADMIN_REENABLE_PASSWORD avec
// le mot de passe choisi.
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const ADMIN_EMAILS = ["ferra.izacki@gmail.com"];
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
  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: callerData, error: callerErr } = await callerClient.auth.getUser();
  const callerEmail = (callerData?.user?.email || "").trim().toLowerCase();
  if (callerErr || !ADMIN_EMAILS.includes(callerEmail)) {
    return new Response(JSON.stringify({ error: "forbidden" }), { status: 403, headers: CORS_HEADERS });
  }

  let body: { password?: string };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "bad_request" }), { status: 400, headers: CORS_HEADERS });
  }

  const expected = Deno.env.get("ADMIN_REENABLE_PASSWORD");
  if (!expected) {
    return new Response(JSON.stringify({ error: "missing_password_secret" }), { status: 500, headers: CORS_HEADERS });
  }

  const valid = typeof body.password === "string" && body.password === expected;
  return new Response(JSON.stringify({ valid }), {
    status: 200,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
});
