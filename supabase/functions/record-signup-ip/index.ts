// ============================================================
// Izacki — Fonction Edge : capture l'IP à l'inscription, pour le plafond
// anti-abus du parrainage (05/09/2026, voir migration_18_parrainage.sql).
// Best-effort et volontairement silencieuse en cas d'échec (une IP non
// capturée ne doit jamais bloquer une inscription) : appelée une seule
// fois juste après le tout premier signUp() réussi.
//
// L'IP du VRAI visiteur n'est jamais visible côté client (JS) — seul un
// serveur peut la lire depuis les en-têtes de la requête HTTP. Écrite via
// record_signup_ip() (security definer, "coalesce" — ne s'écrase jamais
// une fois posée), jamais par une simple update() du client, sinon un
// joueur pourrait déclarer n'importe quelle IP lui-même.
//
// Déploiement : Dashboard Supabase -> Edge Functions -> Create a new
// function -> nom "record-signup-ip" -> coller ce fichier -> Deploy.
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
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

  const ip =
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ||
    req.headers.get("x-real-ip") ||
    null;

  if (ip) {
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
    const client = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    await client.rpc("record_signup_ip", { p_ip: ip });
  }

  return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
});
