// ============================================================
// Izacki — Fonction Edge : email au joueur après traitement de sa demande
// de remboursement (05/09/2026, demande explicite).
//
// Appelée par l'admin (Launcher/site) JUSTE APRÈS un admin_process_refund()
// réussi — revérifie côté serveur que l'appelant est admin ET que la
// demande a réellement été traitée (status != 'pending').
//
// Déploiement : Dashboard Supabase -> Edge Functions -> Create a new
// function -> nom "send-refund-result-email" -> coller ce fichier ->
// Deploy. Réutilise le secret RESEND_API_KEY déjà configuré.
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

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
  const callerEmail = (callerData?.user?.email || "").trim().toLowerCase();
  if (callerErr || callerEmail !== "ferra.izacki@gmail.com") {
    return new Response(JSON.stringify({ error: "forbidden" }), { status: 403, headers: CORS_HEADERS });
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const { data: rr } = await admin
    .from("refund_requests")
    .select("buyer_id, game_id, amount_credits, status, rejection_reason")
    .eq("id", requestId)
    .maybeSingle();
  if (!rr || rr.status === "pending") {
    return new Response(JSON.stringify({ error: "not_processed" }), { status: 400, headers: CORS_HEADERS });
  }

  const { data: buyerData } = await admin.auth.admin.getUserById(rr.buyer_id);
  const buyerEmail = buyerData?.user?.email;
  if (!buyerEmail) {
    return new Response(JSON.stringify({ error: "buyer_not_found" }), { status: 404, headers: CORS_HEADERS });
  }
  const { data: game } = await admin.from("submitted_games").select("title").eq("id", rr.game_id).maybeSingle();

  const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
  if (!RESEND_API_KEY) {
    console.error("[send-refund-result-email] RESEND_API_KEY manquant");
    return new Response(JSON.stringify({ error: "email_not_configured" }), { status: 500, headers: CORS_HEADERS });
  }

  const approved = rr.status === "approved";
  const subject = approved ? `✅ Ton remboursement pour "${game?.title || "ton jeu"}" est accepté` : `Ton remboursement pour "${game?.title || "ton jeu"}" n'a pas été accepté`;
  const html = approved
    ? `<h2>Remboursement accepté</h2><p><b>${rr.amount_credits} crédits</b> t'ont été rendus.</p>`
    : `<h2>Remboursement refusé</h2><p><b>Raison :</b></p><p style="background:#f4f4f4;padding:12px;border-radius:8px;">${(rr.rejection_reason || "").replace(/</g, "&lt;")}</p>`;

  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: RESEND_FROM, to: [buyerEmail], subject, html }),
    });
    if (!res.ok) {
      console.error("[send-refund-result-email] Resend a échoué :", await res.text());
      return new Response(JSON.stringify({ error: "resend_error" }), { status: 502, headers: CORS_HEADERS });
    }
  } catch (err) {
    console.error("[send-refund-result-email]", err);
    return new Response(JSON.stringify({ error: "resend_error" }), { status: 502, headers: CORS_HEADERS });
  }

  return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
});
