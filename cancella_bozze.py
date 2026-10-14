#!/usr/bin/env python3
"""
Cancella da Discogs TUTTI gli annunci in bozza (Draft) del venditore. Quelli In vendita non si toccano.

- Legge l'inventario, conta le bozze e chiede UNA conferma (s/N).
- Prima di cancellare rilegge ogni annuncio: se non è più in bozza, lo salta.
- Una richiesta al secondo (limite di Discogs).
- Nello stato dello script le righe cancellate diventano "bozza cancellata" (come fa verifica_inventario.py).
- ATTENZIONE: la cancellazione su Discogs non si può annullare.

Uso (dalla cartella del progetto):
    python3 cancella_bozze.py
"""

import sqlite3

import vendi


def main():
    api = vendi.DiscogsAPI(vendi.load_token())
    username = api.identity()["username"]
    print(f"Collegato a Discogs come {username}. Leggo le bozze...")
    inv = vendi.fetch_inventory(api, username, statuses=("Draft",))
    drafts = [i for i in inv.by_listing.values() if i.get("status") == "Draft"]
    if not drafts:
        raise SystemExit("Nessuna bozza su Discogs: niente da cancellare.")
    print(f"\nBozze trovate: {len(drafts)}")
    for item in drafts:
        print(f"  - {(item.get('release') or {}).get('description', '?')}   (annuncio {item['id']})")
    try:
        answer = input(f"\nCancello DEFINITIVAMENTE queste {len(drafts)} bozze? Gli annunci In vendita restano. [s/N] ")
    except EOFError:
        answer = ""
    if answer.strip().lower() not in ("s", "si", "sì", "y"):
        raise SystemExit("Nessuna modifica.")

    state = sqlite3.connect(vendi.STATE_DB)
    done = 0
    try:
        for item in drafts:
            lid, title = item["id"], (item.get("release") or {}).get("description", "?")
            try:
                status = vendi.listing_fields(api.get_listing(lid)).get("status")
                if status != "Draft":
                    print(f"  saltato (ora è '{status}'): {title}")
                    continue
                api.request("DELETE", f"/marketplace/listings/{lid}")
            except vendi.ApiError as e:
                print(f"  ERRORE ({e}): {title}")
                continue
            state.execute("UPDATE annunci_api SET online = 'bozza_cancellata', online_ultimo = 'bozza_cancellata'"
                          " WHERE listing_id = ?", (lid,))
            if item.get("external_id"):
                state.execute("UPDATE righe_csv SET online = 'bozza_cancellata', online_ultimo = 'bozza_cancellata'"
                              " WHERE external_id = ?", (item["external_id"],))
            state.commit()
            done += 1
            print(f"  cancellata: {title}")
    finally:
        state.close()
    print(f"\nBozze cancellate: {done} su {len(drafts)}. Gli annunci In vendita non sono stati toccati.")


if __name__ == "__main__":
    main()
