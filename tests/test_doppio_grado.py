"""
Test del doppio grado nelle cartelle: DISCO_COPERTINA (es. M_NM = disco M, copertina NM).
Ambiente simulato di test_protezioni.py: niente rete, niente spesa.

    python3 -m unittest discover tests
"""

import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_protezioni as tp  # noqa: E402
from test_lotto import TempRun, write_jpeg  # noqa: E402

vendi = tp.vendi

MINT, NEAR_MINT, VG_PLUS = vendi.GRADES["M"], vendi.GRADES["NM"], vendi.GRADES["VG+"]


class TestReadGrades(unittest.TestCase):
    def test_nomi_validi(self):
        self.assertEqual(vendi.read_grades("M_NM"), ("M", "NM"))
        self.assertEqual(vendi.read_grades("VG+"), ("VG+", "VG+"))
        self.assertEqual(vendi.read_grades("m_nm"), ("M", "NM"))         # minuscole accettate
        self.assertEqual(vendi.read_grades("NM_VG+"), ("NM", "VG+"))
        self.assertEqual(vendi.read_grades("vg+_vg"), ("VG+", "VG"))

    def test_nomi_non_validi(self):
        for name in ("M_XX", "M_NM_VG", "XX", "M_", "_NM", "", "VG+ VG"):
            self.assertIsNone(vendi.read_grades(name), name)


def grade_prices(rid):
    """Prezzo suggerito diverso per grado: M 30, NM 10, gli altri 5."""
    return {g: {"value": {MINT: 30.0, NEAR_MINT: 10.0}.get(g, 5.0), "currency": "EUR"}
            for g in vendi.GRADES.values()}


class TestDoppioGrado(TempRun):
    photos = {"M_NM": ["IMG_0006"]}      # Theo Parrish - Dance Of The Medusa, trovato per catalogo

    def test_csv_media_e_sleeve(self):
        self.run.main()
        rows = self.run.inventory()
        self.assertEqual([(r["external_id"], r["media_condition"], r["sleeve_condition"]) for r in rows],
                         [("IMG_0006", MINT, NEAR_MINT)])

    def test_grado_unico_come_oggi(self):
        self.run = tp.Run(self._tmp.name + "/b", photos={"VG+": ["IMG_0006"]})
        self.run.main()
        row = self.run.inventory()[0]
        self.assertEqual((row["media_condition"], row["sleeve_condition"]), (VG_PLUS, VG_PLUS))

    def test_minuscolo_accettato(self):
        self.run = tp.Run(self._tmp.name + "/b", photos={"m_nm": ["IMG_0006"]})
        self.run.main()
        row = self.run.inventory()[0]
        self.assertEqual((row["media_condition"], row["sleeve_condition"]), (MINT, NEAR_MINT))

    def test_nome_non_valido_errore(self):
        for name in ("M_XX", "M_NM_VG"):
            run = tp.Run(f"{self._tmp.name}/{name}", photos={name: ["IMG_0006"]})
            with self.assertRaises(SystemExit) as e:
                run.main()
            self.assertIn(f"la cartella '{name}' non è un grado valido", str(e.exception))
            self.assertIn("DISCO_COPERTINA (es. M_NM, VG+_VG, NM_VG+)", str(e.exception))
            self.assertIn("M, NM, VG+, VG, G+, G", str(e.exception))

    def test_prezzo_sul_grado_del_disco(self):
        prices = {}
        for folder in ("M_NM", "M", "NM"):
            run = tp.Run(f"{self._tmp.name}/{folder}", photos={folder: ["IMG_0006"]})
            with mock.patch.object(run.api, "price_suggestions", grade_prices):
                run.main()
            prices[folder] = run.inventory()[0]["price"]
        self.assertEqual(prices["M_NM"], prices["M"])
        self.assertNotEqual(prices["M_NM"], prices["NM"])

    def test_api_in_bozza(self):
        self.run.main("--bozza")
        self.assertEqual([(l[1], l[2]) for l in self.run.api.listings], [(MINT, NEAR_MINT)])
        published = self.run.read_csv("annunci_pubblicati_api.csv")
        self.assertEqual((published[0]["media_condition"], published[0]["sleeve_condition"]), (MINT, NEAR_MINT))

    def test_sottocartella_per_disco(self):
        folder = self.run.photos / "M_NM" / "disco-001"
        folder.mkdir()
        (folder / "IMG_0003.jpg").write_bytes(b"etichetta moodymann")
        self.run.main()
        rows = {r["release_id"]: r for r in self.run.inventory()}
        self.assertEqual((rows["3993455"]["media_condition"], rows["3993455"]["sleeve_condition"]),
                         (MINT, NEAR_MINT))
        self.assertRegex(rows["3993455"]["external_id"], r"^disco-001-[0-9a-f]{8}$")

    def test_file_di_uscita(self):
        # da_controllare: disco da 120 € riconosciuto solo per artista e titolo
        self.run = tp.Run(self._tmp.name + "/b", photos={"M_NM": ["IMG_0005"], "VG+_VG": ["IMG_0003"],
                                                        "NM_VG+": ["IMG_0006"]})
        self.run.api.blocked.add(3993455)                       # non_vendibili: IMG_0003
        self.run.main("--soglia-collezionistico", "0")          # collezionistici: IMG_0006
        check = self.run.to_check()["IMG_0005"]
        self.assertEqual((check["cartella"], check["grado"], check["grado_copertina"]), ("M_NM", "M", "NM"))
        blocked = self.run.read_csv("non_vendibili.csv")
        self.assertEqual([(r["grado"], r["grado_copertina"]) for r in blocked], [("VG+", "VG")])
        collectors = self.run.read_csv("collezionistici.csv")
        self.assertEqual([(r["external_id"], r["grado"], r["grado_copertina"]) for r in collectors],
                         [("IMG_0006", "NM", "VG+")])
        self.assertEqual([(r["media_condition"], r["sleeve_condition"]) for r in self.run.inventory()],
                         [(NEAR_MINT, VG_PLUS)])

    def test_collezionistici_versione_precedente(self):
        # righe salvate prima della colonna sleeve: la copertina è come il disco
        old = ("IMG_1", 1, "VG+", 1, "VG+/IMG_1.JPG", "disco", 5, "motivi", 10.0, None, 20.0, "EUR", "CSV", "calc")
        row = vendi.collector_csv_rows([old + (None,)])[0]
        self.assertEqual(dict(zip(vendi.COLLECTOR_HEADER, row))["grado_copertina"], "VG+")


class TestRaggruppaDoppioGrado(TempRun):
    photos = {}

    def setUp(self):
        try:
            import PIL  # noqa: F401
        except ImportError:
            self.skipTest("serve Pillow (pip install Pillow)")
        super().setUp()
        self.source = self.run.tmp / "scatti"
        self.source.mkdir()
        self.dest = self.run.tmp / "lotto-02"

    def shot(self, name, when, color):
        write_jpeg(self.source / f"{name}.jpg", color, date_time_original=f"2026:10:13 {when}")

    def test_grado_doppio(self):
        self.shot("a", "12:00:00", "red")
        self.shot("b", "12:00:05", "blue")
        self.raggruppa_grado("m_nm")
        self.assertEqual(sorted(f.name for f in (self.dest / "M_NM" / "disco-001").iterdir()), ["a.jpg", "b.jpg"])

    def test_grado_non_valido(self):
        self.shot("a", "12:00:00", "red")
        with self.assertRaises(SystemExit) as e:
            self.raggruppa_grado("M_XX")
        self.assertIn("DISCO_COPERTINA", str(e.exception))
        self.assertEqual([f.name for f in self.source.iterdir()], ["a.jpg"])

    def raggruppa_grado(self, grade):
        import contextlib
        import io
        import raggruppa_foto
        argv = ["raggruppa_foto.py", str(self.source), "--grado", grade, "--destinazione", str(self.dest)]
        with mock.patch("sys.argv", argv), mock.patch("builtins.input", lambda prompt="": "s"), \
                contextlib.redirect_stdout(io.StringIO()):
            raggruppa_foto.main()


if __name__ == "__main__":
    unittest.main()
