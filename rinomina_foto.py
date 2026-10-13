#!/usr/bin/env python3
"""
Rinomina le foto nuove con data e ora di scatto, così due telefoni (o il
contatore dell'iPhone che ricomincia) non producono mai due foto con lo stesso
nome, cioè lo stesso external_id.

    IMG_2087.HEIC  ->  20261013_154233_IMG_2087.HEIC

  1. trova le foto nella cartella indicata e nelle sue sottocartelle (es. Dischi/VG+/...);
  2. legge la data di scatto dall'EXIF (DateTimeOriginal, anche dalle HEIC); se manca
     (foto passate da WhatsApp o simili) usa la data di modifica del file e lo segnala;
  3. NON tocca mai le foto già presenti nello stato di vendi.py (stesso nome o stesso
     contenuto): il loro nome è l'external_id di annunci già creati;
  4. salta le foto già rinominate e quelle il cui nuovo nome esiste già;
  5. mostra l'anteprima e rinomina solo dopo conferma.

Esempio:
    python3 rinomina_foto.py ~/Pictures/Dischi
"""

import argparse
import datetime as dt
import json
import re
import sqlite3
from pathlib import Path

import vendi

RENAMED_RE = re.compile(r"^\d{8}_\d{6}_")
EXAMPLES = 20


def known_photos(state_path):
    """(external_id, impronte) delle foto già nello stato di vendi.py; insiemi vuoti se non c'è ancora."""
    if not Path(state_path).exists():
        return set(), set()
    con = sqlite3.connect(f"file:{state_path}?mode=ro", uri=True)
    try:
        columns = {r[1] for r in con.execute("PRAGMA table_info(foto)")}
        if not columns:
            return set(), set()
        ids = {r[0] for r in con.execute("SELECT external_id FROM foto")}
        hashes = ({r[0] for r in con.execute("SELECT hash FROM foto WHERE hash IS NOT NULL")}
                  if "hash" in columns else set())
        if "hash_foto" in columns:  # foto dei dischi in sottocartella
            for (parts,) in con.execute("SELECT hash_foto FROM foto WHERE hash_foto IS NOT NULL"):
                hashes.update(json.loads(parts))
        return ids, hashes
    finally:
        con.close()


def plan_renames(root, state_path):
    """[(foto, nuovo percorso, data, da_exif)] e [(foto, motivo per cui resta com'è)]."""
    ids, hashes = known_photos(state_path)
    plan, skipped, targets = [], [], set()
    files = sorted(p for p in Path(root).expanduser().rglob("*")
                   if p.is_file() and p.suffix.lower() in vendi.IMAGE_EXTS
                   and not any(part.startswith(".") for part in p.relative_to(root).parts))
    for path in files:
        if RENAMED_RE.match(path.name):
            skipped.append((path, "già rinominata"))
            continue
        if path.stem in ids or vendi.file_sha256(path) in hashes:
            skipped.append((path, "già nello stato di vendi.py: il nome è l'external_id, non si tocca"))
            continue
        taken = vendi.photo_taken_at(path)
        from_exif = taken is not None
        if taken is None:
            taken = dt.datetime.fromtimestamp(path.stat().st_mtime)
        target = path.with_name(f"{taken:%Y%m%d_%H%M%S}_{path.name}")
        if target.exists() or target in targets:
            skipped.append((path, f"il nuovo nome {target.name} esiste già"))
            continue
        targets.add(target)
        plan.append((path, target, taken, from_exif))
    return plan, skipped


def main():
    parser = argparse.ArgumentParser(description="Rinomina le foto nuove con data e ora di scatto (EXIF)")
    parser.add_argument("cartella", help="cartella delle foto (anche con le sottocartelle dei gradi)")
    args = parser.parse_args()
    root = Path(args.cartella).expanduser()
    if not root.is_dir():
        raise SystemExit(f"Cartella non trovata: {root}")

    plan, skipped = plan_renames(root, vendi.STATE_DB)
    for path, reason in skipped:
        if not reason.startswith("già rinominata"):
            print(f"Resta com'è: {path.relative_to(root)} ({reason})")
    if not plan:
        print("Nessuna foto da rinominare.")
        return
    without_exif = [p for p in plan if not p[3]]
    print(f"\nFoto da rinominare: {len(plan)}")
    for path, target, _taken, from_exif in plan[:EXAMPLES]:
        print(f"  {path.relative_to(root)} -> {target.name}"
              + ("" if from_exif else "   (senza data di scatto: uso la data del file)"))
    if len(plan) > EXAMPLES:
        print(f"  ... e altre {len(plan) - EXAMPLES}")
    if without_exif:
        print(f"\nAttenzione: {len(without_exif)} foto senza data di scatto nell'EXIF (es. passate da WhatsApp): "
              "per queste uso la data di modifica del file.")
    try:
        answer = input(f"\nRinominare queste {len(plan)} foto? [s/N] ").strip().lower()
    except EOFError:
        answer = ""
    if answer not in ("s", "si", "sì", "y", "yes"):
        print("Annullato: nessuna foto è stata rinominata.")
        return
    for path, target, _taken, _from_exif in plan:
        path.rename(target)
    print(f"Rinominate {len(plan)} foto.")


if __name__ == "__main__":
    main()
