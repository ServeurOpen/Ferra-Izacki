// ============================================================
// Izacki — Fonction Edge : statistiques du panel admin DU SITE WEB
// (05/09/2026, demande explicite : "nombre de téléchargement launcher,
// nombre de visite sur le site, les gens connectés/inscription, les gens
// non rien... des graphiques comparé à hier... le plus beau des panels").
//
// Même schéma de sécurité que supabase/functions/admin-stats (panel du
// Launcher) : réservé à ferra.izacki@gmail.com, revérifié ICI côté serveur
// (jamais fié au seul JS de la page), lecture des tables site_visits /
// launcher_downloads (aucune policy select ne les rend lisibles
// directement côté client, même pour l'auteur d'une ligne) via la clé de
// service.
//
// Déploiement : Dashboard Supabase -> Edge Functions -> Create a new
// function -> nom "admin-site-stats" -> coller ce fichier -> Deploy. Rien à
// ajouter dans Secrets (SUPABASE_SERVICE_ROLE_KEY est fourni par la plateforme).
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const ADMIN_EMAILS = ["ferra.izacki@gmail.com"];
const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function dayKey(iso: string): string {
  return iso.slice(0, 10);
}

// 14 derniers jours, aujourd'hui inclus, dans l'ordre chronologique —
// même construction que admin-stats pour rester cohérent visuellement
// entre les deux panels (Launcher et site).
function buildDayBuckets(): Map<string, number> {
  const buckets = new Map<string, number>();
  const today = new Date();
  for (let i = 13; i >= 0; i--) {
    const d = new Date(today);
    d.setUTCDate(d.getUTCDate() - i);
    buckets.set(d.toISOString().slice(0, 10), 0);
  }
  return buckets;
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

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: callerData, error: callerErr } = await callerClient.auth.getUser();
  const callerEmail = (callerData?.user?.email || "").trim().toLowerCase();
  if (callerErr || !ADMIN_EMAILS.includes(callerEmail)) {
    return new Response(JSON.stringify({ error: "forbidden" }), { status: 403, headers: CORS_HEADERS });
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // "En ligne maintenant" (05/09/2026, demande explicite : "le nombre de
  // total de joueur connecté en simultanée") — basé sur les sessions
  // Launcher dont le dernier battement de cœur (toutes les 60s tant que
  // l'appli tourne, voir migration_13) date de moins de 3 minutes ET qui
  // n'ont pas été fermées proprement. Une fenêtre de 3 minutes (pas 60s
  // pile) absorbe un battement en retard sans compter quelqu'un comme
  // hors-ligne trop vite ; au-delà, on considère l'appli fermée/plantée.
  const onlineThreshold = new Date(Date.now() - 3 * 60_000).toISOString();

  const [visitsRes, downloadsRes, usersRes, onlineRes, profilesRes] = await Promise.all([
    admin.from("site_visits").select("path, user_id, created_at"),
    admin.from("launcher_downloads").select("created_at"),
    admin.auth.admin.listUsers({ perPage: 1000 }),
    admin.from("launcher_sessions").select("user_id").is("ended_at", null).gt("last_heartbeat", onlineThreshold),
    // Pseudo de chaque joueur (05/09/2026, demande explicite : "je vois le
    // mail mais aussi le nom du joueur qui se compte aussi dans la
    // recherche") — auth.users n'a pas le pseudo, il vit dans profiles.
    admin.from("profiles").select("id, username"),
  ]);

  const visits = visitsRes.data || [];
  const downloads = downloadsRes.data || [];
  const users = usersRes.data?.users || [];
  const onlineNow = new Set((onlineRes.data || []).map((s: any) => s.user_id)).size;
  const usernameById = new Map((profilesRes.data || []).map((p: any) => [p.id, p.username as string]));

  const todayKey = dayKey(new Date().toISOString());
  const yesterdayKey = dayKey(new Date(Date.now() - 86_400_000).toISOString());

  // ---- Visites : total, par jour (14j), aujourd'hui vs hier, connecté vs anonyme ----
  const visitDayBuckets = buildDayBuckets();
  let visitsToday = 0, visitsYesterday = 0, loggedVisits = 0, anonVisits = 0;
  for (const v of visits) {
    const day = dayKey(v.created_at as string);
    if (visitDayBuckets.has(day)) visitDayBuckets.set(day, (visitDayBuckets.get(day) || 0) + 1);
    if (day === todayKey) visitsToday++;
    if (day === yesterdayKey) visitsYesterday++;
    if (v.user_id) loggedVisits++; else anonVisits++;
  }
  const visitsByDay = Array.from(visitDayBuckets.entries()).map(([date, count]) => ({ date, count }));

  // ---- Téléchargements Launcher : total, par jour (14j), aujourd'hui vs hier ----
  const dlDayBuckets = buildDayBuckets();
  let downloadsToday = 0, downloadsYesterday = 0;
  for (const d of downloads) {
    const day = dayKey(d.created_at as string);
    if (dlDayBuckets.has(day)) dlDayBuckets.set(day, (dlDayBuckets.get(day) || 0) + 1);
    if (day === todayKey) downloadsToday++;
    if (day === yesterdayKey) downloadsYesterday++;
  }
  const downloadsByDay = Array.from(dlDayBuckets.entries()).map(([date, count]) => ({ date, count }));

  // ---- Comptes : total, créés aujourd'hui/hier ----
  let accountsToday = 0, accountsYesterday = 0;
  for (const u of users) {
    const day = dayKey((u.created_at as string) || "");
    if (day === todayKey) accountsToday++;
    if (day === yesterdayKey) accountsYesterday++;
  }

  const players = users
    .map((u: any) => ({
      userId: u.id,
      email: u.email || "",
      username: usernameById.get(u.id) || "",
      createdAt: u.created_at || null,
      lastSignInAt: u.last_sign_in_at || null,
    }))
    .sort((a, b) => (b.createdAt || "").localeCompare(a.createdAt || ""));

  return new Response(
    JSON.stringify({
      visitsTotal: visits.length,
      visitsToday,
      visitsYesterday,
      visitsByDay,
      loggedVisits,
      anonVisits,
      downloadsTotal: downloads.length,
      downloadsToday,
      downloadsYesterday,
      downloadsByDay,
      accountsTotal: users.length,
      accountsToday,
      accountsYesterday,
      onlineNow,
      players,
    }),
    { status: 200, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } }
  );
});
