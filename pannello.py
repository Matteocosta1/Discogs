"""
Pannello visivo dell'inventario: risultati/pannello.html.

Lo genera vendi.py a ogni lancio (insieme agli altri file dei risultati), dallo stato salvato:
- IN VENDITA: ogni disco con foto, nome, grado, prezzo, copie, file CSV di provenienza, stato online;
- DA CONTROLLARE: ogni disco fermo con foto, motivo in chiaro e disco proposto da confrontare.

È una pagina sola, tutta sul Mac: le foto sono miniature JPEG in risultati/miniature/, fatte una volta
sola dalle foto dei lotti; niente va online. Si apre con un doppio clic, in Safari o Chrome.

Si può anche rigenerare da solo, senza elaborare niente:  python pannello.py
"""

import html
import json
import os
import re
import sqlite3
import sys
from pathlib import Path

IMAGE_EXTS = {".jpg", ".jpeg", ".heic", ".heif", ".png"}

# Righe che su Discogs non sono (più) in vendita: nascoste nella vista "Attuali" (restano in "Tutti").
NOT_CURRENT = {"assente", "rimosso", "bozza_cancellata", "scaduto", "sparito", "venduto", "forse_venduto"}

ONLINE_IT = {
    "in_vendita": "Online", "bozza": "Bozza su Discogs", "venduto": "Venduto", "forse_venduto": "Forse venduto",
    "scaduto": "Scaduto", "assente": "Non trovato online", "sparito": "Sparito", "rimosso": "Rimosso",
    "bozza_cancellata": "Bozza cancellata", "bloccato": "Bloccato da Discogs",
}


THUMB_SIZE = 700


THUMB_ERRORS = []   # (foto, errore) delle miniature non riuscite: le prime vengono mostrate da pannello.py


def _thumb_pillow(photo, tmp):
    from PIL import Image, ImageOps
    try:
        import pillow_heif  # foto HEIC dell'iPhone
        pillow_heif.register_heif_opener()
    except ImportError:
        pass
    with Image.open(photo) as img:
        img.draft("RGB", (THUMB_SIZE, THUMB_SIZE))
        small = ImageOps.exif_transpose(img).convert("RGB")
        small.thumbnail((THUMB_SIZE, THUMB_SIZE))
        small.save(tmp, "JPEG", quality=82)


def _thumb_sips(photo, tmp):
    """Su macOS: sips (incluso nel sistema) converte anche le HEIC, se Pillow non ci riesce."""
    import subprocess
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "82", "-Z", str(THUMB_SIZE),
                    str(photo), "--out", str(tmp)], check=True, capture_output=True, timeout=60)


def thumbnail(photo, thumbs_dir):
    """Miniatura JPEG della foto in risultati/miniature/ (fatta una volta sola, poi riusata): Safari non
    mostra le foto prese da altre cartelle del Mac, e le HEIC non si vedono in tutti i browser.
    Prima con Pillow, poi (macOS) con sips. Restituisce il percorso relativo al pannello, o None."""
    import hashlib
    try:
        st = photo.stat()
    except OSError as e:
        THUMB_ERRORS.append((str(photo), str(e)))
        return None
    key = hashlib.sha1(f"{photo}|{st.st_size}|{st.st_mtime_ns}".encode()).hexdigest()[:20]
    target = Path(thumbs_dir) / f"{key}.jpg"
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_name(target.stem + ".tmp.jpg")
        errors = []
        for make in (_thumb_pillow, _thumb_sips) if sys.platform == "darwin" else (_thumb_pillow,):
            try:
                make(photo, tmp)
                tmp.replace(target)
                break
            except Exception as e:
                errors.append(f"{make.__name__[7:]}: {type(e).__name__}: {e}")
        else:
            THUMB_ERRORS.append((str(photo), "; ".join(errors)))
            return None
    return f"{Path(thumbs_dir).name}/{target.name}"


def images_of(path_text, thumbs_dir=None):
    """Foto di un disco: la foto stessa, o le foto della sua sottocartella (fronte prima, per nome).
    Con thumbs_dir: miniature in risultati/miniature/ (se una foto non si apre, il suo file://)."""
    if not path_text:
        return []
    path = Path(path_text)
    try:
        if path.is_dir():
            files = sorted(f for f in path.iterdir() if f.is_file() and f.suffix.lower() in IMAGE_EXTS)
        elif path.is_file():
            files = [path]
        else:
            return []
    except OSError:
        return []
    out = []
    for f in files[:4]:
        thumb = thumbnail(f, thumbs_dir) if thumbs_dir else None
        out.append(thumb or f.as_uri())
    return out


CAND_RE = re.compile(r"^(\d+) (.*?)(?: \[punteggio [^\]]*\])? https://www\.discogs\.com/release/\d+$")


def parse_candidates(text, proposed_id=None, proposed_text="", thumbs=None, cover_dir=None):
    """[{id, testo, foto}] dal testo di format_candidates(); la release proposta sempre per prima.
    foto: miniatura della copertina Discogs, se è già in cache (data/copertine/)."""
    out, seen = [], set()
    if proposed_id:
        out.append({"id": int(proposed_id), "testo": proposed_text or f"release {proposed_id}"})
        seen.add(int(proposed_id))
    for item in (text or "").split(" | "):
        m = CAND_RE.match(item.strip())
        if m and int(m.group(1)) not in seen:
            seen.add(int(m.group(1)))
            out.append({"id": int(m.group(1)), "testo": m.group(2)})
    out = out[:12]
    for c in out:
        cover = Path(cover_dir) / f"{c['id']}-0.jpg" if cover_dir else None
        c["foto"] = (thumbnail(cover, thumbs) if thumbs and cover and cover.exists() else None) or ""
    return out


def _vendi_module():
    import vendi
    return vendi


def lot_folder_of(path_text):
    """Cartella del lotto (quella che contiene le cartelle dei gradi) dalla foto o dalla sottocartella."""
    return str(Path(path_text).parent.parent) if path_text else ""


def lot_of(path_text):
    return Path(path_text).parent.parent.name if path_text else ""


WAITING_SQL = """
    SELECT * FROM foto f
    WHERE f.esito = 'trovato' AND f.fonte = 'manuale' AND COALESCE(f.riga_csv, '') = ''
      AND NOT EXISTS (SELECT 1 FROM annunci_api a
                      WHERE a.external_id = f.external_id OR a.external_id LIKE f.external_id || '-copia%')
"""


ORDER_FILE = "ordine_discogs.json"


def listing_ids(row):
    """Id degli annunci Discogs visti per una riga (colonna online_annunci, JSON)."""
    try:
        return [int(i) for i in json.loads(row["online_annunci"] or "[]")]
    except (ValueError, TypeError, KeyError, IndexError):
        return []


def discogs_order(out_dir):
    """{listing_id: posizione} nell'ordine della pagina Discogs (risultati/ordine_discogs.json), o {}."""
    if not out_dir:
        return {}
    try:
        ids = json.loads((Path(out_dir) / ORDER_FILE).read_text())
        return {int(i): n for n, i in enumerate(ids)}
    except (OSError, ValueError, TypeError):
        return {}


def collect(state, reasons, problems, display_name, listing_owner, not_sellable_reason, out_dir=None):
    """Dati del pannello dallo stato di vendi.py (con out_dir: miniature delle foto in out_dir/miniature)."""
    thumbs = Path(out_dir) / "miniature" if out_dir else None
    cover_dir = getattr(_vendi_module(), "COVER_DIR", None)
    def foto(eid):
        return state.execute("SELECT * FROM foto WHERE external_id = ?", (eid,)).fetchone()

    # File CSV già caricati: almeno una riga vista online. Una riga "non online" di un file mai caricato
    # è solo da caricare (si vede); di un file già caricato è stata scartata o tolta (nascosta).
    uploaded = {r[0] for r in state.execute("SELECT DISTINCT parte FROM righe_csv WHERE online_visto IS NOT NULL")}

    def sale_status(r):
        online = r["online"] or ""
        if online in NOT_CURRENT and not r["online_visto"] and r["parte"] not in uploaded:
            return "Da caricare su Discogs", False
        return ONLINE_IT.get(online, online), online in NOT_CURRENT

    selling = []
    for r in state.execute("SELECT * FROM righe_csv"):
        status, hidden = sale_status(r)
        f = foto(r["external_id"])
        path = f["foto"] if f else ""
        selling.append({
            "id": r["external_id"], "disco": (f["disco"] if f else "") or "", "release": r["release_id"],
            "grado": r["media"], "copertina": r["sleeve"] or r["media"], "copie": r["quantita"] or 1,
            "prezzo": r["price"], "file": f"inventario_{r['parte']:03d}.csv", "lotto": lot_of(path),
            "foto_nome": display_name(f) if f else "", "foto": images_of(path, thumbs),
            "online": status, "calcolo": r["calcolo"] or "",
            "link": f"https://www.discogs.com/release/{r['release_id']}", "annuncio": "",
            "nascosto": hidden, "_annunci": listing_ids(r),
        })
        # Riga mai vista online e senza più le foto: una prova vecchia, non qualcosa da caricare
        if status == "Da caricare su Discogs" and not selling[-1]["foto"]:
            selling[-1]["nascosto"] = True
    for r in state.execute("SELECT * FROM annunci_api WHERE stato IN ('pubblicato', 'pronto')"):
        f = foto(listing_owner(r["external_id"]))
        path = f["foto"] if f else ""
        ready = r["stato"] == "pronto"
        selling.append({
            "id": r["external_id"], "disco": (f["disco"] if f else "") or "", "release": r["release_id"],
            "grado": r["media"], "copertina": r["sleeve"] or r["media"], "copie": 1, "prezzo": r["price"],
            "file": "API" + (" (bozza)" if (r["status"] or "") == "DRAFT" else ""), "lotto": lot_of(path),
            "foto_nome": display_name(f) if f else "", "foto": images_of(path, thumbs),
            "online": "Da pubblicare" if ready else ONLINE_IT.get(r["online"] or "", r["online"] or ""),
            "pronto": ready, "calcolo": r["calcolo"] or "",
            "link": f"https://www.discogs.com/release/{r['release_id']}",
            "annuncio": f"https://www.discogs.com/sell/item/{r['listing_id']}" if r["listing_id"] else "",
            "nascosto": (not ready) and (r["online"] or "") in NOT_CURRENT,
            "_annunci": listing_ids(r) + ([r["listing_id"]] if r["listing_id"] else []),
        })

    # Confermati a mano ma senza annuncio (il prezzo non è riuscito): restano visibili.
    for f in state.execute(WAITING_SQL):
        pics = images_of(f["foto"], thumbs)
        selling.append({
            "id": f["external_id"], "disco": f["disco"] or "", "release": f["release_id"], "grado": f["media"],
            "copertina": f["sleeve"] or f["media"], "copie": 1, "prezzo": None, "file": "API",
            "lotto": lot_of(f["foto"]), "foto_nome": display_name(f), "foto": pics,
            "online": "Confermato, senza prezzo", "pronto": False, "calcolo": "",
            "link": f"https://www.discogs.com/release/{f['release_id']}", "annuncio": "", "nascosto": not pics,
            "_annunci": [],
        })

    # Annunci in Draft su Discogs: non sono in vendita, vanno guardati e rimessi in vendita a mano.
    # Si spostano nella scheda Da controllare (sempre visibili, anche senza foto).
    drafts = [d for d in selling if d["online"] == ONLINE_IT["bozza"] and not d.get("pronto") and not d["nascosto"]]
    selling = [d for d in selling if d not in drafts]

    checking = []
    for d in drafts:
        checking.append({
            "id": d["id"], "motivo": "In bozza su Discogs: controllalo e rimettilo in vendita",
            "dettaglio": "Non è visibile ai compratori. Se il disco in mano combacia: Edit -> Status: For Sale.",
            "esito": "bozza", "bozza": True, "grado": d["grado"], "copertina": d["copertina"],
            "lotto": d["lotto"], "cartella": "", "foto_nome": d["foto_nome"], "foto": d["foto"],
            "proposto": d["disco"], "release": d["release"], "link": d["link"], "annuncio": d["annuncio"],
            "prezzo": d["prezzo"], "candidati": "", "scelte": [], "copie": "",
        })
    keys = sorted(problems) + ["non_vendibile"]
    for r in state.execute("SELECT * FROM foto WHERE esito IN ({})".format(",".join("?" * len(keys))), keys):
        if r["esito"] == "non_vendibile":
            title, detail = "Bloccato da Discogs: non si può vendere", r["motivo"] or not_sellable_reason
        else:
            title, detail = reasons[r["esito"]], r["motivo"] or ""
        checking.append({
            "id": r["external_id"], "motivo": title[:1].upper() + title[1:], "dettaglio": detail,
            "esito": r["esito"], "grado": r["media"] or "", "copertina": r["sleeve"] or r["media"] or "",
            "lotto": lot_of(r["foto"]), "cartella": lot_folder_of(r["foto"]),
            "foto_nome": display_name(r), "foto": images_of(r["foto"], thumbs),
            "proposto": r["disco"] or "", "release": r["release_id"] or "",
            "link": f"https://www.discogs.com/release/{r['release_id']}" if r["release_id"] else "",
            "prezzo": r["prezzo"], "candidati": r["candidati"] or "",
            "scelte": parse_candidates(r["candidati"], r["release_id"], r["disco"], thumbs, cover_dir),
            "copie": (m.group(1) if (m := re.search(r"--copie-diverse (\S+)", r["motivo"] or "")) else ""),
        })
    for r in state.execute("SELECT a.*, f.foto, f.n_foto, f.disco FROM annunci_api a LEFT JOIN foto f ON "
                           "f.external_id = a.external_id OR a.external_id LIKE f.external_id || '-copia%' "
                           "WHERE a.stato IN ('in_corso', 'rifiutato')"):
        title = ("Pubblicazione non confermata: controlla su Discogs" if r["stato"] == "in_corso"
                 else "Discogs ha rifiutato l'annuncio")
        checking.append({
            "id": r["external_id"], "motivo": title, "dettaglio": r["messaggio"] or "", "esito": r["stato"],
            "grado": r["media"] or "", "copertina": r["sleeve"] or "", "lotto": lot_of(r["foto"]),
            "foto_nome": display_name(r) if r["foto"] else "", "foto": images_of(r["foto"], thumbs),
            "proposto": r["disco"] or "", "release": r["release_id"],
            "link": f"https://www.discogs.com/release/{r['release_id']}", "prezzo": r["price"], "candidati": "",
        })
    # Immagine principale della scheda: la copertina ufficiale Discogs (più ordinata delle foto fatte a
    # mano), se è già in cache; le foto del disco restano nelle miniature accanto.
    # Dischi per cui il venditore preferisce la sua foto (copertina Discogs brutta): tasto "La mia foto".
    try:
        own = {r[0] for r in state.execute("SELECT external_id FROM foto_mia")}
    except sqlite3.OperationalError:
        own = set()
    for d in selling + checking:
        cover = Path(cover_dir) / f"{d['release']}-0.jpg" if cover_dir and thumbs and d.get("release") else None
        d["discogs"] = (thumbnail(cover, thumbs) or "") if cover and cover.exists() else ""
        d["foto_mia"] = d["id"] in own and bool(d["foto"])
        d["scelta_foto"] = bool(d["discogs"] and d["foto"])   # c'è da scegliere: Discogs o la mia
        if d["foto_mia"]:
            d["discogs"] = ""
    for d in checking:   # foto non più nella loro cartella (prove vecchie, foto spostate): nascosti
        d["nascosto"] = not d["foto"] and not d.get("bozza")
    natural = lambda d: (d["lotto"], d["foto_nome"] or d["id"])  # noqa: E731
    # In vendita: lo stesso ordine della pagina Discogs (dal più recente, salvato da verifica_inventario.py);
    # i dischi che lì non compaiono ancora (appena pubblicati, da pubblicare) vanno in cima: sono i più recenti.
    order = discogs_order(out_dir)
    if order:
        selling.sort(key=lambda d: (min((order.get(i, -1) for i in d["_annunci"]), default=-1), natural(d)))
    else:
        selling.sort(key=natural)
    for d in selling:
        d.pop("_annunci", None)
    checking.sort(key=natural)
    return {"vendita": selling, "controllo": checking}


def render(data, generated, live=False):
    payload = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
    return (PAGE.replace("__DATA__", payload).replace("__WHEN__", html.escape(generated))
            .replace("__LIVE__", "true" if live else "false"))


def write_panel(out_dir, data, generated):
    path = Path(out_dir) / "pannello.html"
    path.write_text(render(data, generated), encoding="utf-8")
    return path


PAGE = r"""<!doctype html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Inventario dischi</title>
<style>
:root{
  --bg:#f3f2ec; --panel:#ffffff; --ink:#15170f; --muted:#5d6152; --line:#d9d8cc;
  --green:#4b5320; --green-ink:#ffffff; --warn:#a4471c; --warn-bg:#fbeee6; --ok:#2f6b2f; --chip:#ebeadf;
  --mono:ui-monospace,"SF Mono",Menlo,monospace;
}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){
  --bg:#111209; --panel:#1b1d13; --ink:#ecebdf; --muted:#a3a693; --line:#30331f;
  --green:#8a9a4a; --green-ink:#111209; --warn:#e58a5c; --warn-bg:#2c1c13; --ok:#8ac08a; --chip:#262916;
}}
*{box-sizing:border-box}
[hidden]{display:none !important}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif}
header{padding:28px 24px 12px;border-bottom:3px solid var(--ink)}
h1{margin:0;font-size:44px;line-height:1;letter-spacing:-.02em;text-transform:uppercase;font-weight:900}
.sub{margin-top:8px;color:var(--muted);font-family:var(--mono);font-size:12px}
.stats{display:flex;flex-wrap:wrap;gap:0;margin-top:18px;border:2px solid var(--ink)}
.stat{flex:1 1 140px;padding:10px 14px;border-right:2px solid var(--ink)}
.stat:last-child{border-right:0}
.stat b{display:block;font-size:26px;font-variant-numeric:tabular-nums}
.stat span{font-family:var(--mono);font-size:11px;text-transform:uppercase;color:var(--muted)}
nav{position:sticky;top:0;z-index:2;background:var(--bg);display:flex;flex-wrap:wrap;gap:10px;align-items:center;
  padding:12px 24px;border-bottom:1px solid var(--line)}
.tab{border:2px solid var(--ink);background:transparent;color:var(--ink);padding:8px 14px;font-weight:800;
  text-transform:uppercase;letter-spacing:.03em;cursor:pointer;font-size:13px}
.tab[aria-selected="true"]{background:var(--ink);color:var(--bg)}
.tab .n{font-family:var(--mono);margin-left:6px;font-weight:400}
input,select{font:inherit;padding:8px 10px;border:2px solid var(--ink);background:var(--panel);color:var(--ink)}
input{flex:1 1 220px;min-width:0}
main{padding:20px 24px 60px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:16px}
.card{background:var(--panel);border:1px solid var(--line);display:flex;flex-direction:column}
.pics{display:grid;grid-template-columns:1fr;aspect-ratio:1;background:var(--chip);position:relative;overflow:hidden}
.pics .swap{position:absolute;top:8px;right:8px;opacity:.85}
.pics img{width:100%;height:100%;object-fit:cover;display:block;cursor:zoom-in}
.pics .thumbs{position:absolute;right:6px;bottom:6px;display:flex;gap:4px}
.pics .thumbs img{width:44px;height:44px;border:2px solid var(--panel)}
.nopic{display:flex;align-items:center;justify-content:center;color:var(--muted);font-family:var(--mono);font-size:12px;padding:12px;text-align:center}
.body{padding:12px 14px;display:flex;flex-direction:column;gap:6px;flex:1}
.title{font-weight:800;line-height:1.25}
.meta{font-family:var(--mono);font-size:11.5px;color:var(--muted)}
.row{display:flex;justify-content:space-between;align-items:baseline;gap:8px}
.price{font-size:22px;font-weight:900;font-variant-numeric:tabular-nums}
.chips{display:flex;flex-wrap:wrap;gap:4px}
.chip{background:var(--chip);padding:2px 7px;font-family:var(--mono);font-size:11px}
.chip.g{background:var(--green);color:var(--green-ink)}
.chip.on{color:var(--ok);font-weight:700}
.chip.ready{background:var(--warn);color:#fff;font-weight:700}
.reason{background:var(--warn-bg);color:var(--warn);font-weight:800;padding:6px 8px;font-size:13px}
.detail{font-size:12.5px;color:var(--muted)}
details summary{cursor:pointer;font-family:var(--mono);font-size:11px;color:var(--muted)}
details p{font-family:var(--mono);font-size:11px;white-space:pre-wrap;margin:6px 0 0}
a{color:var(--green);font-weight:700}
.links{display:flex;gap:12px;margin-top:auto;padding-top:4px;font-size:13px}
.empty{padding:40px;text-align:center;color:var(--muted);border:2px dashed var(--line)}
.actions{display:flex;flex-wrap:wrap;gap:10px;align-items:center;padding:10px 24px;border-bottom:1px solid var(--line);background:var(--panel)}
.act{border:2px solid var(--ink);background:var(--ink);color:var(--bg);padding:7px 12px;font-weight:800;cursor:pointer;font-size:13px}
.act.ghost{background:transparent;color:var(--ink)}
.act.small{padding:4px 8px;font-size:12px}
.act.ok{font-weight:700}
.act.warn{border-color:var(--warn);color:var(--warn);background:transparent}
.act:disabled{opacity:.5;cursor:wait}
.hint{font-family:var(--mono);font-size:11px;color:var(--muted)}
#log{margin:0;padding:12px 24px;background:#111;color:#ddd;font:12px/1.4 var(--mono);max-height:40vh;overflow:auto;white-space:pre-wrap}
.choices{display:flex;flex-direction:column;gap:4px}
.choice{display:flex;gap:8px;align-items:center;font-size:12.5px}
.choice .t{flex:1}
.choice .cov{width:44px;height:44px;object-fit:cover;background:var(--chip);flex:none;cursor:zoom-in}
.cardbtns{display:flex;gap:6px;flex-wrap:wrap;margin-top:4px}
#zoom{position:fixed;inset:0;background:rgba(0,0,0,.88);display:none;align-items:center;justify-content:center;z-index:9;cursor:zoom-out}
#zoom img{max-width:94vw;max-height:94vh}
@media (max-width:600px){header,nav,main{padding-left:16px;padding-right:16px}h1{font-size:32px}}
</style>
</head>
<body>
<header>
  <h1>Inventario dischi</h1>
  <div class="sub">Aggiornato al __WHEN__ · generato da vendi.py · clic su una foto per ingrandirla</div>
  <div class="stats" id="stats"></div>
  <div class="sub" id="hidden"></div>
</header>
<nav>
  <button class="tab" data-tab="vendita" aria-selected="true">In vendita<span class="n" id="n-vendita"></span></button>
  <button class="tab" data-tab="controllo" aria-selected="false">Da controllare<span class="n" id="n-controllo"></span></button>
  <input id="q" type="search" placeholder="Cerca: titolo, artista, lotto, cartella, file…" autocomplete="off">
  <select id="lot"><option value="">Tutti i lotti</option></select>
  <select id="view"><option value="attuali">Solo attuali</option><option value="tutti">Mostra anche i nascosti</option></select>
</nav>
<div id="actions" class="actions" hidden>
  <button class="act" data-job="pubblica" id="btn-pubblica">Pubblica su Discogs</button>
  <button class="act ghost" data-job="verifica">Verifica su Discogs</button>
  <button class="act ghost" id="btn-elabora">Elabora un lotto…</button>
  <span class="hint" id="live-hint">Pannello collegato allo script: i pulsanti agiscono davvero.</span>
</div>
<div id="offline" class="actions" hidden><span class="hint">Pagina statica. Per i pulsanti (scegli, togli, pubblica): nel Terminale <code>python pannello.py</code></span></div>
<pre id="log" hidden></pre>
<main><div class="grid" id="grid"></div></main>
<div id="zoom"><img alt=""></div>
<script>
const DATA = __DATA__;
const LIVE = __LIVE__;
const NO_CONFIRM = ["non_vendibile", "in_corso", "rifiutato", "stesso_disco"];
const euro = v => v == null || v === "" ? "" : Number(v).toLocaleString("it-IT",{style:"currency",currency:"EUR"});
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
let tab = "vendita";
try { tab = localStorage.getItem("tab") || "vendita"; } catch (e) {}

const lots = [...new Set([...DATA.vendita, ...DATA.controllo].map(d => d.lotto).filter(Boolean))].sort();
document.getElementById("lot").innerHTML += lots.map(l => `<option>${esc(l)}</option>`).join("");
function visible(list) {
  const all = document.getElementById("view").value === "tutti";
  return list.filter(d => all || !d.nascosto);
}
function stats() {
  const sale = visible(DATA.vendita), check = visible(DATA.controllo);
  const copies = sale.reduce((s, d) => s + (d.copie || 1), 0);
  const value = sale.reduce((s, d) => s + (d.prezzo || 0) * (d.copie || 1), 0);
  const hidden = DATA.vendita.length + DATA.controllo.length - sale.length - check.length;
  const ready = sale.filter(d => d.pronto).length;
  document.getElementById("stats").innerHTML = [
    [sale.length, "righe in vendita"], [copies, "copie"], [euro(value), "valore di listino"],
    [ready, "da pubblicare"], [check.length, "da controllare"]].map(([b, s]) => `<div class="stat"><b>${b}</b><span>${s}</span></div>`).join("");
  document.getElementById("n-vendita").textContent = sale.length;
  document.getElementById("n-controllo").textContent = check.length;
  document.getElementById("hidden").textContent = hidden && document.getElementById("view").value !== "tutti"
    ? `${hidden} nascosti: righe non più online su Discogs e dischi da controllare con le foto non più nella loro cartella` : "";
}
function pics(d) {
  if (!d.foto.length && !d.discogs) return `<div class="pics nopic">foto non trovata<br>${esc(d.foto_nome)}</div>`;
  // La copertina Discogs davanti (se c'è), le foto del disco nelle miniature
  // Con la copertina Discogs si vede solo quella, pulita (niente miniature delle foto fatte a mano)
  const [first, ...rest] = d.discogs ? [d.discogs] : d.foto;
  const swap = LIVE && (d.scelta_foto || d.foto_mia)
    ? `<button class="act small swap" data-act="foto-mia" data-id="${esc(d.id)}">${d.foto_mia ? "Foto Discogs" : "La mia foto"}</button>` : "";
  return `<div class="pics"><img src="${esc(first)}" alt="" loading="lazy">${swap}
    <div class="thumbs">${d.discogs ? "" : rest.map(u => `<img src="${esc(u)}" alt="" loading="lazy">`).join("")}</div></div>`;
}
function grade(d) {
  return d.copertina && d.copertina !== d.grado ? `Disco ${esc(d.grado)} · Copertina ${esc(d.copertina)}` : `Grado ${esc(d.grado)}`;
}
function cardSale(d) {
  return `<article class="card">${pics(d)}<div class="body">
    <div class="title">${esc(d.disco) || "Release " + esc(d.release)}</div>
    <div class="row"><span class="price">${euro(d.prezzo)}</span>${d.copie > 1 ? `<span class="chip g">${d.copie} copie</span>` : ""}</div>
    <div class="chips"><span class="chip g">${grade(d)}</span><span class="chip">${esc(d.file)}</span>
      ${d.lotto ? `<span class="chip">${esc(d.lotto)}</span>` : ""}
      <span class="chip ${d.online === "Online" ? "on" : d.pronto ? "ready" : ""}">${esc(d.online || "online non verificato")}</span></div>
    <div class="meta">${esc(d.foto_nome)} · ${esc(d.id)}</div>
    ${d.calcolo ? `<details><summary>come è stato calcolato il prezzo</summary><p>${esc(d.calcolo)}</p></details>` : ""}
    <div class="links"><a href="${esc(d.link)}" target="_blank" rel="noopener">Release su Discogs</a>
      ${d.annuncio ? `<a href="${esc(d.annuncio)}" target="_blank" rel="noopener">Annuncio</a>` : ""}</div>
    ${LIVE && d.pronto ? `<div class="cardbtns"><button class="act small warn" data-act="togli" data-id="${esc(d.id)}">Togli (non pubblicare)</button></div>` : ""}
  </div></article>`;
}
function cardCheck(d) {
  return `<article class="card">${pics(d)}<div class="body">
    <div class="reason">${esc(d.motivo)}</div>
    ${d.dettaglio ? `<div class="detail">${esc(d.dettaglio)}</div>` : ""}
    ${d.bozza ? `<div class="title">${esc(d.proposto)}</div>` : d.proposto ? `<div class="title">Proposto: ${esc(d.proposto)}</div>` : `<div class="title">Nessun disco proposto</div>`}
    <div class="chips"><span class="chip g">${grade(d)}</span>${d.lotto ? `<span class="chip">${esc(d.lotto)}</span>` : ""}
      ${d.prezzo ? `<span class="chip">${euro(d.prezzo)}</span>` : ""}</div>
    <div class="meta">${esc(d.foto_nome)} · ${esc(d.id)}</div>
    ${LIVE && d.scelte.length ? `<div class="choices">${d.scelte.map(c => `<div class="choice">${c.foto ? `<img class="cov" src="${esc(c.foto)}" alt="">` : `<span class="cov"></span>`}<span class="t">${esc(c.testo)}</span>
        <a href="https://www.discogs.com/release/${c.id}" target="_blank" rel="noopener">vedi</a>
        <button class="act small" data-act="abbina" data-id="${esc(d.id)}" data-release="${c.id}">È questo</button></div>`).join("")}</div>`
      : d.candidati ? `<details><summary>altre release possibili</summary><p>${esc(d.candidati)}</p></details>` : ""}
    ${d.bozza ? `<div class="links">${d.annuncio ? `<a href="${esc(d.annuncio)}" target="_blank" rel="noopener">Apri l'annuncio</a>` : `<a href="https://www.discogs.com/sell/manage" target="_blank" rel="noopener">Apri l'inventario</a>`}</div>` : ""}
    ${LIVE && d.bozza ? `<div class="cardbtns"><button class="act small ok" data-act="bozza-vendita" data-id="${esc(d.id)}">Conferma</button></div>` : ""}
    ${LIVE && !d.bozza ? `<div class="cardbtns">
      ${d.release && !NO_CONFIRM.includes(d.esito) ? `<button class="act small ok" data-act="conferma" data-id="${esc(d.id)}" data-release="${esc(d.release)}">Conferma</button>` : ""}
      <button class="act small ghost" data-act="abbina-id" data-id="${esc(d.id)}">Altra release…</button>
      ${d.copie ? `<button class="act small ghost" data-act="copie" data-id="${esc(d.id)}" data-copie="${esc(d.copie)}" data-cartella="${esc(d.cartella)}">Sono copie diverse</button>` : ""}
      <button class="act small warn" data-act="togli" data-id="${esc(d.id)}">Togli</button></div>` : ""}
    <div class="links">${d.link ? `<a href="${esc(d.link)}" target="_blank" rel="noopener">Confronta su Discogs</a>` : ""}
      <a href="https://www.discogs.com/search/?type=release&format=Vinyl&q=${encodeURIComponent(d.proposto || "")}" target="_blank" rel="noopener">Cerca</a></div>
  </div></article>`;
}
function draw() {
  document.querySelectorAll(".tab").forEach(b => b.setAttribute("aria-selected", b.dataset.tab === tab));
  const q = document.getElementById("q").value.trim().toLowerCase();
  const lot = document.getElementById("lot").value;
  stats();
  const list = visible(DATA[tab]).filter(d => (!lot || d.lotto === lot) &&
    (!q || JSON.stringify([d.disco, d.proposto, d.lotto, d.foto_nome, d.file, d.id, d.release, d.motivo]).toLowerCase().includes(q)));
  document.getElementById("grid").innerHTML = list.length ? list.map(tab === "vendita" ? cardSale : cardCheck).join("")
    : `<div class="empty">${tab === "vendita" ? "Nessun disco in vendita" : "Niente da controllare"}${q || lot ? " con questo filtro" : ""}</div>`;
}
document.querySelectorAll(".tab").forEach(b => b.onclick = () => {
  tab = b.dataset.tab; try { localStorage.setItem("tab", tab); } catch (e) {} draw(); });
document.getElementById("q").oninput = draw;
document.getElementById("lot").onchange = draw;
document.getElementById("view").onchange = draw;
const zoom = document.getElementById("zoom");
document.getElementById("grid").addEventListener("click", e => {
  if (e.target.tagName === "IMG") { zoom.querySelector("img").src = e.target.src; zoom.style.display = "flex"; } });
zoom.onclick = () => zoom.style.display = "none";
document.addEventListener("keydown", e => { if (e.key === "Escape") zoom.style.display = "none"; });
draw();

// ----- Pannello collegato allo script (python pannello.py): azioni vere -----
document.getElementById(LIVE ? "actions" : "offline").hidden = false;
// Pagina statica aperta dal file: se il pannello collegato è acceso, si passa a quello (con i pulsanti)
if (!LIVE) fetch("http://127.0.0.1:8765/api/log", {mode: "no-cors"}).then(() => { location.href = "http://127.0.0.1:8765/"; }).catch(() => {});
async function call(body) {
  const r = await fetch("/api/azione", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(body)});
  return r.json();
}
function setBusy(b) { document.querySelectorAll(".act").forEach(x => x.disabled = b); }
async function runJob(body) {
  const log = document.getElementById("log");
  log.hidden = false; log.textContent = "Avvio…\n"; setBusy(true);
  const start = await call(body);
  if (!start.ok) { log.textContent += start.messaggio + "\n"; setBusy(false); return; }
  for (;;) {
    await new Promise(r => setTimeout(r, 1000));
    const st = await (await fetch("/api/log")).json();
    log.textContent = st.log; log.scrollTop = log.scrollHeight;
    if (!st.attivo) break;
  }
  setBusy(false);
  log.textContent += "\n— Fatto. Ricarico il pannello. —";
  setTimeout(() => location.reload(), 1200);
}
document.querySelectorAll("[data-job]").forEach(b => b.onclick = () => {
  if (b.dataset.job === "pubblica" && !confirm("Pubblicare ORA su Discogs tutti gli annunci pronti?")) return;
  runJob({azione: b.dataset.job});
});
document.getElementById("btn-elabora").onclick = () => {
  const cartella = prompt("Cartella del lotto (es. /Users/a1/Desktop/lotto-07):", localStorage.getItem("cartella") || "");
  if (!cartella) return;
  const grado = prompt("Grado dei dischi (M, NM, VG+, oppure M_NM per disco M e copertina NM).\nServe solo se nella cartella ci sono foto sciolte da raggruppare 2 a 2:", localStorage.getItem("grado") || "M");
  try { localStorage.setItem("cartella", cartella); if (grado) localStorage.setItem("grado", grado); } catch (e) {}
  runJob({azione: "elabora", cartella, grado: grado || ""});
};
document.getElementById("grid").addEventListener("click", async e => {
  const b = e.target.closest("[data-act]"); if (!b) return;
  const id = b.dataset.id; let body = null;
  if (b.dataset.act === "abbina") body = {azione: "abbina", disco: id, release: Number(b.dataset.release)};
  if (b.dataset.act === "abbina-id") {
    const v = prompt("Numero della release Discogs giusta (dall'indirizzo discogs.com/release/NUMERO):");
    if (!v || !/^\d+$/.test(v.trim())) return; body = {azione: "abbina", disco: id, release: Number(v.trim())};
  }
  if (b.dataset.act === "conferma") { runJob({azione: "conferma", disco: id, release: Number(b.dataset.release)}); return; }
  if (b.dataset.act === "bozza-vendita") body = {azione: "bozza_vendita", disco: id};
  if (b.dataset.act === "foto-mia") body = {azione: "foto_mia", disco: id};
  if (b.dataset.act === "togli") { if (!confirm(`Togliere ${id} dall'inventario?`)) return; body = {azione: "togli", disco: id}; }
  if (b.dataset.act === "copie") { runJob({azione: "elabora", cartella: b.dataset.cartella, grado: "", copie: b.dataset.copie}); return; }
  if (!body) return;
  setBusy(true);
  const r = await call(body);
  if (!r.ok) { alert(r.messaggio); setBusy(false); return; }
  location.reload();
});
</script>
</body>
</html>
"""


# --------------------------------------------------------------------------
# Pannello collegato allo script: python pannello.py
# --------------------------------------------------------------------------

PORT = 8765


class Job:
    """Un comando dello script lanciato dal pannello (vendi.py --pubblica, verifica_inventario.py, ...):
    uno alla volta, con l'output raccolto per la pagina."""

    def __init__(self):
        self.proc, self.log, self.thread = None, "", None

    @property
    def active(self):
        return self.proc is not None and self.proc.poll() is None

    def start(self, argv, cwd):
        import subprocess
        import threading
        if self.active:
            return False
        self.log = "$ " + " ".join(argv) + "\n"
        self.proc = subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                     bufsize=1, env={**os.environ, "PYTHONUNBUFFERED": "1"})

        def pump():
            for line in self.proc.stdout:
                self.log += line
            self.proc.wait()
            self.log += f"\n[finito, codice {self.proc.returncode}]\n"

        self.thread = threading.Thread(target=pump, daemon=True)
        self.thread.start()
        return True


def dd_base():
    import discogs_dump as dd
    return dd.BASE_DIR


def draft_to_sale(vendi, con, eid):
    """Un annuncio in Draft (bozza) controllato a mano torna In vendita su Discogs. Rilegge per verificare."""
    api = vendi.DiscogsAPI(vendi.load_token())
    ids = [r[0] for r in con.execute("SELECT listing_id FROM annunci_api WHERE external_id = ? AND listing_id",
                                     (eid,))]
    if not ids:   # annuncio caricato con il CSV: si cerca tra le bozze per external_id
        inv = vendi.fetch_inventory(api, api.identity()["username"], statuses=("Draft",))
        ids = [i["id"] for i in inv.by_listing.values()
               if (i.get("external_id") or "") == eid or (i.get("external_id") or "").startswith(eid + "-")]
    if not ids:
        raise SystemExit(f"Non trovo l'annuncio di {eid} tra le bozze su Discogs (forse già in vendita: "
                         "premi Verifica su Discogs).")
    done = []
    for lid in ids:
        full = api.get_listing(lid)
        if vendi.listing_fields(full).get("status") != "For Sale":
            api.edit_listing_fields(lid, vendi.listing_edit_body(full, status="For Sale"))
        after = vendi.listing_fields(api.get_listing(lid)).get("status")
        if after != "For Sale":
            raise SystemExit(f"Discogs non l'ha messo in vendita (stato: {after}): fallo dal sito.")
        con.execute("UPDATE annunci_api SET online = 'in_vendita', online_ultimo = 'in_vendita', status = 'FOR_SALE'"
                    " WHERE listing_id = ?", (lid,))
        done.append(str(lid))
    con.execute("UPDATE righe_csv SET online = 'in_vendita', online_ultimo = 'in_vendita' WHERE external_id = ?",
                (eid,))
    con.commit()
    return f"In vendita: {eid} (annuncio {', '.join(done)})"


def make_handler(vendi, out_dir, job):
    import http.server
    import sqlite3

    def state():
        con = sqlite3.connect(vendi.STATE_DB)
        con.row_factory = sqlite3.Row
        return con

    def fresh_page():
        con = state()
        try:
            data = collect(con, vendi.REASONS, vendi.PROBLEMS, vendi.display_name, vendi.listing_owner,
                           vendi.NOT_SELLABLE_REASON, out_dir)
        finally:
            con.close()
        import datetime as dt
        return render(data, dt.datetime.now().strftime("%d/%m/%Y %H:%M"), live=True)

    def script(name, *args):
        return [sys.executable, str(dd_base() / name), *args]

    def action(body):
        """Azioni immediate (nello stato) o comandi dello script (job in sottoprocesso)."""
        what = body.get("azione")
        if what in ("pubblica", "verifica", "elabora", "conferma"):
            if what == "conferma":
                argv = script("conferma_disco.py", str(body.get("disco", "")), str(int(body.get("release") or 0)))
            elif what == "pubblica":
                argv = script("vendi.py", "--pubblica", "--senza-pannello")
            elif what == "verifica":
                argv = script("verifica_inventario.py")
            else:
                folder = (body.get("cartella") or "").strip()
                if not folder or not Path(folder).expanduser().is_dir():
                    return {"ok": False, "messaggio": f"Cartella non trovata: {folder}"}
                argv = script("vendi.py", str(Path(folder).expanduser()), "--senza-pannello", "--si")
                if body.get("grado"):
                    argv += ["--grado", body["grado"]]
                if body.get("copie"):
                    argv += ["--copie-diverse", body["copie"]]
            if not job.start(argv, str(dd_base())):
                return {"ok": False, "messaggio": "C'è già un comando in corso: aspetta che finisca."}
            return {"ok": True}
        if job.active:
            return {"ok": False, "messaggio": "C'è un comando in corso: aspetta che finisca."}
        con = vendi.open_state(vendi.STATE_DB)
        try:
            if what == "togli":
                targets, rows, rest = vendi.remove_discs(con, out_dir, [body.get("disco", "")])
                msg = f"Tolto: {', '.join(targets)}" + (f"; tornano da elaborare: {', '.join(rest)}" if rest else "")
            elif what == "abbina":
                import discogs_dump as dd
                db = dd.open_db(dd.DEFAULT_DB)
                try:
                    done = vendi.assign_releases(con, db, vendi.DiscogsAPI(vendi.load_token()),
                                                 f"{body.get('disco', '')}={body.get('release', '')}")
                finally:
                    db.close()
                msg = "; ".join(f"{eid} -> {vendi.describe_release(r)}" for eid, r in done)
            elif what == "foto_mia":
                eid = body.get("disco", "")
                con.execute("CREATE TABLE IF NOT EXISTS foto_mia (external_id TEXT PRIMARY KEY)")
                if con.execute("SELECT 1 FROM foto_mia WHERE external_id = ?", (eid,)).fetchone():
                    con.execute("DELETE FROM foto_mia WHERE external_id = ?", (eid,))
                    msg = f"{eid}: torna la copertina Discogs"
                else:
                    con.execute("INSERT INTO foto_mia VALUES (?)", (eid,))
                    msg = f"{eid}: si vede la sua foto"
                con.commit()
            elif what == "bozza_vendita":
                msg = draft_to_sale(vendi, con, body.get("disco", ""))
            else:
                return {"ok": False, "messaggio": f"Azione sconosciuta: {what}"}
            vendi.write_outputs(con, out_dir, [], [])
        except SystemExit as e:
            return {"ok": False, "messaggio": str(e)}
        finally:
            con.close()
        return {"ok": True, "messaggio": msg}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, code, ctype, body):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path in ("/", "/index.html", "/pannello.html"):
                return self.send(200, "text/html; charset=utf-8", fresh_page().encode("utf-8"))
            if path == "/api/log":
                return self.send(200, "application/json", json.dumps({"attivo": job.active, "log": job.log}).encode())
            if path.startswith("/miniature/") and "/.." not in path:
                f = Path(out_dir) / "miniature" / Path(path).name
                if f.is_file():
                    return self.send(200, "image/jpeg", f.read_bytes())
            self.send(404, "text/plain", b"non trovato")

        def do_POST(self):
            if self.path != "/api/azione":
                return self.send(404, "text/plain", b"non trovato")
            n = int(self.headers.get("Content-Length") or 0)
            try:
                body = json.loads(self.rfile.read(n) or b"{}")
                result = action(body)
            except Exception as e:  # mai lasciare la pagina senza risposta
                result = {"ok": False, "messaggio": f"Errore: {e}"}
            self.send(200, "application/json", json.dumps(result, ensure_ascii=False).encode("utf-8"))

    return Handler


def download_missing_covers(vendi, state, out_dir):
    """Scarica da Discogs la copertina principale dei dischi del pannello che non ce l'hanno ancora
    (una volta sola: poi resta in data/copertine). Restituisce quante ne ha scaricate."""
    data = collect(state, vendi.REASONS, vendi.PROBLEMS, vendi.display_name, vendi.listing_owner,
                   vendi.NOT_SELLABLE_REASON, out_dir)
    cover_dir = Path(vendi.COVER_DIR)
    missing = sorted({int(d["release"]) for d in data["vendita"] + data["controllo"]
                      if d.get("release") and not d.get("discogs") and not d.get("nascosto")
                      and not (cover_dir / f"{d['release']}-0.jpg").exists()})
    if not missing:
        return 0
    print(f"Scarico le copertine Discogs mancanti: {len(missing)} (circa {2 * len(missing)} secondi, una volta sola)")
    api = vendi.DiscogsAPI(vendi.load_token())
    cover_dir.mkdir(parents=True, exist_ok=True)
    done = 0
    for n, rid in enumerate(missing, 1):
        try:
            images = api.release(rid).get("images") or []
            images.sort(key=lambda i: 0 if i.get("type") == "primary" else 1)
            url = images and (images[0].get("uri") or images[0].get("uri150"))
            if url:
                blob = api.download(url)
                if blob:
                    (cover_dir / f"{rid}-0.jpg").write_bytes(blob)
                    done += 1
        except Exception as e:  # una copertina che manca non deve fermare il pannello
            print(f"  release {rid}: copertina non scaricata ({e})")
        if n % 10 == 0:
            print(f"  {n}/{len(missing)}")
    return done


def serve(port=PORT, open_browser=True):
    import http.server
    import vendi
    out_dir = vendi.OUT_DIR
    out_dir.mkdir(parents=True, exist_ok=True)
    handler = make_handler(vendi, out_dir, Job())
    server = http.server.HTTPServer(("127.0.0.1", port), handler)
    url = f"http://127.0.0.1:{port}/"
    print(f"Pannello su {url}  (Ctrl+C per chiudere)")
    if open_browser and sys.platform == "darwin":
        import subprocess
        subprocess.run(["open", url], check=False)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nPannello chiuso.")
    finally:
        server.server_close()


def main():
    import argparse
    import datetime as dt
    import sqlite3
    import vendi
    parser = argparse.ArgumentParser(description="Pannello dell'inventario: pagina con le foto e i pulsanti")
    parser.add_argument("--solo-file", action="store_true",
                        help="rigenera solo risultati/pannello.html (pagina statica, senza pulsanti) e esce")
    parser.add_argument("--porta", type=int, default=PORT)
    parser.add_argument("--senza-browser", action="store_true", help="non aprire il browser")
    args = parser.parse_args()
    out_dir = vendi.OUT_DIR
    state = sqlite3.connect(vendi.STATE_DB)
    state.row_factory = sqlite3.Row
    try:
        try:
            download_missing_covers(vendi, state, out_dir)
        except Exception as e:  # senza rete o senza token il pannello si apre lo stesso
            print(f"Copertine Discogs non scaricate ({e}): restano le sue foto")
        path = vendi.write_panel_from_state(state, out_dir)
    finally:
        state.close()
    print(f"Pannello aggiornato: {path}  ({dt.datetime.now():%H:%M})")
    if THUMB_ERRORS:
        print(f"Attenzione: {len(THUMB_ERRORS)} foto senza miniatura (nel pannello compare il punto di domanda). "
              "Prima:\n  " + "\n  ".join(f"{f}: {e}" for f, e in THUMB_ERRORS[:3]))
    if not args.solo_file:
        serve(args.porta, not args.senza_browser)


if __name__ == "__main__":
    main()
