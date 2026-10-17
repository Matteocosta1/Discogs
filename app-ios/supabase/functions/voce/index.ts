// voce — fa parlare Vinyl Hustler con la voce ElevenLabs scelta da Alessandro.
// La chiave sta SOLO qui sul server (secret ELEVENLABS_API_KEY), mai nell'app.
// POST { text } con la sessione dell'utente -> audio/mpeg.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const VOICE_ID = "37FWDeENZrUWBEHOcBcO";          // la voce di Vinyl Hustler (non quella di JARVIS)
const MODEL = "eleven_multilingual_v2";          // parla bene l'italiano
const MAX_CHARS = 400;                            // frasi brevi: costo sotto controllo

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "solo POST" }, 405);
  const key = Deno.env.get("ELEVENLABS_API_KEY");
  if (!key) return json({ error: "manca ELEVENLABS_API_KEY su Supabase" }, 500);

  // Solo utenti dell'app con una sessione valida
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: auth } = await admin.auth.getUser(jwt);
  if (!auth?.user) return json({ error: "accesso richiesto" }, 401);

  const body = await req.json().catch(() => ({}));
  const text = String(body.text ?? "").trim().slice(0, MAX_CHARS);
  if (!text) return json({ error: "testo vuoto" }, 400);

  const res = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${VOICE_ID}?output_format=mp3_44100_128`, {
    method: "POST",
    headers: { "xi-api-key": key, "Content-Type": "application/json", "Accept": "audio/mpeg" },
    body: JSON.stringify({
      text,
      model_id: MODEL,
      language_code: "it",
      voice_settings: { stability: 0.5, similarity_boost: 0.8 },
    }),
  });
  if (!res.ok) return json({ error: `ElevenLabs ${res.status}: ${(await res.text()).slice(0, 300)}` }, 502);
  return new Response(res.body, { headers: { "Content-Type": "audio/mpeg" } });
});
