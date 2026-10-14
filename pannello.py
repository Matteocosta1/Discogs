"""
Pannello visivo dell'inventario: risultati/pannello.html.

Lo genera vendi.py a ogni lancio (insieme agli altri file dei risultati), dallo stato salvato:
- IN VENDITA: ogni disco con foto, nome, grado, prezzo, copie, file CSV di provenienza, stato online;
- DA CONTROLLARE: ogni disco fermo con foto, motivo in chiaro e disco proposto da confrontare.

È una pagina sola, tutta sul Mac: le foto sono lette dalle cartelle dei lotti (file://), niente
va online. Si apre con un doppio clic; le foto HEIC dell'iPhone si vedono in Safari.

Si può anche rigenerare da solo, senza elaborare niente:  python pannello.py
"""

import html
import json
from pathlib import Path

IMAGE_EXTS = {".jpg", ".jpeg", ".heic", ".heif", ".png"}

ONLINE_IT = {
    "in_vendita": "Online", "bozza": "Bozza su Discogs", "venduto": "Venduto", "forse_venduto": "Forse venduto",
    "scaduto": "Scaduto", "assente": "Non trovato online", "sparito": "Sparito", "rimosso": "Rimosso",
    "bozza_cancellata": "Bozza cancellata", "bloccato": "Bloccato da Discogs",
}


def images_of(path_text):
    """Foto di un disco: la foto stessa, o le foto della sua sottocartella (fronte prima, per nome)."""
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
    return [f.as_uri() for f in files[:4]]


def lot_of(path_text):
    return Path(path_text).parent.parent.name if path_text else ""


def collect(state, reasons, problems, display_name, listing_owner, not_sellable_reason):
    """Dati del pannello dallo stato di vendi.py."""
    def foto(eid):
        return state.execute("SELECT * FROM foto WHERE external_id = ?", (eid,)).fetchone()

    selling = []
    for r in state.execute("SELECT * FROM righe_csv"):
        f = foto(r["external_id"])
        path = f["foto"] if f else ""
        selling.append({
            "id": r["external_id"], "disco": (f["disco"] if f else "") or "", "release": r["release_id"],
            "grado": r["media"], "copertina": r["sleeve"] or r["media"], "copie": r["quantita"] or 1,
            "prezzo": r["price"], "file": f"inventario_{r['parte']:03d}.csv", "lotto": lot_of(path),
            "foto_nome": display_name(f) if f else "", "foto": images_of(path),
            "online": ONLINE_IT.get(r["online"] or "", r["online"] or ""), "calcolo": r["calcolo"] or "",
            "link": f"https://www.discogs.com/release/{r['release_id']}", "annuncio": "",
        })
    for r in state.execute("SELECT * FROM annunci_api WHERE stato = 'pubblicato'"):
        f = foto(listing_owner(r["external_id"]))
        path = f["foto"] if f else ""
        selling.append({
            "id": r["external_id"], "disco": (f["disco"] if f else "") or "", "release": r["release_id"],
            "grado": r["media"], "copertina": r["sleeve"] or r["media"], "copie": 1, "prezzo": r["price"],
            "file": "API" + (" (bozza)" if (r["status"] or "") == "DRAFT" else ""), "lotto": lot_of(path),
            "foto_nome": display_name(f) if f else "", "foto": images_of(path),
            "online": ONLINE_IT.get(r["online"] or "", r["online"] or ""), "calcolo": r["calcolo"] or "",
            "link": f"https://www.discogs.com/release/{r['release_id']}",
            "annuncio": f"https://www.discogs.com/sell/item/{r['listing_id']}" if r["listing_id"] else "",
        })

    checking = []
    keys = sorted(problems) + ["non_vendibile"]
    for r in state.execute("SELECT * FROM foto WHERE esito IN ({})".format(",".join("?" * len(keys))), keys):
        if r["esito"] == "non_vendibile":
            title, detail = "Bloccato da Discogs: non si può vendere", r["motivo"] or not_sellable_reason
        else:
            title, detail = reasons[r["esito"]], r["motivo"] or ""
        checking.append({
            "id": r["external_id"], "motivo": title[:1].upper() + title[1:], "dettaglio": detail,
            "esito": r["esito"], "grado": r["media"] or "", "copertina": r["sleeve"] or r["media"] or "",
            "lotto": lot_of(r["foto"]), "foto_nome": display_name(r), "foto": images_of(r["foto"]),
            "proposto": r["disco"] or "", "release": r["release_id"] or "",
            "link": f"https://www.discogs.com/release/{r['release_id']}" if r["release_id"] else "",
            "prezzo": r["prezzo"], "candidati": r["candidati"] or "",
        })
    for r in state.execute("SELECT a.*, f.foto, f.n_foto, f.disco FROM annunci_api a LEFT JOIN foto f ON "
                           "f.external_id = a.external_id OR a.external_id LIKE f.external_id || '-copia%' "
                           "WHERE a.stato IN ('in_corso', 'rifiutato')"):
        title = ("Pubblicazione non confermata: controlla su Discogs" if r["stato"] == "in_corso"
                 else "Discogs ha rifiutato l'annuncio")
        checking.append({
            "id": r["external_id"], "motivo": title, "dettaglio": r["messaggio"] or "", "esito": r["stato"],
            "grado": r["media"] or "", "copertina": r["sleeve"] or "", "lotto": lot_of(r["foto"]),
            "foto_nome": display_name(r) if r["foto"] else "", "foto": images_of(r["foto"]),
            "proposto": r["disco"] or "", "release": r["release_id"],
            "link": f"https://www.discogs.com/release/{r['release_id']}", "prezzo": r["price"], "candidati": "",
        })
    natural = lambda d: (d["lotto"], d["foto_nome"] or d["id"])  # noqa: E731
    selling.sort(key=natural)
    checking.sort(key=natural)
    return {"vendita": selling, "controllo": checking}


def render(data, generated):
    payload = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
    return PAGE.replace("__DATA__", payload).replace("__WHEN__", html.escape(generated))


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
.reason{background:var(--warn-bg);color:var(--warn);font-weight:800;padding:6px 8px;font-size:13px}
.detail{font-size:12.5px;color:var(--muted)}
details summary{cursor:pointer;font-family:var(--mono);font-size:11px;color:var(--muted)}
details p{font-family:var(--mono);font-size:11px;white-space:pre-wrap;margin:6px 0 0}
a{color:var(--green);font-weight:700}
.links{display:flex;gap:12px;margin-top:auto;padding-top:4px;font-size:13px}
.empty{padding:40px;text-align:center;color:var(--muted);border:2px dashed var(--line)}
#zoom{position:fixed;inset:0;background:rgba(0,0,0,.88);display:none;align-items:center;justify-content:center;z-index:9;cursor:zoom-out}
#zoom img{max-width:94vw;max-height:94vh}
@media (max-width:600px){header,nav,main{padding-left:16px;padding-right:16px}h1{font-size:32px}}
</style>
</head>
<body>
<header>
  <h1>Inventario dischi</h1>
  <div class="sub">Aggiornato al __WHEN__ · generato da vendi.py · le foto si vedono in Safari</div>
  <div class="stats" id="stats"></div>
</header>
<nav>
  <button class="tab" data-tab="vendita" aria-selected="true">In vendita<span class="n" id="n-vendita"></span></button>
  <button class="tab" data-tab="controllo" aria-selected="false">Da controllare<span class="n" id="n-controllo"></span></button>
  <input id="q" type="search" placeholder="Cerca: titolo, artista, lotto, cartella, file…" autocomplete="off">
  <select id="lot"><option value="">Tutti i lotti</option></select>
</nav>
<main><div class="grid" id="grid"></div></main>
<div id="zoom"><img alt=""></div>
<script>
const DATA = __DATA__;
const euro = v => v == null || v === "" ? "" : Number(v).toLocaleString("it-IT",{style:"currency",currency:"EUR"});
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
let tab = "vendita";
try { tab = localStorage.getItem("tab") || "vendita"; } catch (e) {}

const copies = DATA.vendita.reduce((s, d) => s + (d.copie || 1), 0);
const value = DATA.vendita.reduce((s, d) => s + (d.prezzo || 0) * (d.copie || 1), 0);
document.getElementById("stats").innerHTML = [
  [DATA.vendita.length, "righe in vendita"], [copies, "copie"], [euro(value), "valore di listino"],
  [DATA.controllo.length, "da controllare"]].map(([b, s]) => `<div class="stat"><b>${b}</b><span>${s}</span></div>`).join("");
document.getElementById("n-vendita").textContent = DATA.vendita.length;
document.getElementById("n-controllo").textContent = DATA.controllo.length;
const lots = [...new Set([...DATA.vendita, ...DATA.controllo].map(d => d.lotto).filter(Boolean))].sort();
document.getElementById("lot").innerHTML += lots.map(l => `<option>${esc(l)}</option>`).join("");

function pics(d) {
  if (!d.foto.length) return `<div class="pics nopic">foto non trovata<br>${esc(d.foto_nome)}</div>`;
  const [first, ...rest] = d.foto;
  return `<div class="pics"><img src="${esc(first)}" alt="" loading="lazy">
    <div class="thumbs">${rest.map(u => `<img src="${esc(u)}" alt="" loading="lazy">`).join("")}</div></div>`;
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
      <span class="chip ${d.online === "Online" ? "on" : ""}">${esc(d.online || "online non verificato")}</span></div>
    <div class="meta">${esc(d.foto_nome)} · ${esc(d.id)}</div>
    ${d.calcolo ? `<details><summary>come è stato calcolato il prezzo</summary><p>${esc(d.calcolo)}</p></details>` : ""}
    <div class="links"><a href="${esc(d.link)}" target="_blank" rel="noopener">Release su Discogs</a>
      ${d.annuncio ? `<a href="${esc(d.annuncio)}" target="_blank" rel="noopener">Annuncio</a>` : ""}</div>
  </div></article>`;
}
function cardCheck(d) {
  return `<article class="card">${pics(d)}<div class="body">
    <div class="reason">${esc(d.motivo)}</div>
    ${d.dettaglio ? `<div class="detail">${esc(d.dettaglio)}</div>` : ""}
    ${d.proposto ? `<div class="title">Proposto: ${esc(d.proposto)}</div>` : `<div class="title">Nessun disco proposto</div>`}
    <div class="chips"><span class="chip g">${grade(d)}</span>${d.lotto ? `<span class="chip">${esc(d.lotto)}</span>` : ""}
      ${d.prezzo ? `<span class="chip">${euro(d.prezzo)}</span>` : ""}</div>
    <div class="meta">${esc(d.foto_nome)} · ${esc(d.id)}</div>
    ${d.candidati ? `<details><summary>altre release possibili</summary><p>${esc(d.candidati)}</p></details>` : ""}
    <div class="links">${d.link ? `<a href="${esc(d.link)}" target="_blank" rel="noopener">Confronta su Discogs</a>` : ""}
      <a href="https://www.discogs.com/search/?type=release&format=Vinyl&q=${encodeURIComponent(d.proposto || "")}" target="_blank" rel="noopener">Cerca</a></div>
  </div></article>`;
}
function draw() {
  document.querySelectorAll(".tab").forEach(b => b.setAttribute("aria-selected", b.dataset.tab === tab));
  const q = document.getElementById("q").value.trim().toLowerCase();
  const lot = document.getElementById("lot").value;
  const list = DATA[tab].filter(d => (!lot || d.lotto === lot) &&
    (!q || JSON.stringify([d.disco, d.proposto, d.lotto, d.foto_nome, d.file, d.id, d.release, d.motivo]).toLowerCase().includes(q)));
  document.getElementById("grid").innerHTML = list.length ? list.map(tab === "vendita" ? cardSale : cardCheck).join("")
    : `<div class="empty">${tab === "vendita" ? "Nessun disco in vendita" : "Niente da controllare"}${q || lot ? " con questo filtro" : ""}</div>`;
}
document.querySelectorAll(".tab").forEach(b => b.onclick = () => {
  tab = b.dataset.tab; try { localStorage.setItem("tab", tab); } catch (e) {} draw(); });
document.getElementById("q").oninput = draw;
document.getElementById("lot").onchange = draw;
const zoom = document.getElementById("zoom");
document.getElementById("grid").addEventListener("click", e => {
  if (e.target.tagName === "IMG") { zoom.querySelector("img").src = e.target.src; zoom.style.display = "flex"; } });
zoom.onclick = () => zoom.style.display = "none";
document.addEventListener("keydown", e => { if (e.key === "Escape") zoom.style.display = "none"; });
draw();
</script>
</body>
</html>
"""


def main():
    import datetime as dt
    import sqlite3
    import vendi
    out_dir = vendi.OUT_DIR
    state = sqlite3.connect(vendi.STATE_DB)
    state.row_factory = sqlite3.Row
    try:
        path = vendi.write_panel_from_state(state, out_dir)
    finally:
        state.close()
    print(f"Pannello aggiornato: {path}  ({dt.datetime.now():%H:%M})")


if __name__ == "__main__":
    main()
