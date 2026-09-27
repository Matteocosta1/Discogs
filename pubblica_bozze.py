#!/usr/bin/env python3
"""
Mette in vendita (For Sale) le bozze (Draft) create da vendi.py --bozza.

  1. prende da data/vendita_stato.sqlite gli annunci creati in bozza da
     vendi.py: righe dei CSV di inventario con status DRAFT (dopo che li hai
     caricati su Discogs) e annunci creati via API in bozza;
  2. cerca nel tuo inventario Discogs le bozze con quegli external_id: le
     bozze che hai già messo in vendita o cancellato a mano non ci sono più e
     vengono saltate, come le righe di CSV non ancora caricati;
  3. mostra quante bozze sta per mettere in vendita (e il totale dei prezzi) e
     chiede conferma;
  4. le mette in vendita via API una per una, con il prezzo e i gradi che
     l'annuncio ha in quel momento su Discogs (se li hai cambiati a mano,
     restano i tuoi).

Si può interrompere con Ctrl+C: rilanciandolo, le bozze rimaste vengono
ritrovate e rimesse in vendita (mettere in vendita due volte lo stesso annuncio
non crea doppioni).

Esempio:
    python3 pubblica_bozze.py
"""

import argparse
from pathlib import Path

import vendi
from vendi import ApiError, ApiUncertain, DiscogsAPI, fmt, load_token, now, open_state

EXAMPLES = 10  # quante bozze mostrare prima della conferma


def our_drafts(state):
    """{external_id: origine} degli annunci che vendi.py ha creato in bozza, e {listing_id: external_id} di quelli
    creati via API (per ritrovarli anche se Discogs non restituisce l'external_id)."""
    by_eid, by_listing = {}, {}
    for r in state.execute("SELECT external_id FROM righe_csv WHERE status = 'DRAFT'"):
        by_eid[r["external_id"]] = "CSV"
    for r in state.execute("SELECT external_id, listing_id FROM annunci_api "
                           "WHERE status = 'DRAFT' AND stato = 'pubblicato'"):
        by_eid[r["external_id"]] = "API"
        if r["listing_id"]:
            by_listing[r["listing_id"]] = r["external_id"]
    return by_eid, by_listing


def find_drafts(api, username, by_eid, by_listing):
    """Bozze del tuo inventario Discogs create da vendi.py: [(item, external_id, origine)]."""
    found, page = [], 1
    while True:
        data = api.inventory_page(username, page, status="Draft")
        for item in data.get("listings", []):
            if item.get("status") != "Draft":
                continue
            eid = item.get("external_id") or by_listing.get(item.get("id"))
            if eid in by_eid:
                found.append((item, eid, by_eid[eid]))
        pages = data.get("pagination", {}).get("pages", 1)
        if page >= pages or not data.get("listings"):
            return found
        page += 1


def ask_confirmation(question):
    try:
        answer = input(f"{question} [s/N] ").strip().lower()
    except EOFError:
        return False
    return answer in ("s", "si", "sì", "y", "yes")


def main():
    parser = argparse.ArgumentParser(description="Metti in vendita le bozze create da vendi.py --bozza")
    parser.add_argument("--uscita", default=str(vendi.OUT_DIR),
                        help="cartella dei risultati da aggiornare (default: risultati/)")
    args = parser.parse_args()

    state = open_state(vendi.STATE_DB)
    by_eid, by_listing = our_drafts(state)
    if not by_eid:
        print("Nessun annuncio creato in bozza da vendi.py (serve l'opzione --bozza).")
        return

    api = DiscogsAPI(load_token())
    username = api.identity()["username"]
    print(f"Collegato a Discogs come {username}")
    print(f"Annunci creati in bozza da vendi.py: {len(by_eid)}. Cerco quali sono ancora in bozza su Discogs...")
    drafts = find_drafts(api, username, by_eid, by_listing)
    if not drafts:
        print("Nessuna bozza da mettere in vendita: sono già tutte in vendita o cancellate,\n"
              "oppure i CSV con le bozze non sono ancora stati caricati su Discogs.")
        return

    from_csv = sum(1 for _, _, o in drafts if o == "CSV")
    currencies = {(item.get("price") or {}).get("currency", "") for item, _, _ in drafts}
    total = sum((item.get("price") or {}).get("value") or 0 for item, _, _ in drafts)
    print(f"\nBozze da mettere in vendita: {len(drafts)} ({from_csv} dai CSV, {len(drafts) - from_csv} create via API)")
    if len(currencies) == 1:
        print(f"Totale dei prezzi: {fmt(total)} {currencies.pop()}")
    for item, eid, origin in drafts[:EXAMPLES]:
        price = item.get("price") or {}
        release = item.get("release") or {}
        print(f"  {eid} ({origin}): {release.get('description', release.get('id'))} - {item.get('condition')}"
              f" - {fmt(price.get('value') or 0)} {price.get('currency', '')}")
    if len(drafts) > EXAMPLES:
        print(f"  ... e altre {len(drafts) - EXAMPLES}")
    minutes = len(drafts) * DiscogsAPI.MIN_INTERVAL / 60
    if minutes >= 2:
        print(f"Tempo stimato: circa {minutes:.0f} minuti (limite di 60 richieste al minuto)")

    if not ask_confirmation(f"\nMettere in vendita (For Sale) queste {len(drafts)} bozze?"):
        print("Annullato: nessuna bozza è stata messa in vendita.")
        return

    done, problems = 0, []
    try:
        for n, (item, eid, origin) in enumerate(drafts, 1):
            listing_id = item["id"]
            price = (item.get("price") or {}).get("value")
            release_id = (item.get("release") or {}).get("id")
            try:
                api.edit_listing(listing_id, release_id, item.get("condition"), item.get("sleeve_condition"),
                                 price, "For Sale")
            except (ApiError, ApiUncertain) as e:
                problems.append(f"{eid} (listing {listing_id}): {e}")
                print(f"[{n}/{len(drafts)}] {eid}: non messo in vendita ({e})")
                continue
            state.execute("INSERT OR REPLACE INTO bozze_pubblicate VALUES (?,?,?,?,?,?)",
                          (listing_id, eid, release_id, price, origin, now()))
            if origin == "API":
                state.execute("UPDATE annunci_api SET status = 'FOR_SALE' WHERE external_id = ?", (eid,))
            state.commit()
            done += 1
            print(f"[{n}/{len(drafts)}] {eid}: in vendita (listing {listing_id})")
    except KeyboardInterrupt:
        print("\nInterrotto: rilancia lo stesso comando per mettere in vendita le bozze rimaste.")

    vendi.write_outputs(state, Path(args.uscita), [], [])
    print(f"\nMesse in vendita: {done} su {len(drafts)}")
    if problems:
        print(f"Non riuscite: {len(problems)} (rilancia il comando per riprovare, o controllale su Discogs):")
        for p in problems:
            print(f"  {p}")


if __name__ == "__main__":
    main()
