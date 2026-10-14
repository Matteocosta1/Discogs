"""
Test del flusso nuovo: i dischi riconosciuti restano "pronti" (si guardano nel pannello) e vanno
online solo con --pubblica; --abbina per il riconoscimento a mano. Ambiente simulato di
test_protezioni.py: niente rete, niente spesa.

    python3 -m unittest discover tests
"""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_protezioni as tp  # noqa: E402
from test_lotto import TempRun, run_script  # noqa: E402

import verifica_inventario  # noqa: E402

vendi = tp.vendi


class TestPronti(TempRun):
    photos = {"VG+": ["IMG_0003"], "NM": ["IMG_0004"]}   # due dischi trovati in locale

    def annunci(self):
        return {r["external_id"]: r for r in self.state().execute("SELECT * FROM annunci_api")}

    def test_senza_pubblica_restano_pronti(self):
        out = self.run.main(csv=False)
        self.assertEqual(self.run.inventory(), [])                      # niente CSV
        self.assertEqual(self.run.api.listings, [])                     # niente online
        rows = self.annunci()
        self.assertEqual({r["stato"] for r in rows.values()}, {"pronto"})
        self.assertEqual(set(rows), {"IMG_0003", "IMG_0004"})
        self.assertIn("pronti da pubblicare:        2 nuovi, 2 in attesa in tutto", out)
        self.assertIn("python vendi.py --pubblica", out)
        reg = self.run.read_csv("registro.csv")
        self.assertEqual({(r["file"], r["online"]) for r in reg}, {("API (da pubblicare)", "da_pubblicare")})
        page = (self.run.out / "pannello.html").read_text(encoding="utf-8")
        data = json.loads(page.split("const DATA = ", 1)[1].split(";\n", 1)[0].replace("<\\/", "</"))
        self.assertEqual([(d["online"], d["pronto"], d["nascosto"]) for d in data["vendita"]],
                         [("Da pubblicare", True, False)] * 2)

    def test_secondo_lancio_non_duplica(self):
        self.run.main(csv=False)
        out = self.run.main(csv=False)
        self.assertEqual(len(self.annunci()), 2)
        self.assertIn("foto già in vendita:         2", out)

    def test_pubblica_da_solo(self):
        self.run.main(csv=False)
        out = self.run.main("--pubblica", csv=False, folder=False)
        self.assertEqual(len(self.run.api.listings), 2)
        self.assertEqual({r["stato"] for r in self.annunci().values()}, {"pubblicato"})
        self.assertIn("Pubblicati: 2", out)
        self.assertEqual([r["external_id"] for r in self.run.read_csv("annunci_pubblicati_api.csv")],
                         ["IMG_0003", "IMG_0004"])
        out = self.run.main("--pubblica", csv=False, folder=False)      # niente doppioni
        self.assertEqual(len(self.run.api.listings), 2)
        self.assertIn("Niente da pubblicare", out)

    def test_pubblica_insieme_alla_cartella(self):
        out = self.run.main("--pubblica", csv=False)
        self.assertEqual(len(self.run.api.listings), 2)
        self.assertIn("di cui 2 con --pubblica", out)
        self.assertEqual({r["stato"] for r in self.annunci().values()}, {"pubblicato"})

    def test_verifica_ignora_i_pronti(self):
        self.run.main(csv=False)
        run_script(self.run, verifica_inventario)
        self.assertEqual({r["online"] for r in self.annunci().values()}, {None})

    def test_togli_un_pronto(self):
        self.run.main(csv=False)
        out = self.run.main("--togli", "IMG_0004", csv=False, folder=False)
        self.assertIn("Tolto: IMG_0004", out)
        self.assertEqual(set(self.annunci()), {"IMG_0003"})
        self.run.main("--pubblica", csv=False, folder=False)
        self.assertEqual([l[4] for l in self.run.api.listings], ["IMG_0003"])

    def test_togli_un_pubblicato_si_rifiuta(self):
        self.run.main("--pubblica", csv=False)
        with self.assertRaises(SystemExit) as e:
            self.run.main("--togli", "IMG_0004", csv=False, folder=False)
        self.assertIn("toglilo da Discogs", str(e.exception))

    def test_rielabora_libera_i_pronti(self):
        self.run.main(csv=False)
        out = self.run.main("--rielabora", "--bozza", csv=False)
        self.assertIn("2 foto verranno rielaborate", out)

    def test_csv_come_prima(self):
        self.run.main()                                                 # --csv
        self.assertEqual(len(self.run.inventory()), 2)
        self.assertEqual(self.annunci(), {})


class TestAbbina(TempRun):
    photos = {"VG+": ["IMG_0001"]}   # caso 1: l'AI sbaglia, il disco resta da verificare

    def test_abbina_e_poi_pronto(self):
        self.run.main(csv=False)
        self.assertIn("IMG_0001", self.run.to_check())
        out = self.run.main("--abbina", "IMG_0001=5206239", csv=False, folder=False)
        self.assertIn("Abbinato: IMG_0001 -> Theo Parrish - Theo Parrish's Black Jazz Signature", out)
        row = self.state().execute("SELECT * FROM foto WHERE external_id = 'IMG_0001'").fetchone()
        self.assertEqual((row["esito"], row["fonte"], row["metodo"], row["release_id"]),
                         ("trovato", "manuale", "manuale", 5206239))
        conf = self.state().execute("SELECT * FROM conferme").fetchone()
        self.assertEqual((conf["external_id"], conf["release_id"]), ("IMG_0001", 5206239))
        self.assertNotIn("IMG_0001", self.run.to_check())
        tp.FakeAI.calls = []
        out = self.run.main(csv=False)                                  # prezzato, pronto, niente AI
        self.assertIn("pronto da pubblicare (IMG_0001)", out)
        ann = self.state().execute("SELECT * FROM annunci_api WHERE external_id = 'IMG_0001'").fetchone()
        self.assertEqual((ann["stato"], ann["release_id"], ann["price"]), ("pronto", 5206239, 27.5))
        self.assertEqual(tp.FakeAI.calls, [])

    def test_abbina_release_non_vinile_si_rifiuta(self):
        self.run.main(csv=False)
        with self.assertRaises(SystemExit) as e:
            self.run.main("--abbina", "IMG_0001=568083", csv=False, folder=False)
        self.assertIn("formati ammessi", str(e.exception))

    def test_abbina_formato_sbagliato(self):
        self.run.main(csv=False)
        with self.assertRaises(SystemExit) as e:
            self.run.main("--abbina", "IMG_0001", csv=False, folder=False)
        self.assertIn("disco=numero", str(e.exception))

    def test_senza_cartella_ne_opzioni(self):
        with self.assertRaises(SystemExit):
            self.run.main(csv=False, folder=False)


if __name__ == "__main__":
    unittest.main()
