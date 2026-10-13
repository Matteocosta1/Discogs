#!/usr/bin/env python3
"""
Mette in vendita (For Sale) le bozze (Draft) create da vendi.py --bozza.

  1. prende da data/vendita_stato.sqlite gli annunci creati in bozza via API da
     vendi.py --bozza (le bozze esistono solo via API: Discogs ignora DRAFT nei
     CSV e mette subito in vendita le righe caricate);
  2. cerca nel tuo inventario Discogs le bozze con quegli external_id: le
     bozze che hai già messo in vendita o cancellato a mano non ci sono più e
     vengono saltate;
  3. mostra quante bozze sta per mettere in vendita (e il totale dei prezzi) e
     chiede conferma;
  4. le mette in vendita via API una per una, reinviando tutti i campi che
     l'annuncio ha in quel momento su Discogs (prezzo, gradi, commenti,
     external_id...): cambia solo lo stato, e se hai modificato qualcosa a mano
     resta la tua modifica.

Si può interrompere con Ctrl+C: rilanciandolo, le bozze rimaste vengono
ritrovate e rimesse in vendita (mettere in vendita due volte lo stesso annuncio
non crea doppioni).

Esempio:
    python3 pubblica_bozze.py
"""

import argparse
import datetime as dt
from pathlib import Path

import vendi
from vendi import ApiError, ApiUncertain, DiscogsAPI, fmt, listing_edit_body, load_token, now, open_state

EXAMPLES = 10  # quante bozze mostrare prima della conferma


def our_drafts(state):
    """{external_id: origine} degli annunci che vendi.py ha creato in bozza via API, e {listing_id: external_id}
    (per ritrovarli anche se Discogs non restituisce l'external_id). Le righe CSV non c'entrano: Discogs
    ignora DRAFT nei CSV, quindi una riga caricata è già in vendita."""
    by_eid, by_listing = {}, {}
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


def reworked(state):
    """{external_id: quando} delle righe CSV e degli annunci in bozza tolti da vendi.py --rielabora."""
    return dict(state.execute("SELECT external_id, MAX(archiviato) FROM rielaborati "
                              "WHERE tabella IN ('righe_csv', 'annunci_api') GROUP BY external_id"))


def drop_old_drafts(drafts, reworked_at):
    """Toglie le bozze vecchie rimaste su Discogs dopo vendi.py --rielabora: hanno lo stesso
    external_id delle nuove ma sono state create prima della rielaborazione, e non vanno mai
    messe in vendita (sarebbero doppioni). Le copie di una stessa riga CSV (quantity > 1) sono
    bozze diverse con lo stesso external_id e restano tutte. Restituisce (da mettere in vendita, vecchie)."""
    keep, old = [], []
    for d in drafts:
        when = reworked_at.get(d[1])
        if when is None:
            keep.append(d)
            continue
        try:
            posted = dt.datetime.fromisoformat(d[0].get("posted", ""))
            if posted.tzinfo is None:
                posted = posted.astimezone()
            new = posted > dt.datetime.fromisoformat(when).astimezone()
        except ValueError:
            new = False  # data sconosciuta: meglio non metterla in vendita
        (keep if new else old).append(d)
    return keep, old


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
    parser.add_argument("--backup-da-tenere", type=int, default=vendi.BACKUPS_TO_KEEP,
                        help=f"copie dello stato da tenere in data/backup/ (default {vendi.BACKUPS_TO_KEEP})")
    args = parser.parse_args()

    saved = vendi.backup_state(vendi.STATE_DB, args.backup_da_tenere)
    if saved:
        print(f"Backup dello stato: {saved}")
    state = open_state(vendi.STATE_DB)
    by_eid, by_listing = our_drafts(state)
    if not by_eid:
        print("Nessun annuncio creato in bozza da vendi.py (serve l'opzione --bozza).")
        return

    api = DiscogsAPI(load_token())
    username = api.identity()["username"]
    print(f"Collegato a Discogs come {username}")
    print(f"Annunci creati in bozza da vendi.py: {len(by_eid)}. Cerco quali sono ancora in bozza su Discogs...")
    drafts, old = drop_old_drafts(find_drafts(api, username, by_eid, by_listing), reworked(state))
    if old:
        print(f"\nAttenzione: {len(old)} bozze vecchie, create prima di vendi.py --rielabora per le stesse foto.\n"
              "NON verranno messe in vendita (sarebbero doppioni): cancellale a mano su Discogs.")
        for item, eid, _origin in old:
            print(f"  {eid}: listing {item['id']} https://www.discogs.com/sell/item/{item['id']}")
    if not drafts:
        print("Nessuna bozza da mettere in vendita: sono già tutte in vendita o cancellate.")
        return

    currencies = {(item.get("price") or {}).get("currency", "") for item, _, _ in drafts}
    total = sum((item.get("price") or {}).get("value") or 0 for item, _, _ in drafts)
    print(f"\nBozze da mettere in vendita: {len(drafts)}")
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
                # Tutti i campi attuali dell'annuncio (commenti, external_id, posizione...), cambia solo lo stato:
                # inviando solo i campi obbligatori Discogs potrebbe azzerare gli altri.
                api.edit_listing_fields(listing_id, listing_edit_body(item, status="For Sale"))
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
