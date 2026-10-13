"""
Test degli 8 punti della revisione prima del primo lotto vero (backup, verifica
dell'inventario, --rielabora, --bozza, nomi ripetuti, scadenza delle cache,
stesso disco fotografato più volte, secondo tentativo AI).

Usano l'ambiente simulato di test_protezioni.py: niente rete, niente spesa.

    python3 -m unittest discover tests
"""

import contextlib
import io
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_protezioni as tp  # noqa: E402
from test_protezioni import Run  # noqa: E402

import verifica_inventario  # noqa: E402

vendi = tp.vendi


def run_script(run, module, *options, answer="n"):
    """Lancia verifica_inventario.py (o un altro script con main()) nell'ambiente di prova."""
    output = io.StringIO()
    with contextlib.ExitStack() as stack:
        for target, value in [("sys.argv", [module.__name__, "--uscita", str(run.out), *options]),
                              ("vendi.STATE_DB", run.tmp / "vendita_stato.sqlite"),
                              (f"{module.__name__}.load_token", lambda: "token-finto"),
                              (f"{module.__name__}.DiscogsAPI", lambda token: run.api),
                              ("builtins.input", lambda prompt="": answer)]:
            stack.enter_context(mock.patch(target, value))
        stack.enter_context(contextlib.redirect_stdout(output))
        module.main()
    return output.getvalue()


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


# --------------------------------------------------------------------------
# Punto 3: verifica_inventario.py
# --------------------------------------------------------------------------

class TestVerificaInventario(TempRun):
    """Situazione di oggi: inventario_001.csv con 2 righe DRAFT caricate su Discogs; Discogs ha messo
    in vendita una riga (IMG_0006) e scartato l'altra (IMG_0003)."""

    def setUp(self):
        super().setUp()
        self.run.main()
        state = self.state()
        state.execute("UPDATE righe_csv SET status = 'DRAFT'")  # come le righe create con il vecchio --bozza
        state.commit()
        uploaded = [r for r in self.run.inventory() if r["external_id"] == "IMG_0006"]
        self.run.api.upload_csv(uploaded)

    def rows(self):
        return {r["external_id"]: r for r in self.state().execute("SELECT * FROM righe_csv")}

    def test_online_scartate_e_status_corretto(self):
        out = run_script(self.run, verifica_inventario)
        rows = self.rows()
        self.assertEqual(rows["IMG_0006"]["online"], "in_vendita")
        self.assertEqual(rows["IMG_0006"]["status"], "FOR_SALE")   # DRAFT caricata = in vendita
        self.assertIsNotNone(rows["IMG_0006"]["online_visto"])
        self.assertEqual(rows["IMG_0003"]["online"], "assente")
        self.assertEqual(rows["IMG_0003"]["status"], "DRAFT")      # non online: resta com'era
        self.assertIn("in vendita: 1", out)
        self.assertIn("NON online", out)
        self.assertIn("inventario_001.csv: 1", out)
        self.assertIn("IMG_0003", out)
        check = self.run.read_csv("verifica_inventario.csv")
        self.assertEqual({r["external_id"]: r["online"] for r in check},
                         {"IMG_0003": "non online", "IMG_0006": "in vendita"})

    def test_libera_le_righe_mai_online(self):
        run_script(self.run, verifica_inventario, "--libera", answer="n")
        self.assertIn("IMG_0003", self.rows())                    # risposta N: niente cambia

        out = run_script(self.run, verifica_inventario, "--libera", answer="s")
        self.assertIn("Liberate 1 righe", out)
        self.assertEqual(set(self.rows()), {"IMG_0006"})
        archived = list((self.run.out / "archivio").glob("inventario_001_PRIMA_*.csv"))
        self.assertEqual(len(archived), 1)                        # il file vecchio non viene perso
        self.assertEqual([r["external_id"] for r in self.run.read_csv("inventario_001.csv")], ["IMG_0006"])

        # Al giro dopo la foto torna in un CSV nuovo, senza rifare il riconoscimento né pagare l'AI
        tp.FakeAI.reads = []
        self.run.main()
        new = self.run.read_csv("inventario_002.csv")
        self.assertEqual([r["external_id"] for r in new], ["IMG_0003"])
        self.assertEqual(tp.FakeAI.reads, [])

    def test_mai_liberare_righe_gia_viste_online(self):
        run_script(self.run, verifica_inventario)
        self.run.api.inventory = []                               # venduta o cancellata a mano
        out = run_script(self.run, verifica_inventario, "--libera", answer="s")
        rows = self.rows()
        self.assertEqual(rows["IMG_0006"]["online"], "sparito")
        self.assertIn("IMG_0006", rows)                           # resta: non torna in vendita
        self.assertIn("Erano online e ora non ci sono più", out)

    def test_inventario_non_leggibile(self):
        self.run.api.inventory_error = True
        with self.assertRaises(SystemExit) as e:
            run_script(self.run, verifica_inventario, "--libera", answer="s")
        self.assertIn("Impossibile leggere l'inventario", str(e.exception))
        self.assertEqual(set(self.rows()), {"IMG_0003", "IMG_0006"})
        self.assertIsNone(self.rows()["IMG_0006"]["online"])

    def test_campo_external_id_assente(self):
        for item in self.run.api.inventory:
            del item["external_id"]
        with self.assertRaises(SystemExit) as e:
            run_script(self.run, verifica_inventario)
        self.assertIn("external_id", str(e.exception))

    def test_tutte_le_pagine(self):
        self.run.api.page_size = 1
        for n in range(3):
            self.run.api.add_listing(f"ALTRO_{n}", 1111111, 10.0, "For Sale")
        run_script(self.run, verifica_inventario)
        self.assertEqual(self.rows()["IMG_0006"]["online"], "in_vendita")
        self.assertGreaterEqual(self.run.api.log.count(("inventory", "For Sale")), 4)


# --------------------------------------------------------------------------
# Punto 1: --rielabora non crea mai doppioni
# --------------------------------------------------------------------------

class TestRielaboraSicuro(TempRun):
    def setUp(self):
        super().setUp()
        self.run.main()
        state = self.state()
        state.execute("UPDATE righe_csv SET status = 'DRAFT'")  # righe DRAFT come quelle di inventario_003
        state.commit()
        vendi.write_outputs(state, self.run.out, [], [])
        self.csv = self.run.out / "inventario_001.csv"
        self.before = self.csv.read_text()

    def rows(self):
        return {r["external_id"]: r for r in self.state().execute("SELECT * FROM righe_csv")}

    def test_riga_draft_online_non_rielaborata(self):
        self.run.api.upload_csv(self.run.inventory())       # caricato: Discogs le ha messe in vendita
        tp.FakeAI.reads = []
        out = self.run.main("--bozza", "--rielabora")
        self.assertIn("saltate perché online", out)
        self.assertEqual(set(self.rows()), {"IMG_0003", "IMG_0006"})
        self.assertTrue(self.csv.exists())
        # stesse righe e stessi prezzi; lo status passa a FOR_SALE, com'è davvero su Discogs
        self.assertEqual(self.csv.read_text(), self.before.replace(",DRAFT", ",FOR_SALE"))
        self.assertEqual(self.run.api.listings, [])            # nessun nuovo annuncio
        self.assertEqual(self.rows()["IMG_0006"]["status"], "FOR_SALE")

    def test_inventario_non_leggibile_nessuna_riga_toccata(self):
        self.run.api.inventory_error = True
        out = self.run.main("--bozza", "--rielabora")
        self.assertIn("impossibile leggere l'inventario", out)
        self.assertEqual(set(self.rows()), {"IMG_0003", "IMG_0006"})
        self.assertEqual(self.csv.read_text(), self.before)
        self.assertEqual(self.run.api.listings, [])

    def test_riga_mai_caricata_archiviata_non_cancellata(self):
        self.run.api.add_listing("IMG_0006", 4207270, 25.0, "For Sale")  # solo IMG_0006 è online
        self.run.main("--bozza", "--rielabora")
        rows = self.rows()
        self.assertEqual(rows["IMG_0006"]["parte"], 1)   # online: intatta
        self.assertGreater(rows["IMG_0003"]["parte"], 1) # non era online: rielaborata, in un file nuovo
        archived_rows = self.state().execute("SELECT external_id FROM rielaborati WHERE tabella = 'righe_csv'")
        self.assertEqual([r[0] for r in archived_rows], ["IMG_0003"])
        archived = list((self.run.out / "archivio").glob("inventario_001_PRIMA_*.csv"))
        self.assertEqual(len(archived), 1)
        self.assertEqual(archived[0].read_text(), self.before)

    def test_parte_svuotata_va_in_archivio(self):
        self.run.main("--bozza", "--rielabora")    # inventario vuoto: niente è online
        self.assertFalse(self.csv.exists())       # nessun file nuovo con lo stesso nome
        annullato = self.run.out / "archivio" / "inventario_001_ANNULLATO.csv"
        self.assertEqual(annullato.read_text(), self.before)
        self.assertEqual(min(r["parte"] for r in self.rows().values()), 2)


if __name__ == "__main__":
    unittest.main()
