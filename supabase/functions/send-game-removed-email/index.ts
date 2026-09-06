// ============================================================
// Izacki — Fonction Edge : email au vendeur quand l'admin supprime son
// jeu du marketplace (06/09/2026, demande explicite : "ça lui envoie un
// mail disant que son jeu a été supprimé, raison : ...").
//
// Appelée par le Launcher/site JUSTE APRÈS un admin_remove_game() réussi
// (voir migration_40_admin_remove_game.sql) — revérifie côté serveur que
// l'appelant est bien l'admin ET que le jeu est réellement passé en
// status='removed', jamais fié au seul appel client.
//
// Déploiement : Dashboard Supabase -> Edge Functions -> Create a new
// function -> nom "send-game-removed-email" -> coller ce fichier ->
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

  let gameId = "";
  try {
    const body = await req.json();
    gameId = String(body.gameId || "");
  } catch {
    return new Response(JSON.stringify({ error: "bad_request" }), { status: 400, headers: CORS_HEADERS });
  }
  if (!gameId) {
    return new Response(JSON.stringify({ error: "missing_game_id" }), { status: 400, headers: CORS_HEADERS });
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

  const { data: game } = await admin
    .from("submitted_games")
    .select("seller_id, title, status, removal_reason")
    .eq("id", gameId)
    .maybeSingle();
  if (!game || game.status !== "removed") {
    return new Response(JSON.stringify({ error: "game_not_removed" }), { status: 400, headers: CORS_HEADERS });
  }

  const { data: sellerData } = await admin.auth.admin.getUserById(game.seller_id);
  const sellerEmail = sellerData?.user?.email;
  if (!sellerEmail) {
    return new Response(JSON.stringify({ error: "seller_not_found" }), { status: 404, headers: CORS_HEADERS });
  }

  const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
  if (!RESEND_API_KEY) {
    console.error("[send-game-removed-email] RESEND_API_KEY manquant");
    return new Response(JSON.stringify({ error: "email_not_configured" }), { status: 500, headers: CORS_HEADERS });
  }

  const html = `
    <h2>Ton jeu a été supprimé du Launcher</h2>
    <p>Ton jeu <b>${String(game.title).replace(/</g, "&lt;")}</b> a été retiré du marketplace Izacki par l'équipe.</p>
    <p><b>Raison :</b></p>
    <p style="background:#f4f4f4;padding:12px;border-radius:8px;">${String(game.removal_reason || "").replace(/</g, "&lt;")}</p>
    <p>Les joueurs qui l'avaient déjà acheté gardent leur accès — seule la mise en vente est arrêtée.</p>
    <p>Pour toute question, réponds à cet email ou ouvre un ticket depuis le Launcher.</p>
  `;

  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: RESEND_FROM, to: [sellerEmail], subject: `Ton jeu "${game.title}" a été supprimé`, html }),
    });
    if (!res.ok) {
      console.error("[send-game-removed-email] Resend a échoué :", await res.text());
      return new Response(JSON.stringify({ error: "resend_error" }), { status: 502, headers: CORS_HEADERS });
    }
  } catch (err) {
    console.error("[send-game-removed-email]", err);
    return new Response(JSON.stringify({ error: "resend_error" }), { status: 502, headers: CORS_HEADERS });
  }

  return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
});
