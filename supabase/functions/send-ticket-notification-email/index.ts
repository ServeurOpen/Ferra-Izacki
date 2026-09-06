// ============================================================
// Izacki — Fonction Edge : email à l'admin quand un joueur ouvre un
// ticket d'assistance (06/09/2026, demande explicite : "onglet Service
// Client/assistance... ouvrir un ticket").
//
// Appelée par le Launcher JUSTE APRÈS un create_support_ticket() réussi,
// UNIQUEMENT pour les catégories question/bug/other — les tickets
// "remboursement" ont déjà leur propre email détaillé, voir
// send-refund-request-email (appelé en parallèle par le même flux).
//
// Déploiement : Dashboard Supabase -> Edge Functions -> Create a new
// function -> nom "send-ticket-notification-email" -> coller ce fichier
// -> Deploy. Réutilise le secret RESEND_API_KEY déjà configuré.
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const ADMIN_EMAIL = "ferra.izacki@gmail.com";
const RESEND_FROM = "Izacki <onboarding@resend.dev>";

const CATEGORY_LABELS: Record<string, string> = {
  question: "❓ Question",
  bug: "🐞 Bug",
  refund: "💳 Remboursement",
  other: "📩 Autre",
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

  let ticketId = "";
  try {
    const body = await req.json();
    ticketId = String(body.ticketId || "");
  } catch {
    return new Response(JSON.stringify({ error: "bad_request" }), { status: 400, headers: CORS_HEADERS });
  }
  if (!ticketId) {
    return new Response(JSON.stringify({ error: "missing_ticket_id" }), { status: 400, headers: CORS_HEADERS });
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
  const { data: ticket } = await admin
    .from("support_tickets")
    .select("user_id, category, subject")
    .eq("id", ticketId)
    .maybeSingle();
  if (!ticket || ticket.user_id !== callerData.user.id) {
    return new Response(JSON.stringify({ error: "forbidden" }), { status: 403, headers: CORS_HEADERS });
  }

  const { data: firstMsg } = await admin
    .from("support_ticket_messages")
    .select("message")
    .eq("ticket_id", ticketId)
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();

  const playerEmail = callerData.user.email || "inconnu";
  const categoryLabel = CATEGORY_LABELS[ticket.category] || ticket.category;

  const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
  if (!RESEND_API_KEY) {
    console.error("[send-ticket-notification-email] RESEND_API_KEY manquant");
    return new Response(JSON.stringify({ error: "email_not_configured" }), { status: 500, headers: CORS_HEADERS });
  }

  const html = `
    <h2>🎧 Nouveau ticket d'assistance</h2>
    <p><b>Joueur :</b> ${playerEmail}</p>
    <p><b>Catégorie :</b> ${categoryLabel}</p>
    <p><b>Sujet :</b> ${String(ticket.subject).replace(/</g, "&lt;")}</p>
    ${firstMsg?.message ? `<p><b>Message :</b></p><p style="background:#f4f4f4;padding:12px;border-radius:8px;">${String(firstMsg.message).replace(/</g, "&lt;")}</p>` : ""}
    <p>Réponds depuis le panel admin (Launcher, onglet 🎧 Assistance, ou le site).</p>
  `;

  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: RESEND_FROM, to: [ADMIN_EMAIL], subject: `[Ticket ${categoryLabel}] ${playerEmail} — ${ticket.subject}`, html }),
    });
    if (!res.ok) {
      console.error("[send-ticket-notification-email] Resend a échoué :", await res.text());
      return new Response(JSON.stringify({ error: "resend_error" }), { status: 502, headers: CORS_HEADERS });
    }
  } catch (err) {
    console.error("[send-ticket-notification-email]", err);
    return new Response(JSON.stringify({ error: "resend_error" }), { status: 502, headers: CORS_HEADERS });
  }

  return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
});
