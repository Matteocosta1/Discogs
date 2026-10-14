#!/usr/bin/env python3
"""
Controllo visivo dei dischi GIÀ ONLINE e di quelli PRONTI nel pannello (non ancora pubblicati): le foto
di ogni disco vengono confrontate
con TUTTE le immagini della release su Discogs (copertina, retro, etichette: fino a 8 per release),
con lo stesso motore di copertine.py (Vision di macOS).

- NON usa l'AI (costo zero), NON modifica lo stato, NON tocca gli annunci su Discogs.
- Scarica le immagini in data/copertine_tutte/ (una volta sola per release).
- Scrive risultati/verifica_copertine_online.csv, dal disco più sospetto al più sicuro.

Esiti:
  OK          una foto combacia con un'immagine della release
  DUBBIO      somiglianza bassa: da guardare
  DIVERSA     nessuna immagine somiglia: probabilmente disco sbagliato, da mettere in Draft
  SENZA_IMMAGINI la release su Discogs non ha immagini: controllo impossibile
  FOTO_MANCANTI le foto del disco non sono più nella cartella

Uso (dalla cartella del progetto):
    python3 verifica_copertine_online.py
"""

import csv
import sqlite3
from pathlib import Path

import copertine as cm
import vendi

ALL_IMAGES = 8
COVER_ALL_DIR = vendi.dd.DATA_DIR / "copertine_tutte"
DOUBT_MARGIN = {"vision": 0.15, "pil": 0.12}   # sopra la soglia "stessa copertina", fin qui è DUBBIO
RELEASE = "https://www.discogs.com/release/{}"


def photo_files(row):
    p = Path(row["foto"] or "")
    if p.is_dir():
        return sorted(f for f in p.iterdir() if f.is_file() and f.suffix.lower() in vendi.IMAGE_EXTS
                      and not f.name.startswith("."))
    return [p] if p.is_file() else []


def online_rows(state):
    published = {r["external_id"]: r for r in state.execute(
        "SELECT * FROM annunci_api WHERE stato IN ('pubblicato', 'pronto')")}
    out = []
    for f in state.execute("SELECT * FROM foto WHERE release_id IS NOT NULL ORDER BY cartella, external_id"):
        eid = f["external_id"]
        listing = published.get(eid) or next((v for k, v in published.items() if k.startswith(eid + "-")), None)
        if listing is None and not f["riga_csv"]:
            continue
        out.append((f, listing))
    return out


def main():
    cm.MAX_IMAGES = ALL_IMAGES
    state = sqlite3.connect(f"file:{vendi.STATE_DB}?mode=ro", uri=True)
    state.row_factory = sqlite3.Row
    confirmed = {r["external_id"] for r in state.execute("SELECT external_id FROM conferme")}
    api = vendi.DiscogsAPI(vendi.load_token())
    store = cm.CoverStore(api, COVER_ALL_DIR)
    matcher = cm.Matcher()
    strong = cm.STRONG[matcher.backend]
    doubt = strong + DOUBT_MARGIN[matcher.backend]
    print(f"Confronto con il motore: {matcher.backend}")
    if matcher.backend != "vision":
        print("Attenzione: Vision non disponibile, uso il confronto semplice (meno preciso).")

    rows = online_rows(state)
    results = []
    for n, (f, listing) in enumerate(rows, 1):
        photos = photo_files(f)
        rid = f["release_id"]
        distance, n_images = None, 0
        if not photos:
            verdict = "FOTO_MANCANTI"
        else:
            try:
                images = store.paths(rid)
            except Exception as e:   # un errore su un disco non deve fermare il controllo
                print(f"  {f['external_id']}: immagini non scaricate ({e})")
                images = []
            n_images = len(images)
            if not images:
                verdict = "SENZA_IMMAGINI"
            else:
                distance = matcher.compare([str(p) for p in photos], {rid: images}).get(rid)
                if distance is None:
                    verdict = "SENZA_IMMAGINI"
                elif distance <= strong:
                    verdict = "OK"
                elif distance <= doubt:
                    verdict = "DUBBIO"
                else:
                    verdict = "DIVERSA"
        mark = "" if verdict == "OK" else "  <--"
        print(f"[{n}/{len(rows)}] {verdict:<14} {f['disco'] or rid}"
              + (f" (distanza {distance:.2f})" if distance is not None else "") + mark)
        results.append({
            "esito": verdict,
            "distanza": f"{distance:.2f}" if distance is not None else "",
            "disco_online": f["disco"] or "",
            "release": RELEASE.format(rid),
            "metodo": f["metodo"] or "",
            "scelto_a_mano": "sì" if f["external_id"] in confirmed else "",
            "stato": ("in vendita" if not listing or listing["stato"] == "pubblicato" else "pronto, non pubblicato"),
            "listing_id": (listing["listing_id"] if listing else "") or "",
            "immagini_discogs": n_images,
            "foto": f["external_id"],
            "cartella": f["cartella"],
            "percorso_foto": f["foto"],
        })

    order = {"DIVERSA": 0, "DUBBIO": 1, "SENZA_IMMAGINI": 2, "FOTO_MANCANTI": 3, "OK": 4}
    results.sort(key=lambda r: (order[r["esito"]], -(float(r["distanza"]) if r["distanza"] else 0)))
    out = Path(vendi.OUT_DIR) / "verifica_copertine_online.csv"
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(results[0].keys()) if results else ["esito"])
        w.writeheader()
        w.writerows(results)

    print("\nRiepilogo (dischi online e pronti):")
    for k in ("OK", "DUBBIO", "DIVERSA", "SENZA_IMMAGINI", "FOTO_MANCANTI"):
        print(f"  {k:<15} {sum(1 for r in results if r['esito'] == k)}")
    print(f"Richieste a Discogs per le immagini: {store.calls}")
    print(f"Dettaglio (dal più sospetto): {out.resolve()}")


if __name__ == "__main__":
    main()
