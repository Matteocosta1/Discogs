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

    print(f"Dischi con copertina sbagliata: {len(todo)}")
    for r in todo:
        print(f"  - {r['disco_online']}" + ("" if r.get("listing_id") else "   (nessun annuncio: salto)"))
    try:
        answer = input("\nLi metto in Draft su Discogs? [s/N] ").strip().lower()
    except EOFError:
        answer = ""
    if answer not in ("s", "si", "sì", "y"):
        raise SystemExit("Nessuna modifica.")

    api = vendi.DiscogsAPI(vendi.load_token())
    results, done = [], 0
    for r in todo:
        lid = r.get("listing_id")
        out = {"disco": r["disco_online"], "listing_id": lid or "", "esito": ""}
        if not lid:
            out["esito"] = "nessun annuncio collegato: controllare a mano"
        else:
            try:
                listing = api.get_listing(int(lid))
                status = vendi.listing_fields(listing).get("status")
                if status == "Draft":
                    out["esito"] = "era già in Draft"
                elif status != "For Sale":
                    out["esito"] = f"stato {status}: non toccato"
                else:
                    api.edit_listing_fields(int(lid), vendi.listing_edit_body(listing, status="Draft"))
                    after = vendi.listing_fields(api.get_listing(int(lid))).get("status")
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
