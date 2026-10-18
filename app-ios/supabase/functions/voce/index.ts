// voce — fa parlare Vinyl Hustler con la voce ElevenLabs scelta da Alessandro.
// La chiave sta SOLO qui sul server (secret ELEVENLABS_API_KEY), mai nell'app.
//
// POST { text, stream?, fast? }  -> la frase
//   1. si applica la pronuncia condivisa (tabella voice_lexicon: "miles davis" -> "Màils Dèivis")
//   2. se la frase è già stata generata per qualcuno, si restituisce quella (WAV, bucket "voce"): gratis
//   3. altrimenti ElevenLabs: in streaming (PCM 24 kHz, l'app parla subito) o mp3 intero;
//      intanto la si salva nel bucket, così la prossima volta è gratis per tutti.
// POST { task: "lexicon" }               -> { rules: [{ word, say_as }] }
// POST { task: "lexicon_set", word, say } -> salva una regola (say vuoto = la toglie)
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const VOICE_ID = "37FWDeENZrUWBEHOcBcO";          // la voce di Vinyl Hustler (non quella di JARVIS)
const MODELS: Record<string, string> = { full: "eleven_multilingual_v2", fast: "eleven_flash_v2_5" };
const MAX_CHARS = 400;
const RATE = 24000;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

async function sha256(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function escapeRe(s: string) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }

/** applica le regole di pronuncia, parole più lunghe prima ("miles davis" prima di "miles") */
function pronounce(text: string, rules: { word: string; say_as: string }[]): string {
  let out = text;
  for (const r of [...rules].sort((a, b) => b.word.length - a.word.length)) {
    out = out.replace(new RegExp(`(^|[^\\p{L}\\p{N}])${escapeRe(r.word)}(?=$|[^\\p{L}\\p{N}])`, "giu"), `$1${r.say_as}`);
  }
  return out;
}

function wavHeader(bytes: number): Uint8Array {
  const b = new ArrayBuffer(44), v = new DataView(b);
  const w = (o: number, s: string) => [...s].forEach((c, i) => v.setUint8(o + i, c.charCodeAt(0)));
  w(0, "RIFF"); v.setUint32(4, 36 + bytes, true); w(8, "WAVE"); w(12, "fmt ");
  v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
  v.setUint32(24, RATE, true); v.setUint32(28, RATE * 2, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true);
  w(36, "data"); v.setUint32(40, bytes, true);
  return new Uint8Array(b);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "solo POST" }, 405);
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: auth } = await admin.auth.getUser(jwt);
  if (!auth?.user) return json({ error: "accesso richiesto" }, 401);
  const body = await req.json().catch(() => ({}));

  // --- pronuncia condivisa ---
  if (body.task === "lexicon") {
    const { data } = await admin.from("voice_lexicon").select("word, say_as").order("word");
    return json({ rules: data ?? [] });
  }
  if (body.task === "lexicon_set") {
    const word = String(body.word ?? "").trim().toLowerCase().slice(0, 100);
    const say = String(body.say ?? "").trim().slice(0, 150);
    if (!word) return json({ error: "parola mancante" }, 400);
    if (!say) await admin.from("voice_lexicon").delete().eq("word", word);
    else await admin.from("voice_lexicon").upsert({ word, say_as: say, updated_by: auth.user.id, updated_at: new Date().toISOString() });
    return json({ ok: true });
  }

  // --- una frase ---
  const key = Deno.env.get("ELEVENLABS_API_KEY");
  if (!key) return json({ error: "manca ELEVENLABS_API_KEY su Supabase" }, 500);
  const raw = String(body.text ?? "").trim().slice(0, MAX_CHARS);
  if (!raw) return json({ error: "testo vuoto" }, 400);
  const model = body.fast === true ? MODELS.fast : MODELS.full;
  const { data: rules } = await admin.from("voice_lexicon").select("word, say_as");
  const text = pronounce(raw, rules ?? []);
  const name = `${await sha256(`${VOICE_ID}|${model}|${text}`)}`;

  // già detta da qualcuno? gratis
  const hit = await admin.storage.from("voce").download(`${name}.wav`);
  if (hit.data) return new Response(hit.data, { headers: { "Content-Type": "audio/wav", "X-Voce": "condivisa" } });
  const hitMp3 = await admin.storage.from("voce").download(`${name}.mp3`);
  if (hitMp3.data) return new Response(hitMp3.data, { headers: { "Content-Type": "audio/mpeg", "X-Voce": "condivisa" } });

  const stream = body.stream === true;
  const url = stream
    ? `https://api.elevenlabs.io/v1/text-to-speech/${VOICE_ID}/stream?output_format=pcm_24000`
    : `https://api.elevenlabs.io/v1/text-to-speech/${VOICE_ID}?output_format=mp3_44100_128`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "xi-api-key": key, "Content-Type": "application/json" },
    body: JSON.stringify({ text, model_id: model, language_code: "it", voice_settings: { stability: 0.5, similarity_boost: 0.8 } }),
  });
  if (!res.ok || !res.body) return json({ error: `ElevenLabs ${res.status}: ${(await res.text()).slice(0, 300)}` }, 502);

  // una copia va all'app, l'altra si salva per tutti (finita la frase)
  const [toApp, toStore] = res.body.tee();
  const save = (async () => {
    const chunks: Uint8Array[] = [];
    const reader = toStore.getReader();
    for (;;) { const { done, value } = await reader.read(); if (done) break; chunks.push(value); }
    const size = chunks.reduce((s, c) => s + c.length, 0);
    if (size < 1000) return;
    const parts = stream ? [wavHeader(size), ...chunks] : chunks;
    await admin.storage.from("voce").upload(`${name}.${stream ? "wav" : "mp3"}`, new Blob(parts),
      { contentType: stream ? "audio/wav" : "audio/mpeg", upsert: true });
  })().catch(() => {});
  // @ts-ignore EdgeRuntime esiste sulle funzioni Supabase
  if (typeof EdgeRuntime !== "undefined") EdgeRuntime.waitUntil(save);

  return new Response(toApp, { headers: { "Content-Type": stream ? `audio/pcm;rate=${RATE}` : "audio/mpeg", "X-Voce": "nuova" } });
});
