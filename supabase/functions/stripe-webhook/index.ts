// ============================================================
// Izacki — Fonction Edge : webhook Stripe, crédite le solde une fois le
// paiement RÉELLEMENT confirmé par Stripe (05/09/2026).
//
// Appelée directement par les serveurs de Stripe (jamais par le
// Launcher/site) — pas de jeton Supabase ici, l'authenticité vient de la
// SIGNATURE Stripe (en-tête stripe-signature), vérifiée avec
// STRIPE_WEBHOOK_SECRET. C'est ce qui empêche n'importe qui d'appeler
// cette fonction pour se créditer gratuitement.
//
// ⚠️ IMPORTANT AU DÉPLOIEMENT : dans les réglages de CETTE fonction
// (Dashboard Supabase -> Edge Functions -> stripe-webhook -> Settings),
// désactive "Verify JWT" — Stripe n'envoie pas de jeton Supabase, la
// requête serait sinon rejetée avant même d'arriver ici.
//
// Déploiement :
//  1. Dashboard Supabase -> Edge Functions -> Create a new function ->
//     nom "stripe-webhook" -> coller ce fichier -> Deploy.
//  2. Désactive "Verify JWT" pour cette fonction (voir ci-dessus).
//  3. Copie l'URL de la fonction (affichée dans le Dashboard).
//  4. Dashboard Stripe -> Developers -> Webhooks -> Add endpoint -> colle
//     cette URL -> événement à écouter : "checkout.session.completed".
//  5. Stripe affiche un "Signing secret" (whsec_...) -> ajoute-le comme
//     secret Supabase STRIPE_WEBHOOK_SECRET (en plus de STRIPE_SECRET_KEY,
//     déjà ajouté pour stripe-create-checkout).
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import Stripe from "npm:stripe@17";

Deno.serve(async (req: Request) => {
  const signature = req.headers.get("stripe-signature");
  const body = await req.text();

  const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
    apiVersion: "2024-06-20",
    httpClient: Stripe.createFetchHttpClient(),
  });

  let event: Stripe.Event;
  try {
    // Vérification async avec le fournisseur crypto "Web Crypto" — la
    // vérification synchrone habituelle de Stripe repose sur l'API Node
    // "crypto", indisponible telle quelle dans Deno/edge runtimes.
    const cryptoProvider = Stripe.createSubtleCryptoProvider();
    event = await stripe.webhooks.constructEventAsync(
      body,
      signature!,
      Deno.env.get("STRIPE_WEBHOOK_SECRET")!,
      undefined,
      cryptoProvider
    );
  } catch (err) {
    console.error("[stripe-webhook] signature invalide :", err);
    return new Response("invalid signature", { status: 400 });
  }

  if (event.type === "checkout.session.completed") {
    const session = event.data.object as Stripe.Checkout.Session;
    const userId = session.metadata?.user_id;
    const credits = parseInt(session.metadata?.credits || "0", 10);

    if (userId && credits > 0) {
      const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
      const { error } = await admin.rpc("credit_stripe_topup", {
        p_session_id: session.id,
        p_user_id: userId,
        p_amount_credits: credits,
        p_amount_cents: session.amount_total || 0,
      });
      if (error) console.error("[stripe-webhook] credit_stripe_topup a échoué :", error);
    }
  }

  // Toujours répondre 200 à Stripe pour un événement reçu et traité (même
  // ignoré volontairement, ex. un type d'événement qu'on ne gère pas) —
  // sinon Stripe réessaiera indéfiniment cet événement.
  return new Response(JSON.stringify({ received: true }), { status: 200, headers: { "Content-Type": "application/json" } });
});
