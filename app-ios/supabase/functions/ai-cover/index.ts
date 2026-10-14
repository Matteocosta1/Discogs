// Funzione Supabase "ai-cover": l'unico posto dove sta la chiave di Anthropic.
// L'app manda le foto (e le copertine dei candidati); qui si chiama Claude e si risponde con la scelta.
// Due compiti, gli stessi di vendi.py:
//   task "match": quale candidato ha la stessa copertina delle foto (AI_COVER_PROMPT)
//   task "read":  cosa c'è scritto sul disco (AI_READ_PROMPT)
//
// Pubblicazione:  supabase functions deploy ai-cover
// Secret:         supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
// (SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY ci sono già: li mette Supabase.)

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const MODELS = {
  match: Deno.env.get("AI_MODEL_MATCH") ?? "claude-opus-5-5",   // copertine: il modello più accurato
  read: Deno.env.get("AI_MODEL_READ") ?? "claude-haiku-4-5",    // lettura: il più economico
};
// Prezzi in dollari per milione di token (input, output); per prudenza 1 $ = 1 €, come lo script.
const PRICES: Record<string, [number, number]> = {
  "claude-haiku-4-5": [1, 5],
  "claude-sonnet-5-5": [2, 10],
  "claude-opus-5-5": [4, 20],
};
const NO_THINKING = new Set(["claude-haiku-4-5"]);

const COVER_SCHEMA = {
  type: "object",
  properties: {
    release_id: { type: "integer" },
    confidence: { type: "string", enum: ["high", "medium", "low"] },
    reason: { type: "string" },
  },
  required: ["release_id", "confidence", "reason"],
  additionalProperties: false,
};

const READ_FIELDS = ["artist", "title", "label", "catno", "year", "country", "barcode", "readable_text",
  "recognized_artist", "recognized_title"];
const READ_SCHEMA = {
  type: "object",
  properties: {
    photo_type: { type: "string", enum: ["front", "back", "label", "other"] },
    compilation: { type: "boolean" },
    ...Object.fromEntries(READ_FIELDS.map((k) => [k, { type: "string" }])),
  },
  required: ["photo_type", "compilation", ...READ_FIELDS],
  additionalProperties: false,
};

const COVER_PROMPT = `You are checking which Discogs release a vinyl record is, by comparing ARTWORK.

The first {n_photos} image(s) are photos of the record taken by the seller (front and back sleeve; they may be
taken at an angle, with glare, shrink-wrap, stickers or wear). After them come Discogs reference images:
{candidates}

Decide whether the seller's photos show the SAME sleeve artwork as one candidate's images: same layout, same
picture or illustration, same typography and logo placement, same colors. Ignore differences caused by lighting,
angle, perspective, glare, wear, price stickers and shrink-wrap. Different pressings can share the same artwork:
if two candidates look identical, prefer the one whose details (label, catalog number, country, text) match what
is visible in the photos; if you cannot tell them apart, answer the closest one with confidence "medium".
If NO candidate shows the same artwork, answer release_id 0.
Use confidence "high" only if you are sure the artwork is the same.`;

const READ_PROMPT = `These {n} photos all show the SAME single vinyl record from different sides (front cover, back cover, centre label): they are ONE record.
The record is ALWAYS a vinyl record (LP, 12", 10" or 7"), never a CD, cassette or digital release.
Report what you can see. Transcribe printed details exactly; use an empty string when something is not clearly readable. Never guess printed details.
Identify THIS record only from its MAIN printed details: the artist and title printed large on the cover or label, the record's own catalogue number and its barcode.
A tracklist is NOT the record: never take artist, title or catalogue number from tracklist lines (e.g. "A1 ...") or from references such as "From the album 'X' ABC/12 [1973]".
If the tracklist shows several different artists, this record is probably a compilation: report the header artist/title and set compilation to true.
- photo_type: front, back, label or other.
- artist, title, label, catno, year, country, barcode (digits).
- readable_text: the most useful readable text, one item per line, at most 40 lines.
- recognized_artist / recognized_title: if you recognise the record from its artwork, the artist and album you believe it is; otherwise empty.`;

type Candidate = { release_id: number; title: string; images: string[] };

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

const image = (data: string) => ({ type: "image", source: { type: "base64", media_type: "image/jpeg", data } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "solo POST" }, 405);
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // 1. Chi chiama? Solo utenti dell'app con una sessione valida.
  const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: auth } = await admin.auth.getUser(jwt);
  const user = auth?.user;
  if (!user) return json({ error: "accesso richiesto" }, 401);

  // 2. Tetto di spesa del mese
  const month = new Date().toISOString().slice(0, 7) + "-01";
  const { data: profile } = await admin.from("profiles").select("ai_monthly_cap_eur").eq("id", user.id).single();
  const { data: usage } = await admin.from("usage_monthly").select("ai_cost_eur")
    .eq("user_id", user.id).eq("month", month).maybeSingle();
  if (Number(usage?.ai_cost_eur ?? 0) >= Number(profile?.ai_monthly_cap_eur ?? 3)) {
    return json({ error: "tetto AI del mese raggiunto" }, 402);
  }

  // 3. Richiesta a Claude
  const body = await req.json();
  const task = body.task === "read" ? "read" : "match";
  const photos: string[] = (body.photos ?? []).slice(0, 4);
  const model = MODELS[task];
  let content: unknown[];
  let schema: unknown;
  let maxTokens: number;
  if (task === "match") {
    const candidates: Candidate[] = (body.candidates ?? []).slice(0, 3);
    let n = photos.length;
    const lines: string[] = [];
    const images = photos.map(image);
    candidates.forEach((c, i) => {
      const first = n + 1, last = n + c.images.length;
      lines.push(`- Candidate ${i + 1}: release_id ${c.release_id} = images ${first}-${last}: ${c.title}`);
      images.push(...c.images.map(image));
      n = last;
    });
    const prompt = COVER_PROMPT.replace("{n_photos}", String(photos.length)).replace("{candidates}", lines.join("\n"));
    content = [...images, { type: "text", text: prompt }];
    schema = COVER_SCHEMA;
    maxTokens = 400;
  } else {
    content = [...photos.map(image), { type: "text", text: READ_PROMPT.replaceAll("{n}", String(photos.length)) }];
    schema = READ_SCHEMA;
    maxTokens = 1200;
  }
  const outputConfig: Record<string, unknown> = { format: { type: "json_schema", schema } };
  if (!NO_THINKING.has(model)) {
    maxTokens += 6000;
    outputConfig.effort = "medium";
  }
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": Deno.env.get("ANTHROPIC_API_KEY")!,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({ model, max_tokens: maxTokens, messages: [{ role: "user", content }], output_config: outputConfig }),
  });
  if (!res.ok) return json({ error: `Anthropic ${res.status}: ${await res.text()}` }, 502);
  const msg = await res.json();

  // 4. Costo, registro e risposta
  const [pin, pout] = PRICES[model] ?? [5, 25];
  const cost = (msg.usage.input_tokens * pin + msg.usage.output_tokens * pout) / 1e6;
  await admin.from("ai_calls").insert({
    user_id: user.id, task, model, input_tokens: msg.usage.input_tokens, output_tokens: msg.usage.output_tokens,
    cost_eur: cost,
  });
  await admin.rpc("add_ai_usage", { p_user: user.id, p_cost: cost });
  const text = (msg.content ?? []).find((b: { type: string }) => b.type === "text")?.text ?? "{}";
  let result: Record<string, unknown> = {};
  try {
    result = msg.stop_reason === "end_turn" ? JSON.parse(text) : {};
  } catch {
    result = {};
  }
  if (task === "match") {
    return json({ release_id: result.release_id ?? 0, confidence: result.confidence ?? "low",
      reason: result.reason ?? "", cost });
  }
  return json({
    ...Object.fromEntries(READ_FIELDS.map((k) => [k, String(result[k] ?? "").trim()])),
    compilation: Boolean(result.compilation), cost,
  });
});
