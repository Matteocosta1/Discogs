#!/usr/bin/env python3
"""
Confronta i dischi GIÀ ONLINE con il riconoscimento rifatto da zero nella copia di prova.

Legge due stati di vendi.py, SOLO IN LETTURA (non modifica niente, non tocca Discogs):
  - il vecchio: quello vero, da cui sono partiti gli annunci online;
  - il nuovo:   quello della copia di prova, dopo vendi.py --simula con l'ultima versione.

Per ogni disco online dice se il nuovo riconoscimento:
  UGUALE   -> stessa release: confermato;
  DIVERSO  -> un'altra release: molto probabilmente uno dei due è sbagliato, da guardare SUBITO;
  FERMO    -> la nuova versione non lo chiuderebbe da sola (da controllare);
  MANCA    -> non rielaborato nella prova (lotto non rilanciato).

Scrive tutto in confronto_test.csv (si apre con Numbers) e stampa il riepilogo.

Uso:
    python3 confronta_test.py VECCHIO_STATO NUOVO_STATO
"""

import csv
import sqlite3
import sys
from pathlib import Path

RELEASE = "https://www.discogs.com/release/{}"


def open_ro(path):
    p = Path(path).expanduser()
    if not p.is_file():
        raise SystemExit(f"File non trovato: {p}")
    con = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def online_photos(old):
    """Foto riconosciute del vecchio stato che sono finite online (annuncio API pubblicato o riga CSV)."""
    published = {}
    for r in old.execute("SELECT external_id, listing_id, price, stato FROM annunci_api"):
        if r["stato"] == "pubblicato":
            published[r["external_id"]] = r
    confirmed = {r["external_id"] for r in old.execute("SELECT external_id FROM conferme")}
    out = []
    for f in old.execute("SELECT * FROM foto WHERE release_id IS NOT NULL"):
        eid = f["external_id"]
        listing = published.get(eid) or next((v for k, v in published.items() if k.startswith(eid + "-")), None)
        if listing is None and not f["riga_csv"]:
            continue
        out.append((f, listing, eid in confirmed))
    return out


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    old, new = open_ro(sys.argv[1]), open_ro(sys.argv[2])
    rows, counts = [], {"UGUALE": 0, "DIVERSO": 0, "FERMO": 0, "MANCA": 0}
    for f, listing, confirmed in online_photos(old):
        n = new.execute("SELECT esito, release_id, disco, metodo, motivo FROM foto WHERE external_id = ?",
                        (f["external_id"],)).fetchone()
        if n is None:
            verdict = "MANCA"
        elif n["esito"] == "trovato" and n["release_id"] == f["release_id"]:
            verdict = "UGUALE"
        elif n["esito"] == "trovato":
            verdict = "DIVERSO"
        else:
            verdict = "FERMO"
        counts[verdict] += 1
        rows.append({
            "esito": verdict,
            "foto": f["external_id"],
            "cartella": f["cartella"],
            "grado": f["media"] if f["media"] == f["sleeve"] else f"{f['media']}/{f['sleeve']}",
            "online_disco": f["disco"] or "",
            "online_release": RELEASE.format(f["release_id"]),
            "online_metodo": f["metodo"] or "",
            "scelto_a_mano": "sì" if confirmed else "",
            "listing_id": (listing["listing_id"] if listing else "") or "",
            "nuovo_disco": (n["disco"] if n else "") or "",
            "nuovo_release": RELEASE.format(n["release_id"]) if n and n["release_id"] else "",
            "nuovo_esito": (n["esito"] if n else "") or "",
            "nuovo_metodo": (n["metodo"] if n else "") or "",
            "nuovo_motivo": (n["motivo"] if n else "") or "",
        })
    order = {"DIVERSO": 0, "FERMO": 1, "MANCA": 2, "UGUALE": 3}
    rows.sort(key=lambda r: (order[r["esito"]], r["cartella"], r["foto"]))
    out = Path("confronto_test.csv")
    with out.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()) if rows else ["esito"])
        w.writeheader()
        w.writerows(rows)
    total = sum(counts.values())
    print(f"Dischi online controllati: {total}")
    print(f"  UGUALE  (confermati):            {counts['UGUALE']}")
    print(f"  DIVERSO (da guardare subito):    {counts['DIVERSO']}")
    print(f"  FERMO   (oggi andrebbe a mano):  {counts['FERMO']}")
    print(f"  MANCA   (lotto non rilanciato):  {counts['MANCA']}")
    for r in rows:
        if r["esito"] == "DIVERSO":
            print(f"  ! {r['foto']}: online «{r['online_disco']}» -> ora «{r['nuovo_disco']}»"
                  + (" [era scelto a mano]" if r["scelto_a_mano"] else ""))
    print(f"\nDettaglio completo in {out.resolve()}")


if __name__ == "__main__":
    main()
