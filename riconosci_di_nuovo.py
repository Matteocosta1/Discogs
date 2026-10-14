#!/usr/bin/env python3
"""
Riconosce DA CAPO, con lo script nuovo, i dischi online che il controllo ha segnato con la copertina
sbagliata, e ne corregge gli annunci.

  1. PROVA (default, non modifica nulla): per ogni disco DIVERSA di
     risultati/verifica_copertine_online.csv rifà tutta la cascata nuova (barcode, dump, copertine,
     AI che guarda le copertine, Opus, Gemini, porta d'uscita) ignorando il riconoscimento di allora,
     e calcola il prezzo con la regola di sempre. Scrive risultati/riconosci_di_nuovo.csv.
     Lavora su una COPIA dello stato (risultati/stato_prova.sqlite): lo stato vero non cambia.

  2. APPLICA (--applica): per ogni proposta della prova chiede conferma (s/N) e corregge
     l'annuncio esistente su Discogs: release e prezzo nuovi, tutto il resto com'era (anche lo
     stato: un annuncio in Draft resta in Draft). Poi rilegge l'annuncio per verificare.
     Prima fa un backup dello stato vero e lo aggiorna con la release giusta.

Uso (dalla cartella del progetto):
    python3 riconosci_di_nuovo.py              # prova
    python3 riconosci_di_nuovo.py --applica    # dopo aver guardato la prova
"""

import argparse
import csv
import shutil
import sqlite3
from pathlib import Path

import copertine as cm
import discogs_dump as dd
import vendi

RELEASE = "https://www.discogs.com/release/{}"
OUT = Path(vendi.OUT_DIR) / "riconosci_di_nuovo.csv"
FIELDS = ["foto", "online_disco", "online_release", "listing_id", "grado", "esito", "nuovo_disco",
          "nuovo_release", "nuovo_prezzo", "metodo", "dettagli", "costo_ai"]


def photo_files(path):
    p = Path(path or "")
    if p.is_dir():
        return sorted(f for f in p.iterdir() if f.is_file() and f.suffix.lower() in vendi.IMAGE_EXTS
                      and not f.name.startswith("."))
    return [p] if p.is_file() else []


def price_args():
    parser = argparse.ArgumentParser()
    vendi.add_price_args(parser)
    parser.add_argument("--soglia-prezzo", type=float, default=50.0)
    parser.add_argument("--soglia-collezionistico", type=int, default=4)
    return parser.parse_args([])


def prova(args):
    source = Path(vendi.OUT_DIR) / "verifica_copertine_online.csv"
    if not source.exists():
        raise SystemExit("Prima lancia: python3 verifica_copertine_online.py --ai")
    with source.open(newline="", encoding="utf-8") as fh:
        todo = [r for r in csv.DictReader(fh) if r.get("ai_verdetto") == "DIVERSA"]
    if not todo:
        raise SystemExit("Nessun disco DIVERSA nel controllo.")

    copy = Path(vendi.OUT_DIR) / "stato_prova.sqlite"
    shutil.copy2(vendi.STATE_DB, copy)          # lo stato vero non si tocca
    state = vendi.open_state(copy)
    con = sqlite3.connect(args.db)
    con.row_factory = sqlite3.Row
    api = vendi.DiscogsAPI(vendi.load_token())
    currency = api.user(api.identity()["username"]).get("curr_abbr", "")
    use_ocr = vendi.ocr_available()
    ai = vendi.AIVision("claude-haiku-4-5", args.ai_tetto, 0.0)
    ai2 = vendi.AIVision(vendi.AI_SECOND_MODEL, args.ai_tetto, 0.0, wallet=ai.wallet)
    covers = vendi.CoverCheck(cm.CoverStore(api, vendi.COVER_DIR), cm.Matcher(), ())
    covers.ai = ai2
    gemini = None
    key = vendi.env_value_or_none("GEMINI_API_KEY")
    if key:
        gemini = vendi.GeminiVision(key, vendi.GEMINI_DEFAULT, wallet=ai.wallet)
    pargs = price_args()
    print(f"Dischi da riconoscere di nuovo: {len(todo)} (copertine: {covers.matcher.backend}, "
          f"Gemini: {'sì' if gemini else 'no'}, tetto AI {args.ai_tetto:.2f} €)")

    rows = []
    for n, item in enumerate(todo, 1):
        row = state.execute("SELECT * FROM foto WHERE external_id = ?", (item["foto"],)).fetchone()
        wrong_id = int(item["release"].rsplit("/", 1)[-1])
        out = {k: "" for k in FIELDS}
        out.update(foto=item["foto"], online_disco=item["disco_online"], online_release=item["release"],
                   listing_id=item.get("listing_id", ""))
        print(f"[{n}/{len(todo)}] {item['disco_online']}")
        photos = photo_files(row["foto"] if row else "")
        if row is None or not photos:
            out.update(esito="foto non trovate")
            rows.append(out)
            print("      foto non trovate")
            continue
        media, sleeve = row["media"], row["sleeve"]
        out["grado"] = media if media == sleeve else f"{media}/{sleeve}"
        spent = ai.spent
        try:
            path = [str(p) for p in photos] if len(photos) > 1 else str(photos[0])
            rec = vendi.recognize(path, con, api, use_ocr, ai, {}, vendi.AI_MAX_PHOTOS, covers, None, gemini)
            if rec.esito != "trovato":   # secondo tentativo con Opus, come nel lotto
                rec2 = vendi.recognize(path, con, api, use_ocr, ai2, {}, vendi.AI_MAX_PHOTOS, covers, None, gemini)
                if rec2.esito == "trovato" or rec2.release is not None:
                    rec = rec2
        except vendi.BudgetReached:
            print("Tetto di spesa raggiunto: mi fermo qui.")
            break
        out["costo_ai"] = f"{ai.spent - spent:.3f}"
        out["metodo"], out["dettagli"] = rec.metodo, rec.details[-400:]
        if rec.esito != "trovato" or rec.release is None:
            out["esito"] = f"non chiuso ({rec.esito}): {rec.motivo or ''}".strip()
            print(f"      -> nessuna release sicura ({rec.esito}{': ' + rec.motivo[:90] if rec.motivo else ''})")
            rows.append(out)
            continue
        rid = rec.release["id"]
        out.update(nuovo_disco=vendi.describe_release(rec.release), nuovo_release=RELEASE.format(rid))
        if rid == wrong_id:
            out["esito"] = "stessa release di prima: da guardare a mano"
            print("      -> riconosce di nuovo la stessa release: da guardare a mano")
            rows.append(out)
            continue
        try:
            sugg, _ = vendi.get_price_suggestions(state, api, rid)
            suggestion = sugg.get(vendi.GRADES[media]) or {}
            if not suggestion.get("value"):
                raise vendi.ApiError(0, f"nessun prezzo suggerito per {media}")
            suggested = float(suggestion["value"])
            cdata, _ = vendi.get_collector_data(state, api, con, rid, currency or suggestion.get("currency", ""))
            price, _calc = vendi.compute_price(suggested, cdata, media, currency, pargs, None)
            out["nuovo_prezzo"] = f"{price:.2f}"
            out["esito"] = "proposta"
            print(f"      -> {out['nuovo_disco']}  {price:.2f} {currency}  ({rec.metodo})")
        except Exception as e:
            out["esito"] = f"release trovata ma prezzo non calcolato ({e})"
            print(f"      -> {out['nuovo_disco']}  (prezzo non calcolato: {e})")
        rows.append(out)

    with OUT.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(rows)
    ok = sum(1 for r in rows if r["esito"] == "proposta")
    print(f"\nProposte con prezzo: {ok} su {len(rows)}. Spesa AI: {ai.spent:.2f} €")
    print(f"Dettaglio: {OUT.resolve()}")
    print("Nulla è stato modificato: né lo stato vero né Discogs.")
    if ok:
        print("Per correggere gli annunci (con conferma disco per disco): python3 riconosci_di_nuovo.py --applica")


def applica(args):
    if not OUT.exists():
        raise SystemExit("Prima lancia la prova: python3 riconosci_di_nuovo.py")
    with OUT.open(newline="", encoding="utf-8") as fh:
        todo = [r for r in csv.DictReader(fh) if r["esito"] == "proposta"]
    if not todo:
        raise SystemExit("Nessuna proposta da applicare.")
    saved = vendi.backup_state(vendi.STATE_DB, vendi.BACKUPS_TO_KEEP)
    print(f"Backup dello stato: {saved}")
    state = vendi.open_state(vendi.STATE_DB)
    api = vendi.DiscogsAPI(vendi.load_token())
    # Gli annunci veri si cercano nell'inventario ATTUALE (i numeri salvati possono essere vecchi,
    # i dischi caricati con il CSV non li hanno): per external_id della foto o della riga CSV.
    print("Leggo l'inventario su Discogs...")
    inv = vendi.fetch_inventory(api, api.identity()["username"], statuses=("For Sale", "Draft"))
    kept = []
    for r in todo:
        row = state.execute("SELECT riga_csv FROM foto WHERE external_id = ?", (r["foto"],)).fetchone()
        eids = {r["foto"]} | ({row["riga_csv"]} if row and row["riga_csv"] else set())
        old_id = int(r["online_release"].rsplit("/", 1)[-1])
        found = [i for i in inv.by_listing.values()
                 if (i.get("external_id") or "") in eids or any((i.get("external_id") or "").startswith(e + "-")
                                                               for e in eids)]
        if not found:
            same = [i for i in inv.by_listing.values() if (i.get("release") or {}).get("id") == old_id]
            found = same if len(same) == 1 else []
        if not found:
            print(f"  {r['online_disco']}: non è più su Discogs, salto")
            continue
        for item in found:
            kept.append({**r, "listing_id": str(item["id"])})
    todo = kept
    if not todo:
        raise SystemExit("Nessuna delle proposte ha ancora un annuncio su Discogs.")
    done = 0
    for r in todo:
        new_id = int(r["nuovo_release"].rsplit("/", 1)[-1])
        print(f"\n{r['online_disco']}\n  ora:      {r['online_release']}\n  diventa:  {r['nuovo_disco']} "
              f"{r['nuovo_release']}  prezzo {r['nuovo_prezzo']}")
        try:
            answer = input("  Correggo questo annuncio? [s/N] ").strip().lower()
        except EOFError:
            answer = ""
        if answer not in ("s", "si", "sì", "y"):
            print("  saltato")
            continue
        try:
            listing = api.get_listing(int(r["listing_id"]))
            body = vendi.listing_edit_body(listing, release_id=new_id, price=float(r["nuovo_prezzo"]))
            api.edit_listing_fields(int(r["listing_id"]), body)
            after = api.get_listing(int(r["listing_id"]))
        except Exception as e:
            print(f"  ERRORE da Discogs: {e}\n  -> questo va corretto a mano (Delete e Sell a copy)")
            continue
        got = vendi.listing_fields(after).get("release_id")
        if got != new_id:
            print(f"  Discogs NON ha cambiato la release (resta {got}): va corretto a mano (Delete e Sell a copy)")
            continue
        state.execute("UPDATE foto SET release_id = ? WHERE external_id = ?", (new_id, r["foto"]))
        state.execute("UPDATE annunci_api SET release_id = ?, price = ? WHERE listing_id = ?",
                      (new_id, float(r["nuovo_prezzo"]), int(r["listing_id"])))
        state.commit()
        done += 1
        print("  corretto e verificato su Discogs")
    print(f"\nAnnunci corretti: {done} su {len(todo)}")


def main():
    parser = argparse.ArgumentParser(description="Riconosce di nuovo i dischi con copertina sbagliata")
    parser.add_argument("--applica", action="store_true", help="corregge gli annunci (conferma per ognuno)")
    parser.add_argument("--ai-tetto", type=float, default=3.0, help="spesa AI massima della prova (default 3 €)")
    parser.add_argument("--db", default=str(dd.DEFAULT_DB))
    args = parser.parse_args()
    applica(args) if args.applica else prova(args)


if __name__ == "__main__":
    main()
