import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Autenticazione richiesta" }, 401);
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const openaiKey = Deno.env.get("OPENAI_API_KEY");
    if (!openaiKey) return json({ error: "Chiave AI non configurata sul server" }, 500);
    const userClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
    const { data: userData, error: userError } = await userClient.auth.getUser();
    if (userError || !userData.user) return json({ error: "Sessione non valida" }, 401);
    const body = await req.json();
    const gameId = String(body.game_id || "");
    const { data: membership, error: memberError } = await userClient
      .from("game_members").select("id").eq("game_id", gameId).eq("user_id", userData.user.id).maybeSingle();
    if (memberError || !membership) return json({ error: "Non fai parte di questa partita" }, 403);

    const mode = String(body.mode || "MilSim").slice(0, 40);
    const count = Math.max(2, Math.min(10, Number(body.count) || 5));
    const duration = Math.max(10, Math.min(240, Number(body.duration) || 90));
    const players = Math.max(2, Math.min(100, Number(body.players) || 20));
    const difficulty = String(body.difficulty || "Standard").slice(0, 20);
    const notes = String(body.notes || "").slice(0, 1000);
    const center = body.center || { lat: 41.9, lng: 12.5 };
    const lat = Number(center.lat), lng = Number(center.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat)>90 || Math.abs(lng)>180)
      return json({ error: "Centro mappa non valido" }, 400);

    const system = `Sei il game designer di TACTICAL AI, una piattaforma per giochi sportivi di softair. Crea scenari immaginari e sicuri. Non fornire istruzioni su armi reali, violenza reale, sabotaggi reali o accessi non autorizzati. Tutti gli obiettivi sono props/marker di gioco innocui in un campo autorizzato. Restituisci SOLO JSON valido con: title, briefing, win_condition, objectives. Ogni objective: title, description, lat, lng, team (ALFA|BRAVO|NEUTRAL). Coordinate vicino al centro fornito, entro circa 500 metri; punti indicativi da verificare e approvare sul posto.`;
    const prompt = `Crea una missione ${mode}; durata ${duration} minuti; ${players} giocatori; difficoltà ${difficulty}; ${count} obiettivi. Note: ${notes}. Centro indicativo lat ${lat}, lng ${lng}. Rispondi in italiano e restituisci esattamente ${count} obiettivi con coordinate numeriche.`;
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { "Authorization": `Bearer ${openaiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "gpt-4o-mini",
        temperature: 0.7,
        response_format: { type: "json_object" },
        messages: [{ role: "system", content: system }, { role: "user", content: prompt }]
      })
    });
    const result = await response.json();
    if (!response.ok) return json({ error: result.error?.message || "Errore dal servizio AI" }, 502);
    const content = result.choices?.[0]?.message?.content;
    if (!content) return json({ error: "Risposta AI vuota" }, 502);
    const mission = JSON.parse(content);
    if (!Array.isArray(mission.objectives)) return json({ error: "Formato missione non valido" }, 502);
    mission.objectives = mission.objectives.slice(0, count).map((o: any) => ({
      title: String(o.title || "Obiettivo").slice(0, 90),
      description: String(o.description || "Obiettivo di gioco da verificare").slice(0, 300),
      lat: Number(o.lat), lng: Number(o.lng),
      team: ["ALFA", "BRAVO", "NEUTRAL"].includes(o.team) ? o.team : "NEUTRAL"
    })).filter((o: any) => Number.isFinite(o.lat) && Number.isFinite(o.lng) &&
      Math.abs(o.lat-lat)<0.02 && Math.abs(o.lng-lng)<0.03);
    if (mission.objectives.length < 2) return json({ error: "Coordinate AI non valide: riprova" }, 502);
    return json({ mission });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : "Errore imprevisto" }, 500);
  }
});
