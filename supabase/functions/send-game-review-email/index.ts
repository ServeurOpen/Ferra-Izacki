// ============================================================
// Izacki — Fonction Edge : email au joueur après modération de son jeu
// soumis (05/09/2026, demande explicite : "le joueur recevra un mail...
// selon le résultat").
//
// Appelée par le Launcher/site JUSTE APRÈS un admin_review_game() réussi
// (voir migration_26_game_marketplace.sql) — revérifie côté serveur que
// l'appelant est bien l'admin ET que le jeu a réellement été traité
// (status != 'pending'), jamais fié au seul appel client.
//
// Déploiement : Dashboard Supabase -> Edge Functions -> Create a new
// function -> nom "send-game-review-email" -> coller ce fichier -> Deploy.
// Réutilise le secret RESEND_API_KEY déjà configuré pour contest-ban.
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
    .select("seller_id, title, status, rejection_reason")
    .eq("id", gameId)
    .maybeSingle();
  if (!game || game.status === "pending") {
    return new Response(JSON.stringify({ error: "game_not_reviewed" }), { status: 400, headers: CORS_HEADERS });
  }

  const { data: sellerData } = await admin.auth.admin.getUserById(game.seller_id);
  const sellerEmail = sellerData?.user?.email;
  if (!sellerEmail) {
    return new Response(JSON.stringify({ error: "seller_not_found" }), { status: 404, headers: CORS_HEADERS });
  }

  const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
  if (!RESEND_API_KEY) {
    console.error("[send-game-review-email] RESEND_API_KEY manquant");
    return new Response(JSON.stringify({ error: "email_not_configured" }), { status: 500, headers: CORS_HEADERS });
  }

  const approved = game.status === "approved";
  const subject = approved ? `🎉 Ton jeu "${game.title}" a été accepté !` : `Ton jeu "${game.title}" n'a pas été accepté`;
  // 07/09/2026, demande explicite : "quand le jeux est accepté tu peux
  // faire quelque chose de plus beau / stylé stp" (tickets/remboursements
  // gardés tels quels, EUX sont déjà "parfait" selon le joueur) — email en
  // tables/styles inline (compatibilité Gmail/Outlook), même palette
  // cuivre/or que le site et le Launcher.
  const html = approved
    ? `
<div style="background:#0d0f13;padding:32px 16px;font-family:'Segoe UI',Arial,sans-serif;">
  <table role="presentation" width="100%" style="max-width:560px;margin:0 auto;border-collapse:collapse;">
    <tr>
      <td style="background:linear-gradient(180deg,#1d2027,#14161b);border:1px solid rgba(242,164,90,0.35);border-radius:16px;padding:0;overflow:hidden;">
        <table role="presentation" width="100%" style="border-collapse:collapse;">
          <tr>
            <td style="background:linear-gradient(135deg,#f2a45a,#c9793f);padding:28px 32px;text-align:center;border-radius:16px 16px 0 0;">
              <div style="font-size:44px;line-height:1;margin-bottom:6px;">🎉</div>
              <div style="font-family:Georgia,serif;font-weight:700;font-size:22px;color:#14161b;">Ton jeu est en ligne !</div>
            </td>
          </tr>
          <tr>
            <td style="padding:28px 32px 8px;">
              <p style="color:#e7e9ee;font-size:15px;line-height:1.6;margin:0 0 18px;">Bonne nouvelle — <b style="color:#f2a45a;">${(game.title || "").replace(/</g, "&lt;")}</b> vient d'être validé par l'équipe et est désormais disponible pour toute la communauté Izacki, directement depuis le Launcher. 🚀</p>
              <table role="presentation" width="100%" style="background:rgba(242,164,90,0.08);border:1px solid rgba(242,164,90,0.25);border-radius:12px;margin:0 0 22px;">
                <tr>
                  <td style="padding:16px 18px;color:#c8cdd6;font-size:13.5px;line-height:1.6;">
                    💰 <b style="color:#e7e9ee;">Chaque vente te rapporte le plein montant</b> — aucune commission n'est prélevée à ce moment-là. Tes gains apparaissent directement dans ton Portail créateurs.
                  </td>
                </tr>
              </table>
              <table role="presentation" style="margin:0 auto 24px;">
                <tr>
                  <td style="border-radius:999px;background:linear-gradient(180deg,#f2a45a,#c9793f);">
                    <a href="https://serveuropen.github.io/Ferra-Izacki/" style="display:inline-block;padding:12px 28px;color:#14161b;font-weight:700;font-size:14px;text-decoration:none;border-radius:999px;">Ouvrir le Launcher</a>
                  </td>
                </tr>
              </table>
              <p style="color:#8890a0;font-size:12px;line-height:1.6;margin:0 0 24px;text-align:center;">Merci de faire vivre le marketplace Izacki avec tes créations ✨</p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</div>`
    : `<h2>Ton jeu n'a pas été accepté</h2><p>Ton jeu <b>${game.title}</b> n'a malheureusement pas été accepté.</p><p><b>Raison :</b></p><p style="background:#f4f4f4;padding:12px;border-radius:8px;">${(game.rejection_reason || "").replace(/</g, "&lt;")}</p><p>Tu peux corriger le problème et le soumettre à nouveau.</p>`;

  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: RESEND_FROM, to: [sellerEmail], subject, html }),
    });
    if (!res.ok) {
      console.error("[send-game-review-email] Resend a échoué :", await res.text());
      return new Response(JSON.stringify({ error: "resend_error" }), { status: 502, headers: CORS_HEADERS });
    }
  } catch (err) {
    console.error("[send-game-review-email]", err);
    return new Response(JSON.stringify({ error: "resend_error" }), { status: 502, headers: CORS_HEADERS });
  }

  return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
});
