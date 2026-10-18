// memoria — la memoria condivisa dei dischi di tutti gli utenti di Vinyl Hustler.
//   task "lookup": { dhash?: "hex16", reads?: [string] } -> { photo?: Rel, reads: { [read]: Rel } }
//   task "learn":  { dhash?: "hex16", read?: string, release_id, title?, cover? } -> { ok: true }
// Solo testo e impronte numeriche, niente foto. La tabella si tocca solo da qui (service role).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const MAX_DIST = 6;                 // bit diversi su 64 per dire "è la stessa foto/copertina"

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
/** "Miles Davis - Kind Of Blue" -> "miles davis kind of blue" */
function norm(s: string): string {
  return s.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^a-z0-9]+/g, " ").trim();
}
/** impronta esadecimale (16 cifre) -> bigint con segno, come lo vuole Postgres */
function toBig(hex: string): string | null {
  if (!/^[0-9a-f]{16}$/i.test(hex)) return null;
  return BigInt.asIntN(64, BigInt("0x" + hex)).toString();
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "solo POST" }, 405);
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: auth } = await admin.auth.getUser(jwt);
  if (!auth?.user) return json({ error: "accesso richiesto" }, 401);

  const body = await req.json().catch(() => ({}));

  if (body.task === "lookup") {
    const out: { photo?: unknown; reads: Record<string, unknown> } = { reads: {} };
    const big = typeof body.dhash === "string" ? toBig(body.dhash) : null;
    if (big) {
      const { data } = await admin.rpc("lookup_dhash", { p_dhash: big, p_max: MAX_DIST });
      if (data?.[0]) out.photo = data[0];
    }
    const reads: string[] = Array.isArray(body.reads) ? body.reads.slice(0, 20).map(String) : [];
    const keys = [...new Set(reads.map(norm).filter((k) => k.length >= 3))];
    if (keys.length) {
      const { data } = await admin.from("disc_memory")
        .select("key, release_id, title, cover_url, confirmations")
        .eq("kind", "read").in("key", keys).order("confirmations", { ascending: false });
      for (const r of reads) {
        const hit = (data ?? []).find((d) => d.key === norm(r));   // il più confermato per quella lettura
        if (hit) out.reads[r] = hit;
      }
    }
    return json(out);
  }

  if (body.task === "learn") {
    const release = Number(body.release_id);
    if (!Number.isInteger(release) || release <= 0) return json({ error: "release mancante" }, 400);
    const title = body.title ? String(body.title).slice(0, 300) : null;
    const cover = body.cover ? String(body.cover).slice(0, 500) : null;
    const big = typeof body.dhash === "string" ? toBig(body.dhash) : null;
    if (big) {
      await admin.rpc("learn_disc", { p_kind: "dhash", p_key: body.dhash.toLowerCase(), p_dhash: big,
                                      p_release: release, p_title: title, p_cover: cover });
    }
    const read = body.read ? norm(String(body.read)) : "";
    if (read.length >= 3) {
      await admin.rpc("learn_disc", { p_kind: "read", p_key: read.slice(0, 200), p_dhash: null,
                                      p_release: release, p_title: title, p_cover: cover });
    }
    return json({ ok: true });
  }

  return json({ error: "compito sconosciuto" }, 400);
});
