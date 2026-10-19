// memoria — la memoria condivisa dei dischi di tutti gli utenti di Vinyl Hustler.
//   task "lookup": { dhash?: "hex16", reads?: [string] } -> { photo?: Rel, reads: { [read]: Rel } }
//   task "learn":  { dhash?: "hex16", read?: string, release_id, title?, cover? } -> { ok: true }
// Solo testo e impronte numeriche, niente foto. La tabella si tocca solo da qui (service role).
// Una conferma conta una volta per persona (tabella disc_memory_votes): nessuno può "gonfiare" un disco sbagliato.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const MAX_DIST = 6;                 // bit diversi su 64 per dire "è la stessa foto/copertina"
const MIN_PEOPLE = 2;               // V56: agli altri si propone un abbinamento solo se l'hanno confermato 2+ persone

/** V56: titolo dalla scheda Discogs (non da quello che manda il telefono): "Artista - Titolo (etichetta, paese, anno)". */
async function discogsTitle(release: number): Promise<string | null> {
  try {
    const r = await fetch(`https://api.discogs.com/releases/${release}`, {
      headers: { "User-Agent": "VinylHustler/0.1 +memoria" }, signal: AbortSignal.timeout(4000),
    });
    if (!r.ok) return null;
    const d = await r.json();
    const artist = String(d.artists_sort ?? (d.artists ?? []).map((a: { name: string }) => a.name).join(", ")).trim();
    const extra = [d.labels?.[0]?.name, d.country, d.year || null].filter((x) => x).join(", ");
    const t = [artist, String(d.title ?? "").trim()].filter((x) => x).join(" - ");
    return t ? (extra ? `${t} (${extra})` : t).slice(0, 300) : null;
  } catch {
    return null;
  }
}
/** V56: solo copertine servite da Discogs. */
function discogsCover(v: unknown): string | null {
  const s = String(v ?? "").slice(0, 500);
  return /^https:\/\/(i|img|st)\.discogs\.com\//.test(s) ? s : null;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
/** "Miles Davis - Kind Of Blue" -> "miles davis kind of blue" */
function norm(s: string): string {
  return s.toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9]+/g, " ").trim();
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
      const { data } = await admin.rpc("lookup_dhash_safe", { p_dhash: big, p_max: MAX_DIST, p_user: auth.user.id, p_min: MIN_PEOPLE });
      if (data?.[0]) out.photo = data[0];
    }
    const reads: string[] = Array.isArray(body.reads) ? body.reads.slice(0, 20).map(String) : [];
    const keys = [...new Set(reads.map(norm).filter((k) => k.length >= 3))];
    if (keys.length) {
      const { data } = await admin.rpc("lookup_reads_safe", { p_keys: keys, p_user: auth.user.id, p_min: MIN_PEOPLE });
      for (const r of reads) {
        const hit = (data ?? []).find((d: { key: string }) => d.key === norm(r));   // il più confermato per quella lettura
        if (hit) out.reads[r] = hit;
      }
    }
    return json(out);
  }

  if (body.task === "learn") {
    const release = Number(body.release_id);
    if (!Number.isInteger(release) || release <= 0) return json({ error: "release mancante" }, 400);
    const title = await discogsTitle(release);       // V56: dal server, non dal telefono
    const cover = discogsCover(body.cover);
    const big = typeof body.dhash === "string" ? toBig(body.dhash) : null;
    if (big) {
      await admin.rpc("learn_disc", { p_user: auth.user.id, p_kind: "dhash", p_key: body.dhash.toLowerCase(), p_dhash: big,
                                      p_release: release, p_title: title, p_cover: cover });
    }
    const read = body.read ? norm(String(body.read)) : "";
    if (read.length >= 3) {
      await admin.rpc("learn_disc", { p_user: auth.user.id, p_kind: "read", p_key: read.slice(0, 200), p_dhash: null,
                                      p_release: release, p_title: title, p_cover: cover });
    }
    return json({ ok: true });
  }

  return json({ error: "compito sconosciuto" }, 400);
});
