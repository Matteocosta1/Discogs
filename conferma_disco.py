#!/usr/bin/env python3
"""
Pulsante Conferma del pannello: UN disco controllato a mano va subito in vendita su Discogs.

  1. lo abbina alla release proposta (vendi.py --abbina);
  2. lo prezza con la regola di sempre (vendi.py sulla cartella del lotto, senza AI);
  3. pubblica SOLO il suo annuncio.

Uso: python3 conferma_disco.py DISCO RELEASE      (es. disco-007 24344624)
"""

import sqlite3
import subprocess
import sys
from pathlib import Path

import vendi


def run_vendi(args):
    subprocess.run([sys.executable, str(Path(__file__).with_name("vendi.py")), *args], check=False)


def publish_one(state, api, eid):
    """Pubblica gli annunci pronti di questo disco (e delle sue copie). Restituisce quanti."""
    rows = state.execute("SELECT * FROM annunci_api WHERE stato = 'pronto' AND (external_id = ? OR external_id LIKE ?)",
                         (eid, eid + "-copia%")).fetchall()
    stats = {"api": 0, "problemi": 0}
    for r in rows:
        vendi.send_listing(state, api, r, stats, f"{eid}: {r['price']:.2f}")
    return stats["api"]


def main():
    if len(sys.argv) != 3 or not sys.argv[2].isdigit():
        raise SystemExit("Uso: python3 conferma_disco.py DISCO RELEASE")
    eid, rid = sys.argv[1], sys.argv[2]
    con = sqlite3.connect(vendi.STATE_DB)
    con.row_factory = sqlite3.Row
    row = con.execute("SELECT foto FROM foto WHERE external_id = ?", (eid,)).fetchone()
    con.close()
    if row is None:
        raise SystemExit(f"Disco {eid} non trovato.")
    lot = Path(row["foto"]).parent.parent
    run_vendi(["--abbina", f"{eid}={rid}", str(lot), "--senza-ai", "--senza-pannello", "--si"])
    state = vendi.open_state(vendi.STATE_DB)
    try:
        done = publish_one(state, vendi.DiscogsAPI(vendi.load_token()), eid)
        if done:
            print(f"\nFATTO: {eid} è in vendita su Discogs.")
        else:
            f = state.execute("SELECT esito, motivo FROM foto WHERE external_id = ?", (eid,)).fetchone()
            print(f"\nNON pubblicato: {eid} è '{f['esito']}'" + (f" ({f['motivo']})" if f["motivo"] else ""))
        vendi.write_outputs(state, vendi.OUT_DIR, [], [])
    finally:
        state.close()


if __name__ == "__main__":
    main()
