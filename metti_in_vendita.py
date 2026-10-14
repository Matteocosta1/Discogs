#!/usr/bin/env python3
"""
Mette in vendita su Discogs i dischi confermati a mano nel pannello (pulsante Conferma) e tutti gli
altri annunci pronti.

  1. Trova i dischi confermati che non hanno ancora un prezzo né un annuncio.
  2. Per ogni lotto che li contiene lancia vendi.py sulla cartella del lotto, SENZA AI (le foto già
     elaborate non vengono rifatte): i confermati vengono prezzati e diventano "pronti".
  3. Lancia vendi.py --pubblica: tutti gli annunci pronti vanno in vendita.

È il comando dietro il pulsante "Pubblica su Discogs" del pannello. Uso a mano:
    python3 metti_in_vendita.py
"""

import sqlite3
import subprocess
import sys
from pathlib import Path

import vendi

WAITING_SQL = """
    SELECT * FROM foto f
    WHERE f.esito = 'trovato' AND f.fonte = 'manuale' AND COALESCE(f.riga_csv, '') = ''
      AND NOT EXISTS (SELECT 1 FROM annunci_api a
                      WHERE a.external_id = f.external_id OR a.external_id LIKE f.external_id || '-copia%')
"""


def waiting(state):
    """Dischi confermati a mano che aspettano prezzo e annuncio."""
    return state.execute(WAITING_SQL).fetchall()


def lot_folder(path_text):
    return Path(path_text).parent.parent if path_text else None


def main():
    state = sqlite3.connect(f"file:{vendi.STATE_DB}?mode=ro", uri=True)
    state.row_factory = sqlite3.Row
    rows = waiting(state)
    state.close()
    folders = []
    for r in rows:
        f = lot_folder(r["foto"])
        if f is not None and f.is_dir() and f not in folders:
            folders.append(f)
    print(f"Dischi confermati a mano da prezzare: {len(rows)}", flush=True)
    vendi_py = [sys.executable, str(Path(__file__).with_name("vendi.py"))]
    for folder in folders:
        print(f"\n== Prezzo i confermati del lotto {folder.name} ==", flush=True)
        subprocess.run(vendi_py + [str(folder), "--senza-ai", "--senza-pannello", "--si"], check=False)
    print("\n== Pubblico su Discogs tutti gli annunci pronti ==", flush=True)
    done = subprocess.run(vendi_py + ["--pubblica", "--senza-pannello"], check=False)
    sys.exit(done.returncode)


if __name__ == "__main__":
    main()
