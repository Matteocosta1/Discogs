// Funzione Supabase "ai-cover": l'unico posto dove sta la chiave di Anthropic.
// Un solo compito, come gli occhi di JARVIS:
//   task "scan": l'app manda una foto o i fotogrammi di un video; Claude dice TUTTI i dischi che vede.
//
// Pubblicazione:  supabase functions deploy ai-cover
// Secret:         supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
// (SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY ci sono già: li mette Supabase.)

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const MODEL = Deno.env.get("AI_MODEL_SCAN") ?? "claude-sonnet-5-5";
// Prezzi in dollari per milione di token (input, output); per prudenza 1 $ = 1 €.
const PRICES: Record<string, [number, number]> = {
  "claude-haiku-4-5": [1, 5],
  "claude-sonnet-5-5": [2, 10],
  "claude-opus-5-5": [4, 20],
};
const MAX_PHOTOS = 8;

const SCAN_SCHEMA = {
  type: "object",
  properties: {
    records: {
      type: "array",
      items: {
        type: "object",
        properties: {
          artist: { type: "string" },
          title: { type: "string" },
          label: { type: "string" },
          catno: { type: "string" },
          barcode: { type: "string" },
          year: { type: "string" },
          images: { type: "array", items: { type: "integer" } },
        },
        required: ["artist", "title", "label", "catno", "barcode", "year", "images"],
        additionalProperties: false,
      },
    },
  },
  required: ["records"],
  additionalProperties: false,
};

const SCAN_PROMPT = `The {n} numbered image(s) above were taken by a record seller with a phone camera: a single photo, or frames of a short video in which the seller shows one or more VINYL records (LP, 12", 10", 7") one after the other.

List every DISTINCT vinyl record you can identify. The same record can appear in several images (front cover, back cover, centre label, close-ups): list it ONCE, with the numbers of all the images where it appears.

For each record:
- artist and title: from the main printed text (large on the cover or on the label) or, if you recognise the artwork, from your knowledge of the record.
- label, catno (the record's own catalogue number), barcode (digits only), year: ONLY if clearly readable in the images; otherwise an empty string. Never guess printed details.
- A tracklist is NOT the record: never take artist, title or catalogue number from tracklist lines ("A1 ...") or from references like "From the album 'X'".
- images: the numbers of the images showing this record.

Skip records you cannot identify at all (no readable text and artwork you do not recognise). If there is no identifiable record, return an empty list.`;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

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

  // 3. Richiesta a Claude: ogni immagine con il suo numero, poi le istruzioni
  const body = await req.json();
  if (body.task !== "scan") return json({ error: "compito sconosciuto: aggiorna l'app" }, 400);
  const photos: string[] = (body.photos ?? []).slice(0, MAX_PHOTOS);
  if (photos.length === 0) return json({ records: [], cost: 0 });
  const content: unknown[] = [];
  photos.forEach((data, i) => {
    content.push({ type: "text", text: `Image ${i + 1}:` });
    content.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data } });
  });
  content.push({ type: "text", text: SCAN_PROMPT.replace("{n}", String(photos.length)) });

  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": Deno.env.get("ANTHROPIC_API_KEY")!,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 4000,
      messages: [{ role: "user", content }],
      output_config: { format: { type: "json_schema", schema: SCAN_SCHEMA }, effort: "low" },
    }),
  });
  if (!res.ok) return json({ error: `Anthropic ${res.status}: ${await res.text()}` }, 502);
  const msg = await res.json();

  // 4. Costo, registro e risposta
  const [pin, pout] = PRICES[MODEL] ?? [5, 25];
  const cost = (msg.usage.input_tokens * pin + msg.usage.output_tokens * pout) / 1e6;
  await admin.from("ai_calls").insert({
    user_id: user.id, task: "scan", model: MODEL, input_tokens: msg.usage.input_tokens,
    output_tokens: msg.usage.output_tokens, cost_eur: cost,
  });
  await admin.rpc("add_ai_usage", { p_user: user.id, p_cost: cost });
  const text = (msg.content ?? []).find((b: { type: string }) => b.type === "text")?.text ?? "{}";
  let records: Record<string, unknown>[] = [];
  try {
    records = msg.stop_reason === "end_turn" ? (JSON.parse(text).records ?? []) : [];
  } catch {
    records = [];
  }
  const clean = (v: unknown) => String(v ?? "").trim();
  return json({
    records: records.map((r) => ({
      artist: clean(r.artist), title: clean(r.title), label: clean(r.label), catno: clean(r.catno),
      barcode: clean(r.barcode), year: clean(r.year),
      images: Array.isArray(r.images) ? r.images.filter((n) => Number.isInteger(n)) : [],
    })),
    cost,
  });
});
