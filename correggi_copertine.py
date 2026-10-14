#!/usr/bin/env python3
"""
Cerca la release GIUSTA per i dischi online con la copertina sbagliata (quelli che
verifica_copertine_online.py --ai ha segnato DIVERSA).

Per ogni disco raccoglie i candidati:
  - quelli considerati quando il disco fu riconosciuto (stato);
  - quelli che emergono da ciò che l'AI aveva letto sulla foto (artista, titolo, etichetta, catalogo),
    cercati nel dump locale;
  - le altre stampe dello stesso disco (stesso master).
Poi confronta le foto con le loro copertine Discogs: prima Vision (gratis), poi l'AI con la vista
(Opus) sui 3 più vicini, che dice quale ha la stessa grafica.

NON modifica nulla: né lo stato né gli annunci su Discogs. Scrive le proposte in
risultati/correzioni_proposte.csv, da guardare e approvare.

Uso (dalla cartella del progetto, dopo verifica_copertine_online.py --ai):
    python3 correggi_copertine.py
    python3 correggi_copertine.py --anche-probabili     (controlla anche i PROBABILE)
"""

import argparse
import csv
import re
import sqlite3
from pathlib import Path

import copertine as cm
import discogs_dump as dd
import vendi

RELEASE = "https://www.discogs.com/release/{}"
COVER_ALL_DIR = dd.DATA_DIR / "copertine_tutte"
MAX_CANDIDATES = 15     # candidati confrontati con Vision per disco
AI_SHOWN = 3            # i più vicini mostrati all'AI


def photo_files(path):
    p = Path(path or "")
    if p.is_dir():
        return sorted(f for f in p.iterdir() if f.is_file() and f.suffix.lower() in vendi.IMAGE_EXTS
                      and not f.name.startswith("."))
    return [p] if p.is_file() else []


def candidate_ids(con, row, wrong_id):
    """Id dei candidati per un disco, senza la release sbagliata."""
    ids = [int(x) for x in re.findall(r"(?:^|\| )(\d+) ", row["candidati"] or "")]
    read = None
    if row["ai_dati"]:
        try:
            import json
            read = json.loads(row["ai_dati"])
        except ValueError:
            read = None
    if read:
        ev = vendi.Evidence()
        vendi.ai_evidence(ev, read)
        try:
            _f, rel, ranked = vendi.recognize_local(con, ev, None, False)
            ids += [r["id"] for _s, r, _w in ranked]
            if rel is not None:
                ids.append(rel["id"])
        except Exception as e:  # la ricerca è un aiuto: non deve fermare le altre
            print(f"  ricerca nel dump non riuscita ({type(e).__name__}: {e})")
    known = [i for i in dict.fromkeys(ids)]
    masters = [r.get("master_id") for r in dd.get_releases(con, known + [wrong_id]) if r.get("master_id")]
    if masters:
        ids += dd.releases_by_master(con, masters, exclude=set(known), limit=80)
    ids = [i for i in dict.fromkeys(ids) if i != wrong_id]
    releases = [r for r in dd.get_releases(con, ids) if vendi.format_allowed(r)]
    return releases


def main():
    parser = argparse.ArgumentParser(description="Proposte di correzione per i dischi con copertina sbagliata")
    parser.add_argument("--anche-probabili", action="store_true", help="controlla anche i PROBABILE")
    parser.add_argument("--ai-modello", default="claude-opus-5-5", choices=sorted(vendi.AI_MODELS))
    parser.add_argument("--ai-tetto", type=float, default=3.0, help="spesa massima in euro (default 3)")
    parser.add_argument("--db", default=str(dd.DEFAULT_DB))
    args = parser.parse_args()

    source = Path(vendi.OUT_DIR) / "verifica_copertine_online.csv"
    if not source.exists():
        raise SystemExit("Prima lancia: python3 verifica_copertine_online.py --ai")
    wanted = {"DIVERSA", "PROBABILE"} if args.anche_probabili else {"DIVERSA"}
    with source.open(newline="", encoding="utf-8") as fh:
        todo = [r for r in csv.DictReader(fh) if r.get("ai_verdetto") in wanted]
    if not todo:
        raise SystemExit("Nessun disco da correggere nel controllo (colonna ai_verdetto).")
    print(f"Dischi da correggere: {len(todo)}")

    state = sqlite3.connect(f"file:{vendi.STATE_DB}?mode=ro", uri=True)
    state.row_factory = sqlite3.Row
    con = dd.connect(args.db) if hasattr(dd, "connect") else sqlite3.connect(args.db)
    con.row_factory = sqlite3.Row
    api = vendi.DiscogsAPI(vendi.load_token())
    store = cm.CoverStore(api, COVER_ALL_DIR)
    matcher = cm.Matcher()
    ai = vendi.AIVision(args.ai_modello, args.ai_tetto, 0.0)
    print(f"Confronto: {matcher.backend} + AI ({args.ai_modello}), tetto {args.ai_tetto:.2f} €")

    out_rows = []
    for n, item in enumerate(todo, 1):
        row = state.execute("SELECT * FROM foto WHERE external_id = ?", (item["foto"],)).fetchone()
        wrong_id = int(item["release"].rsplit("/", 1)[-1])
        prefix = f"[{n}/{len(todo)}] {item['disco_online']}"
        photos = photo_files(row["foto"] if row else item.get("percorso_foto"))
        result = {"foto": item["foto"], "online_disco": item["disco_online"], "online_release": item["release"],
                  "listing_id": item.get("listing_id", ""), "proposta_disco": "", "proposta_release": "",
                  "sicurezza": "", "motivo": "", "candidati_guardati": 0}
        if row is None or not photos:
            result["motivo"] = "foto o stato non trovati"
            print(f"{prefix}: foto non trovate")
            out_rows.append(result)
            continue
        cands = candidate_ids(con, row, wrong_id)[:60]
        covers = {}
        for r in cands:
            try:
                files = store.paths(r["id"])
            except Exception:
                files = []
            if files:
                covers[r["id"]] = files
            if len(covers) >= MAX_CANDIDATES:
                break
        distances = matcher.compare([str(p) for p in photos], covers)
        near = sorted((r for r in cands if r["id"] in distances), key=lambda r: distances[r["id"]])[:AI_SHOWN]
        result["candidati_guardati"] = len(distances)
        if not near:
            result["motivo"] = "nessun candidato con immagini su Discogs"
            print(f"{prefix}: nessun candidato da confrontare")
            out_rows.append(result)
            continue
        try:
            shots = [ai.prepare_small(vendi.load_image(p)) for p in photos[:vendi.AI_MAX_PHOTOS]]
            shown = [(r, [ai.prepare_small(vendi.load_image(f)) for f in covers[r["id"]][:vendi.AI_COVER_IMAGES]])
                     for r in near]
            choice, _cost = ai.match_covers(shots, shown)
        except vendi.BudgetReached:
            print("Tetto di spesa raggiunto: mi fermo qui.")
            break
        except Exception as e:
            result["motivo"] = f"AI non riuscita ({type(e).__name__}: {e})"
            out_rows.append(result)
            continue
        chosen = next((r for r in near if r["id"] == choice.get("release_id")), None)
        if chosen:
            result.update(proposta_disco=vendi.describe_release(chosen), proposta_release=RELEASE.format(chosen["id"]),
                          sicurezza=vendi.CONFIDENCE_IT.get(choice.get("confidence"), "?"),
                          motivo=choice.get("reason", ""))
            print(f"{prefix}\n      -> {vendi.describe_release(chosen)} (sicurezza "
                  f"{result['sicurezza']}, distanza {distances[chosen['id']]:.2f})")
        else:
            result["motivo"] = "nessuno dei candidati ha la stessa grafica: " + (choice.get("reason") or "")
            print(f"{prefix}\n      -> nessuna proposta (da sistemare a mano)")
        out_rows.append(result)

    out = Path(vendi.OUT_DIR) / "correzioni_proposte.csv"
    with out.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(out_rows[0].keys()) if out_rows else ["foto"])
        w.writeheader()
        w.writerows(out_rows)
    found = sum(1 for r in out_rows if r["proposta_release"])
    sure = sum(1 for r in out_rows if r["sicurezza"] == "alta")
    print(f"\nProposte: {found} su {len(out_rows)} (sicurezza alta: {sure}). Spesa AI: {ai.spent:.2f} €")
    print(f"Dettaglio: {out.resolve()}")
    print("Nulla è stato modificato su Discogs.")


if __name__ == "__main__":
    main()
