// ============================================================
// Izacki — Fonction Edge : envoi de l'email de test "Tower Défense —
// nouveau classement" (05/09/2026, demande explicite : "pour la phase de
// test envoie uniquement à ferra.izacki@gmail.com comme ça je regarde si il
// est bien").
//
// Volontairement TRÈS restreinte, pas une fonction générique d'envoi
// d'email libre : le destinataire ET le contenu sont FIGÉS dans ce fichier
// (pas de paramètres `to`/`html` passés par l'appelant) — n'importe quel
// utilisateur connecté qui appellerait cette fonction ne pourrait donc
// JAMAIS l'utiliser pour envoyer un email arbitraire à quelqu'un d'autre.
// Une vraie fonction de campagne (envoi à tous les joueurs ayant opt-in)
// viendra plus tard, une fois le panel admin en place pour la déclencher
// en toute sécurité (réservé au compte ferra.izacki@gmail.com).
//
// Déploiement (aucun CLI requis) : Dashboard Supabase -> Edge Functions ->
// Create a new function -> nom "send-test-announcement" -> coller tout ce
// fichier -> Deploy. Ajouter ensuite le secret RESEND_API_KEY (Edge
// Functions -> Secrets) avec la clé API Resend.
// ============================================================

const TEST_RECIPIENT = "ferra.izacki@gmail.com";
// Domaine d'expédition sans DNS à configurer : Resend n'autorise à envoyer
// depuis onboarding@resend.dev qu'à l'adresse du COMPTE Resend lui-même
// (protection anti-abus tant qu'aucun domaine n'est vérifié) — qui sera de
// toute façon ferra.izacki@gmail.com, donc ça correspond exactement au
// besoin de cette phase de test.
const FROM_ADDRESS = "Izacki <onboarding@resend.dev>";

const EMAIL_SUBJECT = "Nouveau classement disponible sur Tower Défense Infini";

// Version texte brut (05/09/2026, retour joueur : "il arrive dans les
// spams") — un email UNIQUEMENT en HTML, sans alternative texte, est un des
// signaux que regardent les filtres anti-spam (Gmail y compris). Un
// `text` en plus du `html` (partie "multipart", standard email) aide un
// peu, même si la vraie cause reste le domaine partagé resend.dev (voir le
// commentaire sur FROM_ADDRESS) — pas de contournement gratuit pour ça,
// seul un domaine à soi avec SPF/DKIM réglerait vraiment le problème.
const EMAIL_TEXT = `Une nouveauté vient de sortir sur Tower Défense Infini !

Tu peux désormais entrer dans un classement des meilleures vagues entre tous les joueurs — chaque partie compte, chaque vague repoussée peut te faire grimper.

Ouvre le Launcher, lance une partie, et va voir où tu te situes face aux autres commandants.

À bientôt en jeu,
L'équipe Izacki — créateurs de FERRA & Tower Défense Infini

Tu reçois cet email car tu as autorisé Izacki à t'envoyer des emails liés au Launcher. Tu peux désactiver ça à tout moment dans les paramètres du Launcher.`;

const EMAIL_HTML = `<!doctype html>
<html lang="fr">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#0d0f14;font-family:'Segoe UI',Roboto,Arial,sans-serif;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#0d0f14;padding:32px 16px;">
    <tr><td align="center">
      <table role="presentation" width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;background:linear-gradient(180deg,#1b1e26,#14161c);border-radius:16px;overflow:hidden;border:1px solid #2a2d36;">

        <!-- bandeau -->
        <tr><td style="background:linear-gradient(135deg,#f2a45a,#e0665f);padding:28px 32px;text-align:center;">
          <div style="font-family:Georgia,serif;font-weight:700;font-size:26px;letter-spacing:1px;color:#141014;">IZACKI</div>
          <div style="font-size:12px;letter-spacing:3px;color:rgba(20,16,20,0.7);text-transform:uppercase;margin-top:2px;">Le launcher de tes jeux</div>
        </td></tr>

        <!-- corps -->
        <tr><td style="padding:34px 32px 8px;">
          <div style="font-size:13px;letter-spacing:2px;text-transform:uppercase;color:#f2a45a;font-weight:700;margin-bottom:10px;">Tower Défense Infini</div>
          <h1 style="margin:0 0 18px;font-size:22px;line-height:1.35;color:#f2f0ea;">Une nouveauté géniale vient de sortir 🎯</h1>
          <p style="font-size:15px;line-height:1.6;color:#c7cbd6;margin:0 0 16px;">
            Tu peux désormais entrer dans un <b style="color:#f2f0ea;">classement des meilleures vagues</b> entre tous les joueurs de Tower Défense Infini — chaque partie compte, chaque vague repoussée peut te faire grimper.
          </p>
          <p style="font-size:15px;line-height:1.6;color:#c7cbd6;margin:0 0 26px;">
            Ouvre le Launcher, lance une partie, et va voir où tu te situes face aux autres commandants.
          </p>
          <div style="text-align:center;margin:0 0 30px;">
            <span style="display:inline-block;background:linear-gradient(135deg,#f2a45a,#e0665f);color:#141014;font-weight:700;font-size:14px;padding:14px 30px;border-radius:999px;letter-spacing:0.5px;">
              🚀 Ouvrir Izacki Launcher
            </span>
          </div>
        </td></tr>

        <!-- séparateur -->
        <tr><td style="padding:0 32px;"><div style="height:1px;background:#2a2d36;"></div></td></tr>

        <!-- signature -->
        <tr><td style="padding:22px 32px 30px;">
          <p style="font-size:13.5px;line-height:1.6;color:#8a8f9c;margin:0;">
            À bientôt en jeu,<br>
            <b style="color:#f2f0ea;">L'équipe Izacki</b> — créateurs de FERRA & Tower Défense Infini
          </p>
        </td></tr>

        <!-- footer -->
        <tr><td style="padding:18px 32px 26px;background:#101218;">
          <p style="font-size:11px;line-height:1.6;color:#5a5f6b;margin:0;text-align:center;">
            Tu reçois cet email car tu as autorisé Izacki à t'envoyer des emails liés au Launcher.<br>
            Tu peux désactiver ça à tout moment dans les paramètres du Launcher.
          </p>
        </td></tr>

      </table>
    </td></tr>
  </table>
</body>
</html>`;

// CORS : les fonctions Edge Supabase ne renvoient RIEN par défaut côté
// CORS — sans ça, l'appel fetch() depuis la fenêtre du Launcher (même
// moteur de rendu qu'un navigateur) échoue silencieusement avec "Failed to
// fetch" avant même d'atteindre le code ci-dessous (le navigateur bloque la
// réponse, pas Supabase). "*" est sans risque ici : cette fonction n'expose
// aucune donnée, elle ne fait que déclencher un envoi figé.
const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  // Requête préliminaire (preflight) que le navigateur envoie tout seul
  // avant le vrai POST dès qu'un en-tête personnalisé (ici Authorization)
  // est présent — doit répondre 200 avec les en-têtes CORS, sans ça le vrai
  // POST n'est jamais envoyé.
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), { status: 405, headers: CORS_HEADERS });
  }

  // Authentification minimale : n'importe quel compte connecté peut
  // déclencher CET envoi de test précis (destinataire et contenu figés,
  // voir le commentaire de tête), mais pas un envoi arbitraire — un
  // en-tête Authorization Bearer valide (le JWT Supabase du joueur) suffit
  // à prouver qu'il ne s'agit pas d'un robot anonyme qui spam l'endpoint.
  const authHeader = req.headers.get("Authorization") || "";
  if (!authHeader.startsWith("Bearer ")) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: CORS_HEADERS });
  }

  const resendApiKey = Deno.env.get("RESEND_API_KEY");
  if (!resendApiKey) {
    return new Response(JSON.stringify({ error: "missing_resend_api_key" }), { status: 500, headers: CORS_HEADERS });
  }

  const resendRes = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: FROM_ADDRESS,
      to: [TEST_RECIPIENT],
      subject: EMAIL_SUBJECT,
      html: EMAIL_HTML,
      text: EMAIL_TEXT,
    }),
  });

  const resendData = await resendRes.json().catch(() => ({}));
  if (!resendRes.ok) {
    return new Response(JSON.stringify({ error: "resend_error", detail: resendData }), { status: 502, headers: CORS_HEADERS });
  }

  return new Response(JSON.stringify({ ok: true, id: resendData.id }), {
    status: 200,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
});
