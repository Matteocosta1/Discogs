#!/usr/bin/env python3
"""
Controlla cosa è davvero online su Discogs tra i dischi preparati da vendi.py.

  1. fa un backup dello stato (data/backup/);
  2. scarica tutto il tuo inventario Discogs, tutte le pagine: annunci in vendita,
     in bozza e, se Discogs li restituisce, venduti e scaduti;
  3. per ogni riga dei CSV di inventario e ogni annuncio creato via API dice se
     l'external_id è online e in che stato, e lo salva in data/vendita_stato.sqlite
     (in_vendita / bozza / venduto / scaduto / assente / bozza_cancellata / sparito);
  4. corregge lo status delle righe CSV caricate come DRAFT: Discogs ignora DRAFT
     nei CSV e le mette subito in vendita;
  5. stampa un riepilogo e, soprattutto, le righe generate ma NON online, divise per
     file CSV (CSV mai caricato o righe scartate da Discogs); scrive anche
     risultati/verifica_inventario.csv con l'esito di ogni riga;
  6. con --libera, dopo conferma, toglie dallo stato le righe mai state online (o
     bozze poi cancellate): le loro foto tornano elaborabili al prossimo vendi.py,
     senza rifare il riconoscimento e senza pagare di nuovo l'AI. Le righe che
     erano in vendita e ora non ci sono più ("sparito": vendute o cancellate) non
     vengono mai liberate.

Esempi:
    python3 verifica_inventario.py
    python3 verifica_inventario.py --libera
"""

import argparse
from pathlib import Path

import vendi
from vendi import (ONLINE_IT, DiscogsAPI, InventoryUnreadable, can_free, fetch_inventory, free_rows, load_token,
                   open_state, verify_listings, write_csv, write_outputs)

EXAMPLES = 10


def ask_confirmation(question):
    try:
        answer = input(f"{question} [s/N] ").strip().lower()
    except EOFError:
        return False
    return answer in ("s", "si", "sì", "y", "yes")


def describe(table, row):
    if table == "righe_csv":
        return (f"inventario_{row['parte']:03d}.csv", f"{row['external_id']} (release {row['release_id']}, "
                f"{row['quantita']} cop{'ia' if row['quantita'] == 1 else 'ie'}, {row['price']:.2f})")
    return ("annunci via API", f"{row['external_id']} (release {row['release_id']}, {row['price']:.2f}, "
            f"listing {row['listing_id'] or '-'}, {row['stato']})")


def main():
    parser = argparse.ArgumentParser(description="Controlla cosa è davvero online su Discogs")
    parser.add_argument("--libera", action="store_true",
                        help="dopo conferma, toglie dallo stato le righe mai state online: le foto tornano elaborabili "
                             "al prossimo vendi.py, senza rifare il riconoscimento")
    parser.add_argument("--uscita", default=str(vendi.OUT_DIR), help="cartella dei risultati (default: risultati/)")
    parser.add_argument("--backup-da-tenere", type=int, default=vendi.BACKUPS_TO_KEEP,
                        help=f"copie dello stato da tenere in data/backup/ (default {vendi.BACKUPS_TO_KEEP})")
    args = parser.parse_args()
    out_dir = Path(args.uscita).expanduser()

    saved = vendi.backup_state(vendi.STATE_DB, args.backup_da_tenere)
    if saved:
        print(f"Backup dello stato: {saved}")
    state = open_state(vendi.STATE_DB)
    try:
        api = DiscogsAPI(load_token())
        username = api.identity()["username"]
        print(f"Collegato a Discogs come {username}. Scarico l'inventario...")
        try:
            inventory = fetch_inventory(api, username)
        except InventoryUnreadable as e:
            raise SystemExit(f"Impossibile leggere l'inventario Discogs: {e}\nNiente è stato modificato.")
        print(f"Annunci nel tuo inventario: {len(inventory.by_listing)}"
              + (f" (Discogs non ha restituito: {', '.join(inventory.unavailable)})" if inventory.unavailable else ""))

        rows = verify_listings(state, inventory)
        counts, not_online, gone = {}, {}, []
        for table, row in rows:
            copies = row["quantita"] if table == "righe_csv" else 1
            counts[row["online"]] = counts.get(row["online"], 0) + copies
            where, text = describe(table, row)
            if row["online"] in ("assente", "bozza_cancellata"):
                not_online.setdefault(where, []).append(text + (" (bozza cancellata)"
                                                                if row["online"] == "bozza_cancellata" else ""))
            elif row["online"] == "sparito":
                gone.append(f"{where}: {text}")

        print("\nRiepilogo (dischi, contando le copie)")
        for key in ("in_vendita", "bozza", "venduto", "scaduto", "assente", "bozza_cancellata", "sparito"):
            if counts.get(key):
                print(f"  {ONLINE_IT[key]}: {counts[key]}")
        if not rows:
            print("  nessuna riga CSV né annuncio API nello stato")

        if not_online:
            print("\nRighe generate ma NON online (CSV mai caricato o righe scartate da Discogs):")
            for where, texts in sorted(not_online.items()):
                print(f"  {where}: {len(texts)}")
                for t in texts[:EXAMPLES]:
                    print(f"    {t}")
                if len(texts) > EXAMPLES:
                    print(f"    ... e altre {len(texts) - EXAMPLES}")
        if gone:
            print("\nErano online e ora non ci sono più (vendute o cancellate a mano?): restano nello stato, "
                  "così non vengono rimesse in vendita.")
            for g in gone[:EXAMPLES]:
                print(f"  {g}")

        write_csv(out_dir / "verifica_inventario.csv",
                  ["origine", "external_id", "release_id", "quantita", "prezzo", "status", "online",
                   "verificato", "visto_online_la_prima_volta"],
                  [[describe(t, r)[0], r["external_id"], r["release_id"], r["quantita"] if t == "righe_csv" else 1,
                    f"{r['price']:.2f}", r["status"] or "FOR_SALE", ONLINE_IT.get(r["online"], r["online"]),
                    r["online_verificato"] or "", r["online_visto"] or ""] for t, r in rows])
        write_outputs(state, out_dir, [], [])
        print(f"\nDettaglio in {out_dir / 'verifica_inventario.csv'}")

        if args.libera:
            freeable = [(t, r) for t, r in rows if can_free(t, r)]
            if not freeable:
                print("\n--libera: nessuna riga da liberare.")
                return
            print(f"\n--libera: {len(freeable)} righe mai state online verranno tolte dallo stato; le loro foto "
                  "torneranno elaborabili al prossimo vendi.py (il riconoscimento resta).")
            if not ask_confirmation("Procedere?"):
                print("Annullato: niente è stato modificato.")
                return
            freed = free_rows(state, out_dir, freeable)
            write_outputs(state, out_dir, [], [])
            print(f"Liberate {len(freeable)} righe ({len(freed)} foto). I file CSV svuotati sono in "
                  f"{out_dir / 'archivio'}/ con _ANNULLATO nel nome: non caricarli.")
    finally:
        state.close()


if __name__ == "__main__":
    main()
