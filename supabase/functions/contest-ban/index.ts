// ============================================================
// Izacki — Fonction Edge : contestation de bannissement (05/09/2026,
// demande explicite : "une touche contester le ban mettre directement son
// message / screen et ça m'enverra un mail à ferra.izacki@gmail.com").
//
// Appelée par le Launcher UNIQUEMENT si le joueur est réellement banni
// (revérifié ICI côté serveur avec la clé service role, jamais fié au
// seul affichage client) — évite qu'un joueur non banni spam la boîte
// mail. Un anti-spam simple (1 contestation max toutes les heures par
// joueur) évite aussi qu'un joueur banni relance en boucle.
//
// Envoi d'email via Resend (resend.com) — compte déjà créé par le joueur,
// domaine non vérifié pour l'instant donc on envoie depuis l'adresse de
// test "onboarding@resend.dev" (fonctionne sans configuration DNS).
//
// Déploiement : Dashboard Supabase -> Edge Functions -> Create a new
// function -> nom "contest-ban" -> coller ce fichier -> Deploy.
// Secret à ajouter : RESEND_API_KEY (clé API Resend, re_...).
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const ADMIN_EMAIL = "ferra.izacki@gmail.com";
const RESEND_FROM = "Izacki <onboarding@resend.dev>";

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

  let message = "";
  let screenshotBase64: string | undefined;
  let screenshotFilename: string | undefined;
  try {
    const body = await req.json();
    message = String(body.message || "").trim().slice(0, 4000);
    screenshotBase64 = body.screenshotBase64 ? String(body.screenshotBase64) : undefined;
    screenshotFilename = body.screenshotFilename ? String(body.screenshotFilename).slice(0, 200) : undefined;
  } catch {
    return new Response(JSON.stringify({ error: "bad_request" }), { status: 400, headers: CORS_HEADERS });
  }
  if (!message) {
    return new Response(JSON.stringify({ error: "message_required" }), { status: 400, headers: CORS_HEADERS });
  }

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
  const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: callerData, error: callerErr } = await callerClient.auth.getUser();
  if (callerErr || !callerData?.user) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: CORS_HEADERS });
  }
  const userId = callerData.user.id;
  const userEmail = callerData.user.email || "inconnu";

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // Revérifie que ce joueur est réellement banni (jamais fié au seul
  // affichage côté client) — accepte aussi un ban temporaire déjà expiré
  // (le joueur a pu écrire son message juste avant l'expiration).
  const { data: ban } = await admin.from("user_bans").select("reason, banned_until").eq("user_id", userId).maybeSingle();
  if (!ban) {
    return new Response(JSON.stringify({ error: "not_banned" }), { status: 403, headers: CORS_HEADERS });
  }

  // Anti-spam : 1 contestation max par heure et par joueur.
  const oneHourAgo = new Date(Date.now() - 60 * 60_000).toISOString();
  const { data: recent } = await admin
    .from("ban_appeals")
    .select("id")
    .eq("user_id", userId)
    .gt("created_at", oneHourAgo)
    .limit(1);
  if (recent && recent.length > 0) {
    return new Response(JSON.stringify({ error: "too_soon" }), { status: 429, headers: CORS_HEADERS });
  }

  await admin.from("ban_appeals").insert({ user_id: userId, message });

  const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
  if (!RESEND_API_KEY) {
    console.error("[contest-ban] RESEND_API_KEY manquant");
    return new Response(JSON.stringify({ error: "email_not_configured" }), { status: 500, headers: CORS_HEADERS });
  }

  const untilTxt = ban.banned_until ? new Date(ban.banned_until).toLocaleString("fr-FR") : "Définitif";
  const emailBody: Record<string, unknown> = {
    from: RESEND_FROM,
    to: [ADMIN_EMAIL],
    subject: `[Contestation de ban] ${userEmail}`,
    html: `
      <h2>Contestation de bannissement</h2>
      <p><b>Joueur :</b> ${userEmail} (id: ${userId})</p>
      <p><b>Raison du ban :</b> ${ban.reason}</p>
      <p><b>Fin du ban :</b> ${untilTxt}</p>
      <p><b>Message du joueur :</b></p>
      <p style="white-space:pre-wrap;background:#f4f4f4;padding:12px;border-radius:8px;">${message.replace(/</g, "&lt;")}</p>
    `,
  };
  if (screenshotBase64) {
    emailBody.attachments = [
      { filename: screenshotFilename || "capture.png", content: screenshotBase64 },
    ];
  }

  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify(emailBody),
    });
    if (!res.ok) {
      const errTxt = await res.text();
      console.error("[contest-ban] Resend a échoué :", errTxt);
      return new Response(JSON.stringify({ error: "resend_error" }), { status: 502, headers: CORS_HEADERS });
    }
  } catch (err) {
    console.error("[contest-ban]", err);
    return new Response(JSON.stringify({ error: "resend_error" }), { status: 502, headers: CORS_HEADERS });
  }

  return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
});
