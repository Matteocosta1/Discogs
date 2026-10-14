"""
Test della seconda opinione di Gemini: concorda / discorda / trappole note / cache / errore di rete.
Gemini simulato: nessuna rete, nessuna spesa.

    python3 -m unittest discover tests
"""

import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_protezioni as tp  # noqa: E402
from test_lotto import TempRun  # noqa: E402

vendi = tp.vendi


class FakeGemini:
    answers = {}      # foto -> {"release_id", "confidence", "reason"} (o eccezione)
    seen = []         # foto mandate a Gemini, in tutti i lanci

    def __init__(self, key, model=vendi.GEMINI_DEFAULT, wallet=None):
        self.model, self.wallet, self.calls, self.cost = model, wallet, 0, 0.0

    def choose(self, image, candidates):
        name = "+".join(image) if isinstance(image, list) else image
        FakeGemini.seen.append(name)
        self.calls += 1
        answer = FakeGemini.answers[name]
        if isinstance(answer, Exception):
            raise answer
        assert answer["release_id"] in [c["id"] for c in candidates] + [0]
        self.cost += 0.002
        return dict(answer), 0.002


class GeminiRun(TempRun):
    photos = {"VG+": ["IMG_0020"]}

    def setUp(self):
        super().setUp()
        FakeGemini.seen, FakeGemini.answers = [], {}
        read = {"photo_type": "front", "compilation": False, "artist": "Theo Parrish", "title": "Dance Of The Medusa",
                "label": "Sound Signature", "catno": "", "year": "2015", "country": "UK", "barcode": "",
                "readable_text": "THEO PARRISH\nDANCE OF THE MEDUSA\nMade in UK 2015", "recognized_artist": "",
                "recognized_title": ""}
        for target, values in ((tp.OCR, {"IMG_0020": []}), (tp.AI_READ, {"IMG_0020": read}),
                               (tp.AI_CHOICE, {"IMG_0020": {"release_id": 4207271, "confidence": "medium",
                                                            "reason": "UK 2015"}})):
            p = mock.patch.dict(target, values)
            p.start()
            self.addCleanup(p.stop)
        for target, value in (("vendi.GeminiVision", FakeGemini),
                              ("vendi.env_value_or_none", lambda key: "chiave" if key == "GEMINI_API_KEY" else None)):
            p = mock.patch(target, value)
            p.start()
            self.addCleanup(p.stop)

    def foto(self, eid):
        return self.state().execute("SELECT * FROM foto WHERE external_id = ?", (eid,)).fetchone()


class TestGemini(GeminiRun):
    def test_concorda(self):
        FakeGemini.answers = {"IMG_0020": {"release_id": 4207271, "confidence": "high", "reason": "UK"}}
        out = self.run.main(csv=False)
        row = self.foto("IMG_0020")
        self.assertEqual((row["esito"], row["release_id"]), ("trovato", 4207271))
        self.assertIn("Gemini concorda (sicurezza alta)", row["dettagli"])
        self.assertIn("Gemini (seconda opinione): 1 dischi controllati", out)
        self.assertIn("Gemini (gemini-3-flash) come seconda opinione", out)

    def test_discorda_va_controllato(self):
        FakeGemini.answers = {"IMG_0020": {"release_id": 4207270, "confidence": "high", "reason": "US"}}
        self.run.main(csv=False)
        row = self.foto("IMG_0020")
        self.assertEqual(row["esito"], "da_verificare")
        self.assertIn("Claude e Gemini scelgono release diverse: 4207271", row["motivo"])
        self.assertEqual(self.state().execute("SELECT COUNT(*) FROM annunci_api").fetchone()[0], 0)

    def test_cache_niente_seconda_chiamata(self):
        FakeGemini.answers = {"IMG_0020": {"release_id": 4207271, "confidence": "high", "reason": "UK"}}
        self.run.main(csv=False)
        self.run.main("--riprova", csv=False)
        self.assertEqual(FakeGemini.seen, ["IMG_0020"])

    def test_gemini_giu_resta_claude(self):
        import urllib.error
        FakeGemini.answers = {"IMG_0020": urllib.error.URLError("rete")}
        self.run.main(csv=False)
        row = self.foto("IMG_0020")
        self.assertEqual((row["esito"], row["release_id"]), ("trovato", 4207271))
        self.assertIn("Gemini non ha risposto", row["dettagli"])

    def test_senza_gemini(self):
        out = self.run.main("--senza-gemini", csv=False)
        self.assertEqual(FakeGemini.seen, [])
        self.assertNotIn("Gemini", out)


class TestTrappole(GeminiRun):
    photos = {"VG+": ["IMG_0001"]}   # caso 1: l'AI sceglie Mirage leggendo la scaletta

    def test_d_accordo_sulla_scaletta_resta_da_verificare(self):
        FakeGemini.answers = {"IMG_0001": {"release_id": 1901512, "confidence": "high", "reason": "Mirage"}}
        self.run.main("--senza-secondo-tentativo", csv=False)
        row = self.foto("IMG_0001")
        self.assertEqual(row["esito"], "da_verificare")
        self.assertIn("scaletta", row["motivo"])
        self.assertIn("Gemini concorda", row["dettagli"])


class TestSchema(unittest.TestCase):
    def test_schema_gemini(self):
        g = vendi.gemini_schema(vendi.AI_CHOOSE_SCHEMA)
        self.assertEqual(g["type"], "OBJECT")
        self.assertEqual(g["properties"]["release_id"], {"type": "INTEGER"})
        self.assertEqual(g["properties"]["confidence"]["enum"], ["high", "medium", "low"])
        self.assertNotIn("additionalProperties", g)
        self.assertEqual(vendi.GEMINI_MODELS[vendi.GEMINI_DEFAULT], (0.50, 3.00))


if __name__ == "__main__":
    unittest.main()
