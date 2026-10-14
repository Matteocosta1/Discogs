"""
Test del confronto con le copertine di Discogs (copertine.py) e del suo uso nel riconoscimento.
Immagini sintetiche per il confronto vero (backend Pillow); confronto simulato nei test end-to-end.

    python3 -m unittest discover tests
"""

import json
import random
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_protezioni as tp  # noqa: E402
from test_lotto import TempRun  # noqa: E402

import copertine  # noqa: E402

vendi = tp.vendi


def synthetic_cover(seed, size=400):
    from PIL import Image, ImageDraw
    rnd = random.Random(seed)
    im = Image.new("RGB", (size, size), tuple(rnd.randint(0, 255) for _ in range(3)))
    d = ImageDraw.Draw(im)
    for _ in range(12):
        x0, y0 = rnd.randint(0, size), rnd.randint(0, size)
        d.rectangle([x0, y0, x0 + rnd.randint(40, 200), y0 + rnd.randint(40, 200)],
                    fill=tuple(rnd.randint(0, 255) for _ in range(3)))
    return im


def photo_of(cover):
    """Come una foto: tavolo intorno, copertina un po' ruotata, sfocata e con luce diversa."""
    from PIL import Image, ImageFilter
    bg = Image.new("RGB", (600, 800), (120, 118, 110))
    c = cover.resize((500, 500)).rotate(3, expand=True, fillcolor=(120, 118, 110)).filter(ImageFilter.GaussianBlur(1.2))
    c = c.point(lambda v: min(255, int(v * 0.92 + 8)))
    bg.paste(c, (30, 130))
    return bg


class TestMatcherPillow(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.covers = {}
        for i in range(6):
            path = self.dir / f"c{i}.jpg"
            synthetic_cover(i).save(path)
            self.covers[i] = [str(path)]
        photo_of(synthetic_cover(3)).save(self.dir / "foto.jpg")
        self.matcher = copertine.Matcher("pil")

    def tearDown(self):
        self._tmp.cleanup()

    def test_riconosce_la_copertina_giusta(self):
        d = self.matcher.compare([str(self.dir / "foto.jpg")], self.covers)
        chosen, text = self.matcher.verdict(d)
        self.assertEqual(chosen, 3)
        self.assertIn("copertina riconosciuta: release 3", text)
        self.assertTrue(self.matcher.strong(d[3]))
        self.assertFalse(any(self.matcher.strong(v) for k, v in d.items() if k != 3))

    def test_foto_non_apribile(self):
        (self.dir / "rotta.jpg").write_bytes(b"non sono una foto")
        self.assertEqual(self.matcher.compare([str(self.dir / "rotta.jpg")], self.covers), {})
        self.assertEqual(self.matcher.verdict({}), (None, "copertine: nessun confronto possibile"))

    def test_candidati_troppo_simili(self):
        d = {1: 0.10, 2: 0.12}
        self.assertEqual(self.matcher.verdict(d)[0], None)
        self.assertIn("troppo simili", self.matcher.verdict(d)[1])


class FakeDownloadAPI(tp.FakeAPI):
    """Discogs con le immagini delle release: GET /releases/{id} ha 'images', download() le restituisce."""
    images = {}   # release_id -> [bytes]

    def release(self, rid):
        data = super().release(rid)
        data["images"] = [{"type": "primary" if n == 0 else "secondary", "uri": f"https://img/{rid}/{n}.jpg"}
                          for n in range(len(self.images.get(rid, [])))]
        return data

    def download(self, url):
        self.log.append(("download", url))
        _, rid, name = url.rsplit("/", 2)
        return self.images[int(rid)][int(name.split(".")[0])]


class TestCoverStore(unittest.TestCase):
    def test_scarica_una_volta_sola(self):
        with tempfile.TemporaryDirectory() as tmp:
            api = FakeDownloadAPI()
            api.images = {3993455: [b"img-a", b"img-b", b"img-c"], 4207270: []}
            store = copertine.CoverStore(api, Path(tmp) / "cop")
            files = store.paths(3993455)
            self.assertEqual([f.name for f in files], ["3993455-0.jpg", "3993455-1.jpg"])   # al massimo 2
            self.assertEqual(files[0].read_bytes(), b"img-a")
            n = len(api.log)
            self.assertEqual(store.paths(3993455), files)                                   # dalla cache
            self.assertEqual(len(api.log), n)
            self.assertEqual(store.paths(4207270), [])                                      # senza immagini
            self.assertEqual(store.paths(4207270), [])
            self.assertEqual(sum(1 for l in api.log if l == ("release", 4207270)), 1)       # chiesto una volta
            self.assertEqual(store.paths(807332, release={"images": []}), [])             # dati già in mano
            self.assertNotIn(("release", 807332), api.log)


# --------------------------------------------------------------------------
# Nel riconoscimento: confronto simulato (le foto dei test non sono immagini)
# --------------------------------------------------------------------------

class FakeStore:
    def __init__(self, api, folder):
        self.api, self.calls = api, 0

    def paths(self, rid, release=None):
        return [f"cover-{rid}"]


class FakeMatcher:
    """distanze[(foto, release_id)] = distanza; quello che manca = 1.0 (diversa)."""
    distances = {}
    backend = "pil"

    def __init__(self, backend=None):
        pass

    def compare(self, photos, covers_by_id):
        out = {}
        for rid in covers_by_id:
            best = min(FakeMatcher.distances.get((Path(p).stem, rid), 1.0) for p in photos)
            out[rid] = best
        return out

    def strong(self, d):
        return d is not None and d <= copertine.STRONG["pil"]

    def verdict(self, distances):
        return copertine.Matcher.verdict(self, distances)


class FakeCopertine:
    CoverStore, Matcher, MAX_CANDIDATES = FakeStore, FakeMatcher, 6


class CoverRun(TempRun):
    def setUp(self):
        super().setUp()
        FakeMatcher.distances = {}
        p = mock.patch("vendi.copertine_module", lambda: FakeCopertine)
        p.start()
        self.addCleanup(p.stop)


class TestCopertineNelRiconoscimento(CoverRun):
    photos = {"VG+": ["IMG_0001", "IMG_0002"]}

    def test_la_copertina_decide_senza_seconda_chiamata_ai(self):
        """Caso 1: l'AI legge la scaletta e sceglierebbe Mirage; la copertina dice Black Jazz Signature."""
        FakeMatcher.distances = {("IMG_0001", 5206239): 0.15}
        out = self.run.main(csv=False)
        row = self.state().execute("SELECT * FROM foto WHERE external_id = 'IMG_0001'").fetchone()
        self.assertEqual((row["esito"], row["release_id"], row["metodo"]), ("trovato", 5206239, "copertina"))
        self.assertIn("copertina riconosciuta: release 5206239", row["dettagli"])
        self.assertEqual([c for c in tp.FakeAI.calls if c[1] == "IMG_0001"], [("claude-haiku-4-5", "IMG_0001")])
        self.assertIn("pronto da pubblicare (IMG_0001)", out)

    def test_copertina_diversa_lascia_decidere_l_ai(self):
        FakeMatcher.distances = {("IMG_0001", 5206239): 0.9, ("IMG_0001", 1901512): 0.8}
        self.run.main(csv=False)
        row = self.state().execute("SELECT * FROM foto WHERE external_id = 'IMG_0001'").fetchone()
        self.assertEqual((row["esito"], row["release_id"]), ("da_verificare", 1901512))   # come prima
        self.assertIn("nessuna copertina riconosciuta", row["dettagli"])

    def test_copertina_conferma_un_riconoscimento_dubbio(self):
        """Caso 2: white label abbinata per il solo titolo a una release russa: da verificare... a meno
        che la copertina non sia proprio quella."""
        self.run.main(csv=False)
        self.assertIn("IMG_0002", self.run.to_check())
        FakeMatcher.distances = {("IMG_0002", 5819891): 0.10}
        self.run.main("--riprova", csv=False)
        row = self.state().execute("SELECT * FROM foto WHERE external_id = 'IMG_0002'").fetchone()
        self.assertEqual((row["esito"], row["release_id"]), ("trovato", 5819891))
        self.assertIn("supera il dubbio", row["dettagli"])

    def test_release_confermata_in_passato_non_si_verifica(self):
        self.run.main(csv=False)
        self.assertIn("IMG_0002", self.run.to_check())
        con = self.state()
        con.execute("INSERT INTO conferme VALUES ('vecchio', 5819891, '', '', '', '')")
        con.commit()
        out = self.run.main("--riprova", csv=False)
        self.assertIn("1 release già confermate a mano", out)
        row = self.state().execute("SELECT * FROM foto WHERE external_id = 'IMG_0002'").fetchone()
        self.assertEqual(row["esito"], "trovato")
        self.assertIn("già confermata a mano", row["dettagli"])

    def test_senza_copertine(self):
        FakeMatcher.distances = {("IMG_0001", 5206239): 0.15}
        out = self.run.main("--senza-copertine", csv=False)
        self.assertNotIn("Confronto delle copertine", out)
        row = self.state().execute("SELECT * FROM foto WHERE external_id = 'IMG_0001'").fetchone()
        self.assertEqual(row["esito"], "da_verificare")


if __name__ == "__main__":
    unittest.main()
