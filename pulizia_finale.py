#!/usr/bin/env python3
"""
Pulizia definitiva dell'inventario: su Discogs restano In vendita SOLO i dischi sicuri, cioè quelli
con la copertina confermata UGUALE dall'AI (risultati/verifica_copertine_online.csv, colonna
ai_verdetto). Tutti gli altri annunci In vendita vanno in Draft:
  - PROBABILE, DIVERSA (copertina dubbia o sbagliata);
  - non controllati (foto non più nelle cartelle);
  - annunci che non si collegano a nessuna foto dello stato (es. caricati a mano).

- Mostra l'elenco completo e chiede UNA conferma.
- Cambia solo lo stato (For Sale -> Draft): niente viene cancellato, si può annullare dal sito.
- Rilegge ogni annuncio per verificare; esito in risultati/pulizia_finale.csv.

Uso (dalla cartella del progetto):
    python3 pulizia_finale.py
"""

import csv
import sqlite3
from pathlib import Path

import vendi

REASON = {"PROBABILE": "copertina probabile, da guardare", "DIVERSA": "copertina sbagliata",
          "": "non controllato (foto mancanti)", None: "non collegato a nessuna foto"}


def main():
    source = Path(vendi.OUT_DIR) / "verifica_copertine_online.csv"
    if not source.exists():
        raise SystemExit("Prima lancia: python3 verifica_copertine_online.py --ai")
    with source.open(newline="", encoding="utf-8") as fh:
        verdict = {r["foto"]: r.get("ai_verdetto", "") for r in csv.DictReader(fh)}

    state = sqlite3.connect(f"file:{vendi.STATE_DB}?mode=ro", uri=True)
    state.row_factory = sqlite3.Row
    # external_id che un annuncio può avere -> foto dello stato
    owner = {}
    for f in state.execute("SELECT external_id, riga_csv FROM foto"):
        owner.setdefault(f["external_id"], set()).add(f["external_id"])
        if f["riga_csv"]:
            owner.setdefault(f["riga_csv"], set()).add(f["external_id"])

    def photos_of(eid):
        if not eid:
            return set()
        if eid in owner:
            return owner[eid]
        base = eid.rsplit("-", 1)[0]          # copia N di un annuncio via API: "<foto>-N"
        return owner.get(base, set())

    api = vendi.DiscogsAPI(vendi.load_token())
    print("Leggo l'inventario su Discogs...")
    inv = vendi.fetch_inventory(api, api.identity()["username"], statuses=("For Sale",))
    keep, move = [], []
    for item in inv.by_listing.values():
        if item.get("status") != "For Sale":
            continue
        rel = item.get("release") or {}
        title = rel.get("description") or f"{rel.get('artist', '')} - {rel.get('title', '')}"
        photos = photos_of(item.get("external_id"))
        if not photos:
            move.append((item, title, REASON[None]))
            continue
        marks = {verdict.get(p, "") for p in photos}
        if marks == {"UGUALE"}:
            keep.append((item, title))
        else:
            worst = next(m for m in ("DIVERSA", "PROBABILE", "") if m in marks)
            move.append((item, title, REASON[worst]))

    print(f"\nIn vendita ora: {len(keep) + len(move)}")
    print(f"  RESTANO in vendita (sicuri): {len(keep)}")
    print(f"  VANNO in Draft:               {len(move)}")
    for _i, title, why in sorted(move, key=lambda x: x[2]):
        print(f"    - {title}   [{why}]")
    if not move:
        raise SystemExit("\nNiente da spostare: in vendita ci sono solo dischi sicuri.")
    try:
        answer = input(f"\nMetto in Draft questi {len(move)} annunci? [s/N] ").strip().lower()
    except EOFError:
        answer = ""
    if answer not in ("s", "si", "sì", "y"):
        raise SystemExit("Nessuna modifica.")

    results, done = [], 0
    for item, title, why in move:
        lid = item["id"]
        try:
            full = api.get_listing(lid)
            api.edit_listing_fields(lid, vendi.listing_edit_body(full, status="Draft"))
            after = vendi.listing_fields(api.get_listing(lid)).get("status")
            esito = "messo in Draft" if after == "Draft" else f"NON riuscito (stato: {after})"
            done += after == "Draft"
        except Exception as e:
            esito = f"errore: {e}"
        print(f"  {esito:<24} {title}")
        results.append({"disco": title, "listing_id": lid, "motivo": why, "esito": esito,
                        "link": f"https://www.discogs.com/sell/item/{lid}"})

    out = Path(vendi.OUT_DIR) / "pulizia_finale.csv"
    with out.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=["disco", "motivo", "esito", "listing_id", "link"])
        w.writeheader()
        w.writerows(results)
    print(f"\nMessi in Draft: {done} su {len(move)}. In vendita restano {len(keep)} dischi sicuri.")
    print(f"Elenco con i link per il controllo a mano: {out.resolve()}")


if __name__ == "__main__":
    main()
