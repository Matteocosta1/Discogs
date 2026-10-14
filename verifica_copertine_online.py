#!/usr/bin/env python3
"""
Controllo visivo dei dischi GIÀ ONLINE e di quelli PRONTI nel pannello (non ancora pubblicati): le foto
di ogni disco vengono confrontate
con TUTTE le immagini della release su Discogs (copertina, retro, etichette: fino a 8 per release),
con lo stesso motore di copertine.py (Vision di macOS).

- NON usa l'AI (costo zero), NON modifica lo stato, NON tocca gli annunci su Discogs.
- Scarica le immagini in data/copertine_tutte/ (una volta sola per release).
- Scrive risultati/verifica_copertine_online.csv, dal disco più sospetto al più sicuro.

Esiti:
  OK          una foto combacia con un'immagine della release
  DUBBIO      somiglianza bassa: da guardare
  DIVERSA     nessuna immagine somiglia: probabilmente disco sbagliato, da mettere in Draft
  SENZA_IMMAGINI la release su Discogs non ha immagini: controllo impossibile
  FOTO_MANCANTI le foto del disco non sono più nella cartella

Con --ai, per ogni disco confrontato l'AI con la vista guarda le foto accanto alle immagini Discogs
e dice se la grafica è la stessa (colonna ai_verdetto: UGUALE / PROBABILE / DIVERSA). Serve a sapere
quali dischi sono DAVVERO sbagliati e a tarare la soglia di Vision sulle vostre foto (riepilogo
finale "Taratura"). Costo: pochi centesimi a disco (default Opus, il più accurato), con un tetto.

Uso (dalla cartella del progetto):
    python3 verifica_copertine_online.py
    python3 verifica_copertine_online.py --ai
"""

import argparse
import csv
import sqlite3
from pathlib import Path

import copertine as cm
import vendi

ALL_IMAGES = 8
COVER_ALL_DIR = vendi.dd.DATA_DIR / "copertine_tutte"
DOUBT_MARGIN = {"vision": 0.15, "pil": 0.12}   # sopra la soglia "stessa copertina", fin qui è DUBBIO
RELEASE = "https://www.discogs.com/release/{}"


def photo_files(row):
    p = Path(row["foto"] or "")
    if p.is_dir():
        return sorted(f for f in p.iterdir() if f.is_file() and f.suffix.lower() in vendi.IMAGE_EXTS
                      and not f.name.startswith("."))
    return [p] if p.is_file() else []


def online_rows(state):
    published = {r["external_id"]: r for r in state.execute(
        "SELECT * FROM annunci_api WHERE stato IN ('pubblicato', 'pronto')")}
    out = []
    for f in state.execute("SELECT * FROM foto WHERE release_id IS NOT NULL ORDER BY cartella, external_id"):
        eid = f["external_id"]
        listing = published.get(eid) or next((v for k, v in published.items() if k.startswith(eid + "-")), None)
        if listing is None and not f["riga_csv"]:
            continue
        out.append((f, listing))
    return out


def ai_check(ai, photos, rid, disco, images):
    """(verdetto, motivo, costo): l'AI dice se le foto hanno la stessa grafica della release."""
    try:
        shots = [ai.prepare_small(vendi.load_image(p)) for p in photos[:vendi.AI_MAX_PHOTOS]]
        covers = [ai.prepare_small(vendi.load_image(f)) for f in images[:vendi.AI_COVER_IMAGES]]
        choice, cost = ai.match_covers(shots, [({"id": rid, "artists": disco, "title": ""}, covers)])
    except vendi.BudgetReached:
        return "TETTO", "tetto di spesa raggiunto", 0.0
    except Exception as e:
        return "ERRORE", f"{type(e).__name__}: {e}", 0.0
    if choice.get("release_id") == rid:
        verdict = "UGUALE" if choice.get("confidence") == "high" else "PROBABILE"
    else:
        verdict = "DIVERSA"
    return verdict, choice.get("reason", ""), cost


def main():
    parser = argparse.ArgumentParser(description="Controllo visivo dei dischi online e pronti")
    parser.add_argument("--ai", action="store_true", help="l'AI guarda ogni disco confrontato (taratura)")
    parser.add_argument("--ai-modello", default="claude-opus-5-5", choices=sorted(vendi.AI_MODELS))
    parser.add_argument("--ai-tetto", type=float, default=6.0, help="spesa massima in euro (default 6)")
    args = parser.parse_args()
    ai = vendi.AIVision(args.ai_modello, args.ai_tetto, 0.0) if args.ai else None
    if ai:
        print(f"AI ({args.ai_modello}) su ogni disco confrontato, tetto {args.ai_tetto:.2f} €")
    cm.MAX_IMAGES = ALL_IMAGES
    state = sqlite3.connect(f"file:{vendi.STATE_DB}?mode=ro", uri=True)
    state.row_factory = sqlite3.Row
    confirmed = {r["external_id"] for r in state.execute("SELECT external_id FROM conferme")}
    api = vendi.DiscogsAPI(vendi.load_token())
    store = cm.CoverStore(api, COVER_ALL_DIR)
    matcher = cm.Matcher()
    strong = cm.STRONG[matcher.backend]
    doubt = strong + DOUBT_MARGIN[matcher.backend]
    print(f"Confronto con il motore: {matcher.backend}")
    if matcher.backend != "vision":
        print("Attenzione: Vision non disponibile, uso il confronto semplice (meno preciso).")

    rows = online_rows(state)
    results = []
    for n, (f, listing) in enumerate(rows, 1):
        photos = photo_files(f)
        rid = f["release_id"]
        distance, n_images = None, 0
        if not photos:
            verdict = "FOTO_MANCANTI"
        else:
            try:
                images = store.paths(rid)
            except Exception as e:   # un errore su un disco non deve fermare il controllo
                print(f"  {f['external_id']}: immagini non scaricate ({e})")
                images = []
            n_images = len(images)
            if not images:
                verdict = "SENZA_IMMAGINI"
            else:
                distance = matcher.compare([str(p) for p in photos], {rid: images}).get(rid)
                if distance is None:
                    verdict = "SENZA_IMMAGINI"
                elif distance <= strong:
                    verdict = "OK"
                elif distance <= doubt:
                    verdict = "DUBBIO"
                else:
                    verdict = "DIVERSA"
        ai_verdict = ai_reason = ""
        if ai and distance is not None:
            ai_verdict, ai_reason, _c = ai_check(ai, photos, rid, f["disco"] or str(rid), images)
        mark = "" if (ai_verdict or verdict) in ("OK", "UGUALE") else "  <--"
        print(f"[{n}/{len(rows)}] {verdict:<14} {f['disco'] or rid}"
              + (f" (distanza {distance:.2f})" if distance is not None else "")
              + (f"  AI: {ai_verdict}" if ai_verdict else "") + mark)
        results.append({
            "esito": verdict,
            "ai_verdetto": ai_verdict,
            "distanza": f"{distance:.2f}" if distance is not None else "",
            "disco_online": f["disco"] or "",
            "release": RELEASE.format(rid),
            "metodo": f["metodo"] or "",
            "scelto_a_mano": "sì" if f["external_id"] in confirmed else "",
            "stato": ("in vendita" if not listing or listing["stato"] == "pubblicato" else "pronto, non pubblicato"),
            "listing_id": (listing["listing_id"] if listing else "") or "",
            "immagini_discogs": n_images,
            "foto": f["external_id"],
            "cartella": f["cartella"],
            "percorso_foto": f["foto"],
            "ai_motivo": ai_reason,
        })

    order = {"DIVERSA": 0, "DUBBIO": 1, "SENZA_IMMAGINI": 2, "FOTO_MANCANTI": 3, "OK": 4}
    ai_order = {"DIVERSA": 0, "PROBABILE": 1, "ERRORE": 2, "TETTO": 2, "": 3, "UGUALE": 4}
    results.sort(key=lambda r: (ai_order[r["ai_verdetto"]], order[r["esito"]],
                                -(float(r["distanza"]) if r["distanza"] else 0)))
    out = Path(vendi.OUT_DIR) / "verifica_copertine_online.csv"
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(results[0].keys()) if results else ["esito"])
        w.writeheader()
        w.writerows(results)

    print("\nRiepilogo (dischi online e pronti):")
    for k in ("OK", "DUBBIO", "DIVERSA", "SENZA_IMMAGINI", "FOTO_MANCANTI"):
        print(f"  {k:<15} {sum(1 for r in results if r['esito'] == k)}")
    print(f"Richieste a Discogs per le immagini: {store.calls}")
    if ai:
        print("\nSecondo l'AI (guardando le copertine):")
        for k in ("UGUALE", "PROBABILE", "DIVERSA", "ERRORE", "TETTO"):
            n_k = sum(1 for r in results if r["ai_verdetto"] == k)
            if n_k:
                print(f"  {k:<15} {n_k}")
        print(f"Spesa AI: {ai.spent:.2f} €")
        same = sorted(float(r["distanza"]) for r in results if r["ai_verdetto"] == "UGUALE")
        diff = sorted(float(r["distanza"]) for r in results if r["ai_verdetto"] == "DIVERSA")
        if same or diff:
            print("\nTaratura di Vision sulle vostre foto (distanze):")
            if same:
                print(f"  copertine UGUALI:  da {same[0]:.2f} a {same[-1]:.2f} (mediana {same[len(same) // 2]:.2f})")
            if diff:
                print(f"  copertine DIVERSE: da {diff[0]:.2f} a {diff[-1]:.2f} (mediana {diff[len(diff) // 2]:.2f})")
            print("  (mi incolli queste righe: servono a fissare la soglia giusta)")
    print(f"Dettaglio (dal più sospetto): {out.resolve()}")


if __name__ == "__main__":
    main()
