"""
Test degli 8 punti della revisione prima del primo lotto vero (backup, verifica
dell'inventario, --rielabora, --bozza, nomi ripetuti, scadenza delle cache,
stesso disco fotografato più volte, secondo tentativo AI).

Usano l'ambiente simulato di test_protezioni.py: niente rete, niente spesa.

    python3 -m unittest discover tests
"""

import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_protezioni as tp  # noqa: E402
from test_protezioni import Run  # noqa: E402

vendi = tp.vendi


class TempRun(unittest.TestCase):
    """Base: un ambiente di prova nuovo per ogni test."""
    photos = {"VG+": ["IMG_0003", "IMG_0006"]}

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.run = Run(self._tmp.name, photos=self.photos)
        tp.FakeAI.reads = []

    def tearDown(self):
        self._tmp.cleanup()

    def state(self):
        con = sqlite3.connect(self.run.tmp / "vendita_stato.sqlite")
        con.row_factory = sqlite3.Row
        self.addCleanup(con.close)
        return con


# --------------------------------------------------------------------------
# Punto 7: backup automatico dello stato
# --------------------------------------------------------------------------

class TestBackup(TempRun):
    def backups(self):
        return sorted((self.run.tmp / "backup").glob("vendita_stato_*.sqlite"))

    def test_backup_a_ogni_lancio(self):
        self.run.main()
        self.assertEqual(self.backups(), [])  # primo lancio: lo stato non esisteva ancora
        self.run.main()
        copies = self.backups()
        self.assertEqual(len(copies), 1)
        con = sqlite3.connect(copies[0])
        self.addCleanup(con.close)
        self.assertGreater(con.execute("SELECT COUNT(*) FROM foto").fetchone()[0], 0)  # copia completa

    def test_nessun_backup_in_simulazione(self):
        self.run.main()
        self.run.main("--simula")
        self.assertEqual(self.backups(), [])

    def test_tiene_solo_le_ultime(self):
        self.run.main()
        state = self.run.tmp / "vendita_stato.sqlite"
        for _ in range(7):
            vendi.backup_state(state, keep=5)
            time.sleep(0.01)
        copies = self.backups()
        self.assertEqual(len(copies), 5)
        self.run.main("--backup-da-tenere", "3")
        self.assertEqual(len(self.backups()), 3)


if __name__ == "__main__":
    unittest.main()
