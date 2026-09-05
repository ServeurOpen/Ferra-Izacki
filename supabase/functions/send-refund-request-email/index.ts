// ============================================================
// Izacki — Fonction Edge : email à l'admin quand un joueur demande un
// remboursement (05/09/2026, demande explicite : "c'est moi qui reçois
// la demande par mail et j'accepte ou non").
//
// Appelée par le Launcher/site JUSTE APRÈS un request_refund() réussi —
// revérifie côté serveur que la demande existe bien et appartient à
// l'appelant (jamais fié au seul appel client).
//
// Déploiement : Dashboard Supabase -> Edge Functions -> Create a new
// function -> nom "send-refund-request-email" -> coller ce fichier ->
// Deploy. Réutilise le secret RESEND_API_KEY déjà configuré.
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const ADMIN_EMAIL = "ferra.izacki@gmail.com";
const RESEND_FROM = "Izacki <onboarding@resend.dev>";

function formatSecs(secs: number): string {
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  return h > 0 ? `${h}h${m}min` : `${m}min`;
}

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

  let requestId = "";
  try {
    const body = await req.json();
    requestId = String(body.requestId || "");
  } catch {
    return new Response(JSON.stringify({ error: "bad_request" }), { status: 400, headers: CORS_HEADERS });
  }
  if (!requestId) {
    return new Response(JSON.stringify({ error: "missing_request_id" }), { status: 400, headers: CORS_HEADERS });
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

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const { data: rr } = await admin
    .from("refund_requests")
    .select("buyer_id, amount_credits, buyer_message, playtime_secs_at_request, days_owned_at_request, meets_policy, game_id")
    .eq("id", requestId)
    .maybeSingle();
  if (!rr || rr.buyer_id !== callerData.user.id) {
    return new Response(JSON.stringify({ error: "forbidden" }), { status: 403, headers: CORS_HEADERS });
  }

  const { data: game } = await admin.from("submitted_games").select("title").eq("id", rr.game_id).maybeSingle();
  const buyerEmail = callerData.user.email || "inconnu";

  const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
  if (!RESEND_API_KEY) {
    console.error("[send-refund-request-email] RESEND_API_KEY manquant");
    return new Response(JSON.stringify({ error: "email_not_configured" }), { status: 500, headers: CORS_HEADERS });
  }

  const html = `
    <h2>💳 Demande de remboursement</h2>
    <p><b>Joueur :</b> ${buyerEmail}</p>
    <p><b>Jeu :</b> ${game?.title || "inconnu"}</p>
    <p><b>Montant :</b> ${rr.amount_credits} crédits</p>
    <p><b>Temps joué :</b> ${formatSecs(Number(rr.playtime_secs_at_request))}</p>
    <p><b>Possédé depuis :</b> ${Number(rr.days_owned_at_request).toFixed(1)} jour(s)</p>
    <p><b>Respecte la règle (≤1h de jeu ET ≤7 jours) :</b> ${rr.meets_policy ? "✅ OUI — recommandé d'accepter" : "❌ NON — recommandé de refuser"}</p>
    ${rr.buyer_message ? `<p><b>Message du joueur :</b></p><p style="background:#f4f4f4;padding:12px;border-radius:8px;">${String(rr.buyer_message).replace(/</g, "&lt;")}</p>` : ""}
    <p>Traite cette demande depuis le panel admin (Launcher ou site).</p>
  `;

  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: RESEND_FROM, to: [ADMIN_EMAIL], subject: `[Remboursement] ${buyerEmail} — ${game?.title || ""}`, html }),
    });
    if (!res.ok) {
      console.error("[send-refund-request-email] Resend a échoué :", await res.text());
      return new Response(JSON.stringify({ error: "resend_error" }), { status: 502, headers: CORS_HEADERS });
    }
  } catch (err) {
    console.error("[send-refund-request-email]", err);
    return new Response(JSON.stringify({ error: "resend_error" }), { status: 502, headers: CORS_HEADERS });
  }

  return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
});
