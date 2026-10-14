#!/usr/bin/env python3
"""
Mette in Draft (bozza) su Discogs i dischi che il controllo visivo ha segnato con la copertina
sbagliata (colonna ai_verdetto = DIVERSA in risultati/verifica_copertine_online.csv).

- Chiede UNA conferma prima di toccare qualsiasi annuncio.
- Cambia SOLO lo stato (For Sale -> Draft): release, prezzo, commenti e tutto il resto restano uguali.
- Rilegge ogni annuncio per verificare; scrive l'esito in risultati/messi_in_draft.csv.
- Per rimetterli in vendita: dal sito (Edit -> Status: For Sale) oppure riconosci_di_nuovo.py --applica
  (che corregge la release e lascia lo stato com'è) e poi For Sale dal sito.

Uso (dalla cartella del progetto):
    python3 metti_in_draft.py
"""

import csv
import sqlite3
from pathlib import Path

import vendi


def main():
    source = Path(vendi.OUT_DIR) / "verifica_copertine_online.csv"
    if not source.exists():
        raise SystemExit("Prima lancia: python3 verifica_copertine_online.py --ai")
    with source.open(newline="", encoding="utf-8") as fh:
        todo = [r for r in csv.DictReader(fh) if r.get("ai_verdetto") == "DIVERSA"]
    if not todo:
        raise SystemExit("Nessun disco DIVERSA nel controllo.")

    # Gli annunci veri si cercano nell'inventario ATTUALE di Discogs (i numeri salvati possono essere
    # vecchi, e i dischi caricati con il CSV non li hanno): per external_id della foto o della riga CSV,
    # e in mancanza per release, tra gli annunci In vendita.
    api = vendi.DiscogsAPI(vendi.load_token())
    username = api.identity()["username"]
    print("Leggo l'inventario su Discogs...")
    inv = vendi.fetch_inventory(api, username, statuses=("For Sale", "Draft"))
    state = sqlite3.connect(f"file:{vendi.STATE_DB}?mode=ro", uri=True)
    state.row_factory = sqlite3.Row
    for r in todo:
        row = state.execute("SELECT riga_csv FROM foto WHERE external_id = ?", (r["foto"],)).fetchone()
        eids = {r["foto"]} | ({row["riga_csv"]} if row and row["riga_csv"] else set())
        rid = int(r["release"].rsplit("/", 1)[-1])
        found = {}
        for item in inv.by_listing.values():
            eid = item.get("external_id") or ""
            if eid in eids or any(eid.startswith(e + "-") for e in eids):
                found[item["id"]] = item
        if not found:   # niente external_id: per release, solo se l'annuncio è uno solo
            same = [i for i in inv.by_listing.values() if (i.get("release") or {}).get("id") == rid]
            if len(same) == 1:
                found[same[0]["id"]] = same[0]
        r["_listings"] = list(found.values())
    print(f"Dischi con copertina sbagliata: {len(todo)}")
    for r in todo:
        n = len(r["_listings"])
        print(f"  - {r['disco_online']}" + ("" if n else "   (non trovato su Discogs: salto)")
              + (f"   ({n} annunci)" if n > 1 else ""))
    try:
        answer = input("\nLi metto in Draft su Discogs? [s/N] ").strip().lower()
    except EOFError:
        answer = ""
    if answer not in ("s", "si", "sì", "y"):
        raise SystemExit("Nessuna modifica.")

    results, done = [], 0
    for r in todo:
        if not r["_listings"]:
            results.append({"disco": r["disco_online"], "listing_id": "",
                            "esito": "non trovato tra gli annunci (forse già tolto o venduto)"})
            print(f"  {'non trovato su Discogs':<32} {r['disco_online']}")
            continue
        for listing in r["_listings"]:
            lid = listing["id"]
            out = {"disco": r["disco_online"], "listing_id": lid, "esito": ""}
            try:
                status = listing.get("status")
                if status == "Draft":
                    out["esito"] = "era già in Draft"
                elif status != "For Sale":
                    out["esito"] = f"stato {status}: non toccato"
                else:
                    full = api.get_listing(lid)
                    api.edit_listing_fields(lid, vendi.listing_edit_body(full, status="Draft"))
                    after = vendi.listing_fields(api.get_listing(lid)).get("status")
                    out["esito"] = "messo in Draft" if after == "Draft" else f"NON riuscito (stato: {after})"
                    done += after == "Draft"
            except Exception as e:
                out["esito"] = f"errore: {e}"
            print(f"  {out['esito']:<32} {out['disco']}")
            results.append(out)

    out_file = Path(vendi.OUT_DIR) / "messi_in_draft.csv"
    with out_file.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=["disco", "listing_id", "esito"])
        w.writeheader()
        w.writerows(results)
    print(f"\nMessi in Draft: {done} su {len(todo)}. Dettaglio: {out_file.resolve()}")


if __name__ == "__main__":
    main()
