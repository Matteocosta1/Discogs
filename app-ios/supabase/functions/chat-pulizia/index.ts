// chat-pulizia (V74): ogni notte (pg_cron, 03:17) cancella le foto della Chat con più di 30 giorni.
// La chiama solo il database: l'intestazione x-chiave deve coincidere con il segreto 'chat_pulizia_chiave'
// del vault, controllato dentro il database (la chiave non è scritta da nessuna parte qui).
// I messaggi restano: l'app mostra «Foto scaduta» al posto dell'immagine.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "solo POST" }, 405);
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const chiave = req.headers.get("x-chiave") ?? "";
  if (chiave.length < 32) return json({ error: "non autorizzato" }, 401);
  const { data: ok } = await admin.rpc("chat_pulizia_ok", { k: chiave });
  if (ok !== true) return json({ error: "non autorizzato" }, 401);

  const { data: nomi, error } = await admin.rpc("chat_foto_scadute");
  if (error) return json({ error: error.message }, 500);
  const lista: string[] = (nomi ?? []).map((n: unknown) => String(n));
  let tolte = 0;
  for (let i = 0; i < lista.length; i += 100) {
    const pezzo = lista.slice(i, i + 100);
    const { data, error: e } = await admin.storage.from("chat-foto").remove(pezzo);
    if (e) return json({ error: e.message, tolte }, 500);
    tolte += data?.length ?? 0;
  }
  return json({ ok: true, tolte });
});
