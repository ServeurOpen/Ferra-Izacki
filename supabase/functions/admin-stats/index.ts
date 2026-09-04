// ============================================================
// Izacki — Fonction Edge : statistiques du panel admin (05/09/2026, demande
// explicite : "graphique des connexions au launcher total/quotidien...
// quel joueur quel mail... les jeux du joueur où il est resté le plus
// longtemps").
//
// Réservée à ferra.izacki@gmail.com — vérifié ICI, côté serveur (jamais en
// se fiant au seul JS du Launcher, qui pourrait être contourné). Utilise la
// clé de service (SUPABASE_SERVICE_ROLE_KEY, fournie automatiquement à
// toute fonction Edge, pas besoin de l'ajouter comme secret) pour lire :
//  - la liste des comptes + emails (auth.admin.listUsers — l'email n'existe
//    nulle part dans les tables normales, RLS ou pas, il vit dans le
//    schéma auth, seul le rôle de service peut le lire) ;
//  - toutes les sessions Launcher et tout game_stats SANS filtrage RLS
//    (un admin doit voir même les profils mis en privé par leur joueur).
//
// Déploiement : Dashboard Supabase -> Edge Functions -> Create a new
// function -> nom "admin-stats" -> coller ce fichier -> Deploy. Rien à
// ajouter dans Secrets pour celle-ci (SUPABASE_SERVICE_ROLE_KEY est déjà
// fourni par la plateforme).
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const ADMIN_EMAILS = ["ferra.izacki@gmail.com"];
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

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

  // Client "au nom de l'appelant" — sert UNIQUEMENT à vérifier qui appelle
  // réellement (Supabase valide le JWT lui-même, plus fiable qu'un décodage
  // manuel du token ici).
  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: callerData, error: callerErr } = await callerClient.auth.getUser();
  const callerEmail = (callerData?.user?.email || "").trim().toLowerCase();
  if (callerErr || !ADMIN_EMAILS.includes(callerEmail)) {
    return new Response(JSON.stringify({ error: "forbidden" }), { status: 403, headers: CORS_HEADERS });
  }

  // Client à privilège de service — seul ce client peut lire tous les
  // joueurs (RLS ignorée) et la liste des emails (schéma auth).
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const [usersRes, profilesRes, sessionsRes, gameStatsRes] = await Promise.all([
    admin.auth.admin.listUsers({ perPage: 1000 }),
    admin.from("profiles").select("id, username, display_name, player_number"),
    admin.from("launcher_sessions").select("user_id, started_at, ended_at, last_heartbeat"),
    admin.from("game_stats").select("user_id, game_id, total_secs, last_played_at"),
  ]);

  const profilesById = new Map((profilesRes.data || []).map((p: any) => [p.id, p]));
  const usersById = new Map((usersRes.data?.users || []).map((u: any) => [u.id, u]));

  // ---- Connexions : total + répartition par jour (14 derniers jours) ----
  const sessions = sessionsRes.data || [];
  const dayBuckets = new Map<string, number>();
  const today = new Date();
  for (let i = 13; i >= 0; i--) {
    const d = new Date(today);
    d.setUTCDate(d.getUTCDate() - i);
    dayBuckets.set(d.toISOString().slice(0, 10), 0);
  }
  for (const s of sessions) {
    const day = (s.started_at as string).slice(0, 10);
    if (dayBuckets.has(day)) dayBuckets.set(day, (dayBuckets.get(day) || 0) + 1);
  }
  const connectionsByDay = Array.from(dayBuckets.entries()).map(([date, count]) => ({ date, count }));

  // ---- Par joueur : temps total sur le Launcher + dernière connexion ----
  const perUser = new Map<string, { totalSecs: number; lastSeen: string | null; sessionCount: number }>();
  for (const s of sessions) {
    const started = new Date(s.started_at as string).getTime();
    const end = new Date((s.ended_at as string) || (s.last_heartbeat as string)).getTime();
    const secs = Math.max(0, Math.round((end - started) / 1000));
    const entry = perUser.get(s.user_id as string) || { totalSecs: 0, lastSeen: null, sessionCount: 0 };
    entry.totalSecs += secs;
    entry.sessionCount += 1;
    if (!entry.lastSeen || (s.started_at as string) > entry.lastSeen) entry.lastSeen = s.started_at as string;
    perUser.set(s.user_id as string, entry);
  }

  // ---- Détail des sessions par joueur (05/09/2026, demande explicite :
  // "on voit le détail de ses dernières sessions, 1ere connexion 17 min, 2e
  // 30 min etc.") — les sessions sont déjà chargées ci-dessus (sessionsRes),
  // pas besoin d'un aller-retour réseau supplémentaire ni d'un endpoint
  // séparé : on les regroupe par joueur et on les trie de la plus récente
  // à la plus ancienne, tronquées aux 30 dernières pour ne pas alourdir la
  // réponse sur un compte qui ouvrirait le Launcher très souvent. ----
  const sessionsByUser = new Map<string, { startedAt: string; endedAt: string | null; durationSecs: number }[]>();
  for (const s of sessions) {
    const started = new Date(s.started_at as string).getTime();
    const end = new Date((s.ended_at as string) || (s.last_heartbeat as string)).getTime();
    const secs = Math.max(0, Math.round((end - started) / 1000));
    const list = sessionsByUser.get(s.user_id as string) || [];
    list.push({ startedAt: s.started_at as string, endedAt: (s.ended_at as string) || null, durationSecs: secs });
    sessionsByUser.set(s.user_id as string, list);
  }
  for (const list of sessionsByUser.values()) {
    list.sort((a, b) => (a.startedAt < b.startedAt ? 1 : -1));
    list.length = Math.min(list.length, 30);
  }

  const players = Array.from(usersById.entries()).map(([userId, u]: [string, any]) => {
    const profile: any = profilesById.get(userId) || {};
    const agg = perUser.get(userId) || { totalSecs: 0, lastSeen: null, sessionCount: 0 };
    return {
      userId,
      email: u.email || "",
      username: profile.username || "?",
      tag: profile.player_number ? `${profile.username}#${profile.player_number}` : profile.username || "?",
      createdAt: u.created_at || null,
      totalLauncherSecs: agg.totalSecs,
      sessionCount: agg.sessionCount,
      lastSeen: agg.lastSeen,
      sessions: sessionsByUser.get(userId) || [],
    };
  }).sort((a, b) => b.totalLauncherSecs - a.totalLauncherSecs);

  // ---- Par jeu : temps cumulé TOUS joueurs confondus (voir game_stats) ----
  const gameTotalsMap = new Map<string, number>();
  for (const g of gameStatsRes.data || []) {
    gameTotalsMap.set(g.game_id as string, (gameTotalsMap.get(g.game_id as string) || 0) + (g.total_secs as number || 0));
  }
  const gameTotals = Array.from(gameTotalsMap.entries())
    .map(([gameId, totalSecs]) => ({ gameId, totalSecs }))
    .sort((a, b) => b.totalSecs - a.totalSecs);

  return new Response(
    JSON.stringify({
      connectionsTotal: sessions.length,
      connectionsByDay,
      players,
      gameTotals,
    }),
    { status: 200, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } }
  );
});
