#!/usr/bin/env python3
"""
Verifica su UN SOLO annuncio cosa succede ai suoi campi quando lo si modifica via API.

Serve a sapere se una modifica che invia solo i campi obbligatori (release,
condizione, condizione copertina, prezzo, stato: è quello che fa oggi
pubblica_bozze.py) lascia intatti gli altri campi (commenti, external_id,
posizione, peso, quantità, offerte) o li azzera.

Il prezzo e tutti i campi restano QUELLI DI ORA: l'annuncio non cambia, a meno
che Discogs non azzeri qualcosa; in quel caso lo script lo ripristina subito.

  1. legge l'annuncio e salva com'è in risultati/verifica_modifica_annuncio.json
     (se qualcosa va storto, lì trovi i valori originali);
  2. chiede conferma;
  3. prova A, modifica "minima": invia solo i campi obbligatori, rilegge e
     confronta; se qualcosa è cambiato lo ripristina reinviando tutti i campi;
  4. prova B, modifica "completa": reinvia tutti i campi attuali (il metodo che
     usa riprezza.py), rilegge e confronta;
  5. stampa il risultato da mandare a Claude.

Usa un annuncio In vendita che abbia commenti ed external_id compilati.

Esempio (il numero è nel link dell'annuncio, discogs.com/sell/item/NUMERO):
    python3 verifica_modifica_annuncio.py 1234567890
"""

import argparse
import json
from pathlib import Path

import vendi
from vendi import DiscogsAPI, changed_fields, listing_edit_body, listing_fields, load_token


def show(title, fields):
    print(f"\n{title}")
    for key in vendi.LISTING_FIELDS:
        print(f"  {key:16} {fields.get(key)!r}")


def ask(question):
    try:
        return input(f"{question} [s/N] ").strip().lower() in ("s", "si", "sì", "y", "yes")
    except EOFError:
        return False


def main():
    parser = argparse.ArgumentParser(description="Verifica su un solo annuncio che la modifica via API non azzeri campi")
    parser.add_argument("listing_id", type=int, help="numero dell'annuncio (discogs.com/sell/item/NUMERO)")
    parser.add_argument("--uscita", default=str(vendi.OUT_DIR), help="cartella dei risultati (default: risultati/)")
    args = parser.parse_args()

    api = DiscogsAPI(load_token())
    username = api.identity()["username"]
    original = api.get_listing(args.listing_id)
    seller = (original.get("seller") or {}).get("username")
    if seller and seller != username:
        raise SystemExit(f"L'annuncio {args.listing_id} è di {seller}, non tuo ({username}).")
    before = listing_fields(original)
    out = Path(args.uscita).expanduser()
    out.mkdir(parents=True, exist_ok=True)
    report_path = out / "verifica_modifica_annuncio.json"
    report = {"listing_id": args.listing_id, "originale": before, "chiavi_restituite": sorted(original)}
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")

    show(f"Annuncio {args.listing_id} com'è ora (salvato in {report_path}):", before)
    missing = [k for k in ("comments", "external_id") if not before.get(k)]
    if missing:
        print(f"\nAttenzione: l'annuncio non ha {', '.join(missing)}: la prova è più utile su un annuncio che li ha.")
    if not ask("\nProcedere con le due modifiche di prova (prezzo e campi restano quelli di ora)?"):
        print("Annullato: nessuna modifica.")
        return

    # Prova A: solo i campi obbligatori, come pubblica_bozze.py
    api.edit_listing(args.listing_id, before["release_id"], before["condition"], before.get("sleeve_condition"),
                     before["price"], before["status"])
    after_a = api.get_listing(args.listing_id)
    diff_a = changed_fields(original, after_a)
    report["prova_A_minima"] = {k: {"prima": a, "dopo": b} for k, (a, b) in diff_a.items()}
    restored = None
    if diff_a:
        api.edit_listing_fields(args.listing_id, listing_edit_body(original))
        after_fix = api.get_listing(args.listing_id)
        restored = changed_fields(original, after_fix)
        report["ripristino_ancora_diversi"] = {k: {"originale": a, "ora": b} for k, (a, b) in restored.items()}

    # Prova B: tutti i campi attuali (metodo di riprezza.py)
    current = api.get_listing(args.listing_id)
    api.edit_listing_fields(args.listing_id, listing_edit_body(current))
    after_b = api.get_listing(args.listing_id)
    diff_b = changed_fields(current, after_b)
    report["prova_B_completa"] = {k: {"prima": a, "dopo": b} for k, (a, b) in diff_b.items()}
    report["finale"] = listing_fields(after_b)
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")

    print("\n=== RISULTATO (manda a Claude da qui in giù) ===")
    if diff_a:
        print("Prova A (solo campi obbligatori): HA CAMBIATO dei campi:")
        for k, (a, b) in diff_a.items():
            print(f"  {k}: {a!r} -> {b!r}")
        print("  Ripristino: " + ("OK, tutto come prima" if not restored else
                                  "NON RIUSCITO per: " + ", ".join(restored) + " (valori originali nel file json)"))
    else:
        print("Prova A (solo campi obbligatori): nessun campo cambiato")
    if diff_b:
        print("Prova B (tutti i campi): HA CAMBIATO dei campi:")
        for k, (a, b) in diff_b.items():
            print(f"  {k}: {a!r} -> {b!r}")
    else:
        print("Prova B (tutti i campi): nessun campo cambiato")
    print(f"Chiavi restituite da Discogs: {', '.join(report['chiavi_restituite'])}")
    print(f"Dettaglio completo: {report_path}")


if __name__ == "__main__":
    main()
