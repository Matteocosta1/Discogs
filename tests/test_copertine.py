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


class TestMaiUnErrore(unittest.TestCase):
    def test_distanza_che_fallisce_diventa_none(self):
        m = copertine.Matcher("vision")
        m._cache = {"a": [1.0, 0.0], "b": None, "c": "rotto"}
        self.assertIsNone(m.distance("a", "b"))
        self.assertIsNone(m.distance("a", "c"))
        self.assertAlmostEqual(copertine._vision_distance([1.0, 0.0], [0.0, 1.0]), 2 ** 0.5)
        self.assertEqual(copertine._vision_distance([0.6, 0.8], [0.6, 0.8]), 0.0)

    def test_cover_check_non_ferma_il_riconoscimento(self):
        class Broken:
            backend = "vision"

            def compare(self, *a):
                raise TypeError("float() argument must be a string or a real number, not 'NoneType'")

        check = vendi.CoverCheck(FakeStore(None, None), Broken())
        chosen, text = check.pick(["foto"], [{"id": 1}, {"id": 2}])
        self.assertIsNone(chosen)
        self.assertIn("confronto non riuscito", text)
        ok, text = check.confirms(["foto"], {"id": 1})
        self.assertFalse(ok)


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
            self.assertEqual([f.name for f in files], ["3993455-0.jpg", "3993455-1.jpg", "3993455-2.jpg"])  # max 4
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
    STRONG, DOUBT = copertine.STRONG, copertine.DOUBT


class CoverRun(TempRun):
    def setUp(self):
        super().setUp()
        FakeMatcher.distances = {}
        self.run.fake_covers = False
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

    def test_copertina_non_scioglie_una_trappola(self):
        """Caso 2: white label abbinata per il solo titolo a una release russa. Anche se la copertina
        "somiglia" resta da verificare: una busta bianca somiglia a tutte le buste bianche."""
        self.run.main(csv=False)
        self.assertIn("IMG_0002", self.run.to_check())
        FakeMatcher.distances = {("IMG_0002", 5819891): 0.10}
        self.run.main("--riprova", csv=False)
        row = self.state().execute("SELECT * FROM foto WHERE external_id = 'IMG_0002'").fetchone()
        self.assertEqual((row["esito"], row["release_id"]), ("da_verificare", 5819891))
        self.assertIn("non si può confrontare", row["motivo"])
        self.assertNotIn("supera il dubbio", row["dettagli"])

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


class TestAltreStampeDelMaster(CoverRun):
    """Il testo trova la stampa US del 2012, ma la foto dice UK 2015: l'altra versione dello stesso
    master (titolo diverso, che il testo non avrebbe trovato) entra tra i candidati e vince."""
    photos = {"VG+": ["IMG_0020"]}

    def setUp(self):
        super().setUp()
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

    def test_la_stampa_che_combacia_meglio_vince(self):
        FakeMatcher.distances = {("IMG_0020", 4207271): 0.10}   # e la copertina combacia (porta d'uscita)
        self.run.main(csv=False)
        row = self.state().execute("SELECT * FROM foto WHERE external_id = 'IMG_0020'").fetchone()
        self.assertEqual((row["esito"], row["release_id"]), ("trovato", 4207271))
        self.assertIn("anno, paese", row["candidati"])

    def test_expand_by_master_aggiunge_le_altre_versioni(self):
        """Se il testo trova solo la stampa US, l'altra versione del master entra tra i candidati."""
        import sqlite3
        con = sqlite3.connect(self.run.db)
        con.row_factory = sqlite3.Row
        self.addCleanup(con.close)
        us = vendi.dd.get_releases(con, [4207270])[0]
        ev = vendi.Evidence()
        read = tp.AI_READ["IMG_0020"]
        vendi.ai_evidence(ev, read)
        ranked = vendi.score_candidates([us], ev)
        merged = vendi.expand_by_master(con, ranked, ev, read, "")
        self.assertEqual([r["id"] for _s, r, _w in merged], [4207271, 4207270])       # UK 2015 davanti
        self.assertTrue(merged[0][1]["_master_sibling"])
        self.assertIn("altra versione dello stesso master", merged[0][2])
        self.assertEqual(vendi.expand_by_master(con, [], ev, read, ""), [])
        self.assertEqual(vendi.dd.releases_by_master(con, [777], exclude=[4207270]), [4207271])
        self.assertEqual(vendi.dd.releases_by_master(con, [None]), [])


class SearchingAPI(tp.FakeAPI):
    """Discogs che risponde alla ricerca libera (q=...) con la release di Omar-S."""
    def search(self, **params):
        self.log.append(("search", params.get("q", "")))
        if "omar" in (params.get("q") or "").lower():
            return {"results": [{"id": 807332, "title": "Omar-S - Test Omar-S EP", "label": ["FXHE Records"],
                                 "catno": "FXHE-TEST", "country": "US", "year": "2006", "format": ["Vinyl", "12\""]}]}
        return {"results": []}


class FakeGoogle:
    guesses_by_image = {}
    calls = 0

    def __init__(self, key, wallet=None):
        self.wallet = wallet
        FakeGoogle.calls = 0

    def guesses(self, image_b64):
        FakeGoogle.calls += 1
        self.wallet.spent += vendi.GOOGLE_VISION_COST
        return list(FakeGoogle.guesses_by_image.get(image_b64, []))


class TestGoogleVision(CoverRun):
    photos = {"VG+": ["IMG_0007"]}   # etichetta Omar-S: OCR nulla, l'AI non legge nulla

    def setUp(self):
        super().setUp()
        self.run.api = SearchingAPI()
        for target, value in (("vendi.GoogleVision", FakeGoogle), ("vendi.load_env_value", lambda *a: "chiave"),
                              ("vendi.env_value_or_none", lambda k: "chiave" if k == "GOOGLE_VISION_KEY" else None)):
            p = mock.patch(target, value)
            p.start()
            self.addCleanup(p.stop)
        FakeGoogle.guesses_by_image = {"IMG_0007": ["Omar-S Test Omar-S EP", "FXHE Records"]}
        FakeGoogle.calls = 0

    def test_senza_google_non_trovato(self):
        self.run.main("--senza-secondo-tentativo", "--senza-google", "--senza-gemini", csv=False)
        self.assertIn("IMG_0007", self.run.to_check())
        self.assertEqual(FakeGoogle.calls, 0)

    def test_google_propone_e_la_coerenza_conferma(self):
        FakeMatcher.distances = {("IMG_0007", 807332): 0.10}    # e la copertina combacia (porta d'uscita)
        out = self.run.main("--google-vision", "--senza-secondo-tentativo", csv=False)
        self.assertIn("Google Vision (ricerca web dell'immagine) attivo", out)
        row = self.state().execute("SELECT * FROM foto WHERE external_id = 'IMG_0007'").fetchone()
        self.assertEqual((row["esito"], row["release_id"], row["fonte"]), ("trovato", 807332, "ai+api-google"))
        self.assertIn("ipotesi di Google: Omar-S Test Omar-S EP", row["dettagli"])
        self.assertEqual(FakeGoogle.calls, 1)
        self.assertIn(("search", "Omar-S Test Omar-S EP"), self.run.api.log)
        self.assertIn("Google Vision: 1 foto inviate", out)
        self.assertNotIn("IMG_0007", self.run.to_check())

    def test_google_non_viene_chiamato_se_l_ai_trova(self):
        self.run.photos.joinpath("VG+", "IMG_0003.JPG").write_bytes(b"foto finta IMG_0003")
        self.run.main("--google-vision", "--senza-secondo-tentativo", csv=False)
        self.assertEqual(FakeGoogle.calls, 1)      # solo per IMG_0007, non per IMG_0003 (trovato in locale)

    def test_ipotesi_sbagliata_non_passa(self):
        FakeGoogle.guesses_by_image = {"IMG_0007": ["Moodymann Silentintroduction"]}
        self.run.main("--google-vision", "--senza-secondo-tentativo", csv=False)
        self.assertIn("IMG_0007", self.run.to_check())    # Discogs non trova nulla di coerente: resta fermo


if __name__ == "__main__":
    unittest.main()


class TestRetroConDiscografia(unittest.TestCase):
    """Lotto-05 disco-018, lotto-07 disco-004: sul retro sono stampati i cataloghi di altri dischi
    dell'etichetta (o un "Fusion 3" che non è un catalogo): non è un contrasto tra le foto."""

    def setUp(self):
        import sqlite3
        self._tmp = tempfile.TemporaryDirectory()
        db = Path(self._tmp.name) / "db.sqlite"
        tp.build_db(db)
        con = sqlite3.connect(db)
        for rid, title, catno in [(9050, "Altro Titolo", "SS050"), (9051, "Terzo Titolo", "SS051"),
                                  (9099, "Fusion Session", "FUSION3")]:
            label = "Sound Signature" if catno.startswith("SS") else "Fusion"
            con.execute("INSERT INTO releases VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                        (rid, title, "Theo Parrish" if label == "Sound Signature" else "Xavier", f"{label} ({catno})",
                         catno, "Vinyl, 12\"", "US", "2013", 2013, "", "", None, "Accepted", ""))
            con.execute("INSERT INTO catnos VALUES (?,?,?,?)", (rid, label, catno, vendi.dd.normalize_catno(catno)))
        con.commit()
        con.close()
        self.con = vendi.dd.open_db(db)
        self.addCleanup(self.con.close)
        self.addCleanup(self._tmp.cleanup)

    def ev(self, lines):
        e = vendi.Evidence()
        e.add_lines([(t, 0.05) for t in lines])
        return e

    def test_elenco_dell_etichetta_non_e_un_contrasto(self):
        label = self.ev(["Sound Signature", "SS049", "DANCE OF THE MEDUSA", "THEO PARRISH"])
        back = self.ev(["Sound Signature", "Also available: SS050", "SS051"])
        self.assertEqual(vendi.photos_in_contrast(self.con, [("etichetta", label), ("retro", back)], 4207270), "")

    def test_catalogo_debole_non_e_un_contrasto(self):
        label = self.ev(["Sound Signature", "SS049", "DANCE OF THE MEDUSA", "THEO PARRISH"])
        back = self.ev(["Recorded at Fusion 3", "Fusion"])
        self.assertEqual(vendi.photos_in_contrast(self.con, [("etichetta", label), ("retro", back)], 4207270), "")

    def test_contrasto_vero_resta(self):
        label = self.ev(["Sound Signature", "SS049"])
        other = self.ev(["Nature Records", "NAT2130", "FRANCISCO", "MUSIC BUSINESS"])
        self.assertIn("in contrasto", vendi.photos_in_contrast(self.con, [("a", label), ("b", other)]))

    def test_elenco_con_titolo_presente_conta(self):
        label = self.ev(["Sound Signature", "SS049", "DANCE OF THE MEDUSA"])
        back = self.ev(["Sound Signature", "SS050", "SS051", "ALTRO TITOLO"])   # il disco è proprio SS050?
        self.assertIn("in contrasto", vendi.photos_in_contrast(self.con, [("a", label), ("b", back)]))


class TestPortaDUscita(CoverRun):
    """Nessun disco va in vendita se la sua copertina non combacia con quella su Discogs."""
    photos = {"NM": ["IMG_0004"], "VG+": ["IMG_0003"]}

    def row(self, eid):
        return self.state().execute("SELECT * FROM foto WHERE external_id = ?", (eid,)).fetchone()

    def test_senza_codice_e_copertina_diversa_si_ferma(self):
        # IMG_0004: artista e titolo puliti (prima andava in vendita senza guardare la copertina)
        FakeMatcher.distances = {("IMG_0004", 3993455): 0.9}
        self.run.main(csv=False)
        row = self.row("IMG_0004")
        self.assertEqual(row["esito"], "da_verificare")
        self.assertIn(vendi.COVER_REASON, row["motivo"])
        self.assertIn("IMG_0004", self.run.to_check())

    def test_senza_codice_e_copertina_uguale_va_in_vendita(self):
        FakeMatcher.distances = {("IMG_0004", 3993455): 0.10, ("IMG_0003", 3993455): 0.10}
        self.run.main(csv=False)
        self.assertEqual(self.row("IMG_0004")["esito"], "trovato")
        self.assertNotIn("IMG_0004", self.run.to_check())

    def test_con_codice_e_copertina_chiaramente_diversa_si_ferma(self):
        # IMG_0003: trovato con il numero di catalogo, ma la copertina è un'altra
        FakeMatcher.distances = {("IMG_0004", 3993455): 0.10, ("IMG_0003", 3993455): 0.9}
        self.run.main(csv=False)
        row = self.row("IMG_0003")
        self.assertEqual(row["esito"], "da_verificare")
        self.assertIn("anche se trovato con il catno", row["motivo"])

    def test_con_codice_e_copertina_solo_poco_simile_passa(self):
        # riflessi o foto storta: zona di dubbio, il codice basta
        d = copertine.STRONG["pil"] + copertine.DOUBT["pil"] - 0.01
        FakeMatcher.distances = {("IMG_0004", 3993455): 0.10, ("IMG_0003", 3993455): d}
        self.run.main(csv=False)
        self.assertEqual(self.row("IMG_0003")["esito"], "trovato")

    def test_gemini_d_accordo_non_scavalca_la_copertina(self):
        class Gemini:
            model = "finto"

            def choose(self, images, shortlist):
                return {"release_id": 3993455, "confidence": "high", "reason": "sicuro"}, 0.0

        rec = vendi.Recognition(esito="da_verificare", release={"id": 3993455}, metodo="ai",
                                motivo=f"{vendi.COVER_REASON} (copertina (pil): distanza 0.90)", details="",
                                candidates=[(1.0, {"id": 3993455}, "")])
        with mock.patch("vendi.load_image", lambda p: p), mock.patch.object(vendi.AIVision, "prepare", lambda img: img):
            vendi.second_opinion(rec, "foto", Gemini(), {})
        self.assertEqual(rec.esito, "da_verificare")
        self.assertIn("Gemini concorda", rec.details)
        self.assertTrue(vendi.is_trap("riga della scaletta"))


class TestPrimaLeCopertine(CoverRun):
    """Regola principale: candidati locali -> confronto copertine -> AI solo se nessuna combacia."""
    photos = {"VG+": ["IMG_0021"]}

    def setUp(self):
        super().setUp()
        # Testo letto in locale: titolo e artista, nessun codice. Il dump ha due stampe (US 2012, UK 2015).
        ocr = [("THEO PARRISH", 0.06), ("DANCE OF THE MEDUSA", 0.05), ("SOUND SIGNATURE", 0.02)]
        read = {"photo_type": "front", "compilation": False, "artist": "Theo Parrish", "title": "Dance Of The Medusa",
                "label": "Sound Signature", "catno": "", "year": "2015", "country": "UK", "barcode": "",
                "readable_text": "THEO PARRISH\nDANCE OF THE MEDUSA", "recognized_artist": "",
                "recognized_title": ""}
        for target, values in ((tp.OCR, {"IMG_0021": ocr}), (tp.AI_READ, {"IMG_0021": read}),
                               (tp.AI_CHOICE, {"IMG_0021": {"release_id": 4207271, "confidence": "medium",
                                                            "reason": "UK 2015"}})):
            p = mock.patch.dict(target, values)
            p.start()
            self.addCleanup(p.stop)

    def test_copertina_decide_senza_nessuna_chiamata_ai(self):
        FakeMatcher.distances = {("IMG_0021", 4207271): 0.10}
        self.run.main(csv=False)
        row = self.state().execute("SELECT * FROM foto WHERE external_id = 'IMG_0021'").fetchone()
        self.assertEqual((row["esito"], row["release_id"]), ("trovato", 4207271))
        self.assertTrue(row["fonte"].startswith("copertina"))
        self.assertIn("prima delle AI", row["dettagli"])
        self.assertEqual([c for c in tp.FakeAI.calls if c[1] == "IMG_0021"], [])    # AI mai chiamata
        self.assertEqual(row["ai_costo"], 0)

    def test_nessuna_copertina_combacia_allora_ai(self):
        FakeMatcher.distances = {}
        self.run.main(csv=False)
        self.assertNotEqual([c for c in tp.FakeAI.calls if c[1] == "IMG_0021"], [])  # tocca all'AI
