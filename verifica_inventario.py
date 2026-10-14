#!/usr/bin/env python3
"""
Controlla cosa è davvero online su Discogs tra i dischi preparati da vendi.py.

  1. fa un backup dello stato (data/backup/);
  2. scarica tutto il tuo inventario Discogs, tutte le pagine: annunci in vendita,
     in bozza e, se Discogs li restituisce, venduti e scaduti;
  3. legge i tuoi ordini (tutte le pagine, tutti gli stati): l'inventario NON mostra
     i dischi venduti, quindi un annuncio che compare in un ordine non annullato è
     "venduto" (collegamento: l'id dell'annuncio di ogni articolo dell'ordine);
  4. per ogni riga dei CSV di inventario e ogni annuncio creato via API salva nello
     stato se è online e come: in vendita, in bozza, venduto, forse venduto (la
     release è in un ordine ma l'annuncio non è mai stato visto), bloccata da
     Discogs, non online (mai caricato o scartato), bozza cancellata, rimosso a mano
     (era in vendita e non è in nessun ordine), sparito (ordini non letti);
  5. corregge lo status delle righe CSV caricate come DRAFT: Discogs ignora DRAFT
     nei CSV e le mette subito in vendita;
  6. stampa il riepilogo (in vendita / in bozza / venduti / bloccati da Discogs / non
     online per altri motivi) con il dettaglio per file CSV, e lo scrive in
     risultati/verifica_inventario.csv;
  7. con --libera (o --libera-solo EXTERNAL_ID per righe precise), dopo conferma,
     toglie dallo stato le righe non online e NON vendute: mai caricate, bozze
     cancellate, rimosse a mano. Le loro foto tornano elaborabili al prossimo
     vendi.py, senza rifare il riconoscimento né pagare l'AI. Mai un disco venduto
     o forse venduto, mai una release bloccata (liberarla non servirebbe). Se gli
     ordini non si leggono, --libera e --libera-solo non partono.

Esempi:
    python3 verifica_inventario.py
    python3 verifica_inventario.py --libera
    python3 verifica_inventario.py --libera-solo IMG_2087
"""

import argparse
import json
from pathlib import Path

import vendi
from vendi import (ONLINE_IT, DiscogsAPI, InventoryUnreadable, OrdersUnreadable, can_free, fetch_inventory,
                   fetch_sales, free_rows, load_token, open_state, verify_listings, write_csv, write_outputs)

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


# Gruppi del riepilogo: stato online -> gruppo
GROUPS = [("in_vendita", "in vendita"), ("bozza", "in bozza"), ("venduto", "venduti"),
          ("bloccata", "bloccati da Discogs"), ("altro", "non online per altri motivi")]
GROUP_OF = {"in_vendita": "in_vendita", "bozza": "bozza", "venduto": "venduto", "bloccata": "bloccata"}


def main():
    parser = argparse.ArgumentParser(description="Controlla cosa è davvero online su Discogs")
    parser.add_argument("--libera", action="store_true",
                        help="dopo conferma, toglie dallo stato le righe non online e non vendute (mai caricate, "
                             "bozze cancellate, rimosse a mano): le foto tornano elaborabili al prossimo vendi.py")
    parser.add_argument("--libera-solo", action="append", default=[], metavar="EXTERNAL_ID",
                        help="come --libera ma solo per la riga con questo external_id (ripetibile)")
    parser.add_argument("--uscita", default=str(vendi.OUT_DIR), help="cartella dei risultati (default: risultati/)")
    parser.add_argument("--backup-da-tenere", type=int, default=vendi.BACKUPS_TO_KEEP,
                        help=f"copie dello stato da tenere in data/backup/ (default {vendi.BACKUPS_TO_KEEP})")
    args = parser.parse_args()
    out_dir = Path(args.uscita).expanduser()
    freeing = args.libera or bool(args.libera_solo)

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
        # Ordine della pagina Discogs (annunci In vendita, dal più recente): il pannello lo riprende uguale
        order = [lid for lid, item in inventory.by_listing.items() if item.get("status") == "For Sale"]
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / "ordine_discogs.json").write_text(json.dumps(order))
        print(f"Annunci nel tuo inventario: {len(inventory.by_listing)}"
              + (f" (Discogs non ha restituito: {', '.join(inventory.unavailable)})" if inventory.unavailable else ""))
        # L'inventario non mostra i dischi venduti: li riconosco dai miei ordini.
        try:
            sales = fetch_sales(api)
            print(f"Ordini letti: {len(sales.listing_ids)} annunci venduti (ordini annullati esclusi)")
        except OrdersUnreadable as e:
            sales = None
            if freeing:
                raise SystemExit(f"Impossibile leggere i tuoi ordini Discogs ({e}).\nSenza ordini non posso "
                                 "distinguere un disco VENDUTO da uno rimosso a mano o mai caricato: --libera e "
                                 "--libera-solo non partono, per non rimettere in vendita un disco che non hai più.\n"
                                 "Niente è stato modificato.")
            print(f"Attenzione: impossibile leggere i tuoi ordini ({e}): i dischi spariti dall'inventario non "
                  "si possono distinguere tra venduti e rimossi a mano.")

        rows = verify_listings(state, inventory, sales)
        ready = sum(1 for t, r in rows if t == "annunci_api" and r["stato"] == "pronto")
        rows = [(t, r) for t, r in rows if not (t == "annunci_api" and r["stato"] == "pronto")]
        if ready:
            print(f"Annunci pronti, non ancora pubblicati (python vendi.py --pubblica): {ready}")
        counts, details = {}, {}
        for table, row in rows:
            copies = row["quantita"] if table == "righe_csv" else 1
            group = GROUP_OF.get(row["online"], "altro")
            counts[group] = counts.get(group, 0) + copies
            if group != "in_vendita":
                where, text = describe(table, row)
                details.setdefault(group, {}).setdefault(where, []).append(f"{text}: {ONLINE_IT[row['online']]}")

        print("\nRiepilogo (dischi, contando le copie)")
        for key, title in GROUPS:
            print(f"  {title}: {counts.get(key, 0)}")
        for key, title in GROUPS[1:]:
            if not details.get(key):
                continue
            print(f"\n{title[0].upper() + title[1:]}:")
            for where, texts in sorted(details[key].items()):
                print(f"  {where}: {len(texts)}")
                for t in texts[:EXAMPLES]:
                    print(f"    {t}")
                if len(texts) > EXAMPLES:
                    print(f"    ... e altre {len(texts) - EXAMPLES}")

        write_csv(out_dir / "verifica_inventario.csv",
                  ["origine", "external_id", "release_id", "quantita", "prezzo", "status", "gruppo", "online",
                   "liberabile", "verificato", "visto_online_la_prima_volta"],
                  [[describe(t, r)[0], r["external_id"], r["release_id"], r["quantita"] if t == "righe_csv" else 1,
                    f"{r['price']:.2f}", r["status"] or "FOR_SALE", dict(GROUPS)[GROUP_OF.get(r["online"], "altro")],
                    ONLINE_IT.get(r["online"], r["online"]), "sì" if can_free(t, r) else "no",
                    r["online_verificato"] or "", r["online_visto"] or ""] for t, r in rows])
        write_outputs(state, out_dir, [], [])
        print(f"\nDettaglio in {out_dir / 'verifica_inventario.csv'}")

        if not freeing:
            return
        if args.libera_solo:
            wanted = set(args.libera_solo)
            chosen = [(t, r) for t, r in rows if r["external_id"] in wanted]
            for eid in sorted(wanted - {r["external_id"] for _, r in chosen}):
                print(f"\n--libera-solo: {eid} non è nello stato (né riga CSV né annuncio API).")
        else:
            chosen = rows
        freeable = [(t, r) for t, r in chosen if can_free(t, r)]
        if args.libera_solo:
            for t, r in chosen:
                if not can_free(t, r):
                    print(f"\n--libera-solo: {r['external_id']} NON si libera: {ONLINE_IT[r['online']]}"
                          + (" (mai liberare un disco venduto)" if r["online"] in ("venduto", "forse_venduto") else ""))
        if not freeable:
            print("\nNessuna riga da liberare.")
            return
        print(f"\nRighe da liberare: {len(freeable)}. Verranno tolte dallo stato e le loro foto torneranno "
              "elaborabili al prossimo vendi.py (il riconoscimento resta):")
        for t, r in freeable[:EXAMPLES]:
            where, text = describe(t, r)
            print(f"  {where}: {text} - {ONLINE_IT[r['online']]}")
        if len(freeable) > EXAMPLES:
            print(f"  ... e altre {len(freeable) - EXAMPLES}")
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
