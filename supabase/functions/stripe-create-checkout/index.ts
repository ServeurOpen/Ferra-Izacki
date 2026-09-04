// ============================================================
// Izacki — Fonction Edge : crée une session de paiement Stripe pour
// recharger le solde de crédits (05/09/2026).
//
// Le montant ET le nombre de crédits sont fixés ICI, côté serveur
// (CREDIT_PACKAGES), jamais envoyés en clair par le client — sinon un
// joueur pourrait demander "10000 crédits pour 0,01€" en trafiquant
// l'appel réseau. Le client ne choisit qu'un identifiant de forfait
// (ex. "1000") parmi cette liste fermée.
//
// Déploiement : Dashboard Supabase -> Edge Functions -> Create a new
// function -> nom "stripe-create-checkout" -> coller ce fichier -> Deploy.
// Secret à ajouter : STRIPE_SECRET_KEY (ta clé secrète Stripe, sk_test_...
// pour l'instant, jamais sk_live_... tant que tu n'es pas prêt pour de
// vrais paiements).
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import Stripe from "npm:stripe@17";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// 100 crédits = 1€ (taux fixé dès le départ du projet). Ajoute/retire des
// paliers ici librement, aucun autre fichier à changer.
const CREDIT_PACKAGES: Record<string, { amountCents: number; credits: number; label: string }> = {
  "500": { amountCents: 500, credits: 500, label: "500 crédits" },
  "1000": { amountCents: 1000, credits: 1000, label: "1000 crédits" },
  "2000": { amountCents: 2000, credits: 2000, label: "2000 crédits" },
  "5000": { amountCents: 5000, credits: 5000, label: "5000 crédits" },
};

const SITE_ORIGIN = "https://serveuropen.github.io/Ferra-Izacki";

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

  let packageId = "";
  try {
    const body = await req.json();
    packageId = String(body.packageId || "");
  } catch {
    return new Response(JSON.stringify({ error: "bad_request" }), { status: 400, headers: CORS_HEADERS });
  }
  const pkg = CREDIT_PACKAGES[packageId];
  if (!pkg) {
    return new Response(JSON.stringify({ error: "unknown_package" }), { status: 400, headers: CORS_HEADERS });
  }

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: callerData, error: callerErr } = await callerClient.auth.getUser();
  if (callerErr || !callerData?.user) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: CORS_HEADERS });
  }

  const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
    apiVersion: "2024-06-20",
    httpClient: Stripe.createFetchHttpClient(),
  });

  try {
    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      // Pas de "payment_method_types" ici : avec Managed Payments (activé
      // sur ce compte), Stripe choisit lui-même les moyens de paiement à
      // proposer — ce paramètre est désormais rejeté ("Unsupported
      // parameter: payment_method_types"), voir l'erreur du 05/09/2026.
      line_items: [
        {
          price_data: {
            currency: "eur",
            product_data: { name: `Izacki — ${pkg.label}` },
            unit_amount: pkg.amountCents,
          },
          quantity: 1,
        },
      ],
      success_url: `${SITE_ORIGIN}/solde.html?success=1`,
      cancel_url: `${SITE_ORIGIN}/solde.html?canceled=1`,
      // Metadata relue par stripe-webhook une fois le paiement confirmé —
      // c'est la SEULE source de vérité pour savoir qui créditer et de
      // combien, jamais un champ renvoyé par le navigateur du joueur.
      metadata: { user_id: callerData.user.id, credits: String(pkg.credits) },
    });

    return new Response(JSON.stringify({ url: session.url }), {
      status: 200,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("[stripe-create-checkout]", err);
    return new Response(JSON.stringify({ error: "stripe_error" }), { status: 502, headers: CORS_HEADERS });
  }
});
