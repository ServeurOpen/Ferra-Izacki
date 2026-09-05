// ============================================================
// Izacki — Fonction Edge : paiement RÉEL d'une demande de retrait via
// PayPal Payouts (05/09/2026, demande explicite : "juste que je valide
// dans un menu launcher c'est tout").
//
// Appelée par l'admin (Launcher/site) quand il clique "Payer" sur une
// demande en attente — revérifie tout côté serveur : l'appelant est bien
// admin, la demande existe et est "pending", ET que la plateforme a
// RÉELLEMENT assez d'argent réel encaissé (platform_finance) pour ne
// jamais payer plus que ce qui a été réellement collecté via Stripe.
//
// Déploiement : Dashboard Supabase -> Edge Functions -> Create a new
// function -> nom "process-withdrawal" -> coller ce fichier -> Deploy.
// Secrets à ajouter : PAYPAL_CLIENT_ID, PAYPAL_CLIENT_SECRET (déjà
// obtenus en mode Sandbox — voir PAYPAL_API_BASE ci-dessous pour basculer
// en Live plus tard).
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Sandbox pour l'instant — remplacer par "https://api-m.paypal.com" une
// fois prêt pour de vrais paiements (en même temps que des identifiants
// PayPal Live, distincts des identifiants Sandbox).
const PAYPAL_API_BASE = "https://api-m.sandbox.paypal.com";

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

  const { data: wr } = await admin
    .from("withdrawal_requests")
    .select("id, seller_id, payout_cents, paypal_email, status")
    .eq("id", requestId)
    .maybeSingle();
  if (!wr || wr.status !== "pending") {
    return new Response(JSON.stringify({ error: "not_found_or_already_processed" }), { status: 400, headers: CORS_HEADERS });
  }

  // Garde-fou de solvabilité (voir migration_29) : jamais payer plus que
  // le vrai chiffre d'affaires réellement encaissé via Stripe.
  const { data: finance } = await admin.from("platform_finance").select("total_topup_cents, total_payout_cents").eq("id", true).maybeSingle();
  const available = (finance?.total_topup_cents || 0) - (finance?.total_payout_cents || 0);
  if (available < wr.payout_cents) {
    return new Response(
      JSON.stringify({ error: "insufficient_platform_funds", availableCents: available, neededCents: wr.payout_cents }),
      { status: 409, headers: CORS_HEADERS }
    );
  }

  const PAYPAL_CLIENT_ID = Deno.env.get("PAYPAL_CLIENT_ID");
  const PAYPAL_CLIENT_SECRET = Deno.env.get("PAYPAL_CLIENT_SECRET");
  if (!PAYPAL_CLIENT_ID || !PAYPAL_CLIENT_SECRET) {
    console.error("[process-withdrawal] identifiants PayPal manquants");
    return new Response(JSON.stringify({ error: "paypal_not_configured" }), { status: 500, headers: CORS_HEADERS });
  }

  try {
    // 1) Jeton OAuth PayPal (Basic auth client_id:secret).
    const tokenRes = await fetch(`${PAYPAL_API_BASE}/v1/oauth2/token`, {
      method: "POST",
      headers: {
        Authorization: `Basic ${btoa(`${PAYPAL_CLIENT_ID}:${PAYPAL_CLIENT_SECRET}`)}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: "grant_type=client_credentials",
    });
    if (!tokenRes.ok) {
      console.error("[process-withdrawal] échec du jeton PayPal :", await tokenRes.text());
      return new Response(JSON.stringify({ error: "paypal_auth_failed" }), { status: 502, headers: CORS_HEADERS });
    }
    const { access_token } = await tokenRes.json();

    // 2) Envoi du paiement (Payouts API) — un seul destinataire par lot.
    const payoutRes = await fetch(`${PAYPAL_API_BASE}/v1/payments/payouts`, {
      method: "POST",
      headers: { Authorization: `Bearer ${access_token}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        sender_batch_header: {
          sender_batch_id: `izacki-${requestId}`,
          email_subject: "Tu as reçu un paiement Izacki !",
          email_message: "Ton retrait de crédits Izacki a été traité.",
        },
        items: [
          {
            recipient_type: "EMAIL",
            amount: { value: (wr.payout_cents / 100).toFixed(2), currency: "EUR" },
            receiver: wr.paypal_email,
            note: "Retrait de crédits — vente de jeu sur Izacki",
            sender_item_id: requestId,
          },
        ],
      }),
    });
    if (!payoutRes.ok) {
      console.error("[process-withdrawal] échec du paiement PayPal :", await payoutRes.text());
      return new Response(JSON.stringify({ error: "paypal_payout_failed" }), { status: 502, headers: CORS_HEADERS });
    }
  } catch (err) {
    console.error("[process-withdrawal]", err);
    return new Response(JSON.stringify({ error: "paypal_error" }), { status: 502, headers: CORS_HEADERS });
  }

  const { data: markResult, error: markErr } = await admin.rpc("mark_withdrawal_paid", { p_request_id: requestId });
  if (markErr || !(markResult as any)?.ok) {
    // Le paiement PayPal est parti mais la mise à jour a échoué — cas rare
    // à surveiller manuellement (voir logs), mais on ne redemande jamais
    // à PayPal de payer une seconde fois automatiquement.
    console.error("[process-withdrawal] paiement envoyé mais mark_withdrawal_paid a échoué :", markErr);
    return new Response(JSON.stringify({ error: "paid_but_db_update_failed" }), { status: 500, headers: CORS_HEADERS });
  }

  return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
});
