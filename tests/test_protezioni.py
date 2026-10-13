"""
Test delle protezioni contro i riconoscimenti sbagliati di vendi.py.

Fanno girare vendi.py dall'inizio alla fine su foto finte, con un piccolo
database locale e con Discogs, OCR e AI simulati (nessuna rete, nessuna spesa):
il testo "letto" in ogni foto e le risposte dell'AI sono scritti qui sotto.
I dati delle release sono semplificati: servono solo al test.

    python3 -m unittest discover tests
"""

import contextlib
import csv
import io
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import discogs_dump as dd  # noqa: E402
import pubblica_bozze  # noqa: E402
import vendi  # noqa: E402

# id, artista, titolo, etichetta, catno, paese, anno, formati
RELEASES = [
    (1901512, "The Awakening", "Mirage", "Black Jazz Records", "BJQD/15", "US", 1973, "Vinyl, LP, Album"),
    (5206239, "Theo Parrish", "Theo Parrish's Black Jazz Signature", "Snow Dog Records", "SDLP-TEST", "Japan", 2013,
     "Vinyl, LP, Compilation"),
    (5819891, "Чертово Колесо Инженера Ферриса", "Wanna Ride?", "Test Label RU", "RU-001", "Russia", 2010,
     "Vinyl, 12\""),
    (473428, "Various", "FXHE-Compulation-#1", "FXHE Records", "FXHE-COMP1", "US", 2005, "Vinyl, LP, Compilation"),
    (3993455, "Moodymann", "Picture This Sampler 3", "Picture This", "THIS003", "US", 2012, "Vinyl, 12\", Sampler"),
    (1111111, "Moodymann", "Silentintroduction", "Planet E", "PE-TEST", "US", 1997, "Vinyl, LP, Album"),
]

# Prezzo suggerito (uguale per tutti i gradi) e dati del marketplace di ogni release.
MARKET = {
    1901512: (120.0, {"want": 50, "have": 100}, {"num_for_sale": 0}),           # 240 €, collezionistico
    5206239: (13.0, {"want": 10, "have": 100}, {"num_for_sale": 12, "lowest_price": {"value": 26.0}}),
    5819891: (15.0, {"want": 1, "have": 5}, {"num_for_sale": 3, "lowest_price": {"value": 15.0}}),
    473428: (20.0, {"want": 5, "have": 50}, {"num_for_sale": 8, "lowest_price": {"value": 20.0}}),
    3993455: (20.0, {"want": 30, "have": 100}, {"num_for_sale": 10, "lowest_price": {"value": 18.0}}),
    1111111: (80.0, {"want": 10, "have": 100}, {"num_for_sale": 2, "lowest_price": {"value": 80.0}}),  # 120 €
}

# Foto: cartella/nome -> righe lette dall'OCR (testo, altezza). [] = OCR senza testo utile.
OCR = {
    # Caso 1: retro della compilation di Theo Parrish; l'OCR non legge nulla di utile, decide l'AI.
    "IMG_0001": [],
    # Caso 2: white label con scritto solo questo.
    "IMG_0002": [("BITCH WANNA RIDE MY DICK", 0.08), ("33 RPM", 0.01)],
    # Match pulito per catalogo: etichetta Moodymann.
    "IMG_0003": [("MOODYMANN", 0.06), ("PICTURE THIS SAMPLER 3", 0.05), ("THIS003", 0.012),
                 ("Picture This", 0.02), ("Side A", 0.01)],
    # Match pulito per artista e titolo (senza catalogo leggibile).
    "IMG_0004": [("MOODYMANN", 0.06), ("PICTURE THIS SAMPLER 3", 0.05)],
    # Match pulito per artista e titolo, ma il disco vale 120 €: rete di sicurezza sul prezzo.
    "IMG_0005": [("MOODYMANN", 0.06), ("SILENTINTRODUCTION", 0.05)],
}

# Caso 1: cosa ha "letto" l'AI sbagliando (prende artista, titolo e catno dalla scaletta)
# e la sua scelta, con sicurezza alta, della release sbagliata.
AI_READ = {
    "IMG_0001": {
        "photo_type": "back", "compilation": False, "artist": "The Awakening", "title": "Mirage",
        "label": "Black Jazz", "catno": "BJQD/15", "year": "1973", "country": "", "barcode": "",
        "readable_text": "THEO PARRISH'S BLACK JAZZ SIGNATURE\n"
                         "A1. Artista Uno - Brano Uno\n"
                         "B1. Artista Due - Brano Due\n"
                         "C2. The Awakening - Mirage, From the album 'Mirage' BJQD/15 [1973]\n"
                         "D1. Artista Tre - Brano Tre\n"
                         "Black Jazz Records\nSnow Dog Records",
        "recognized_artist": "", "recognized_title": "",
    },
}
AI_CHOICE = {"IMG_0001": {"release_id": 1901512, "confidence": "high", "reason": "The Awakening - Mirage, BJQD/15"}}

PHOTOS = {"VG+": ["IMG_0001", "IMG_0002", "IMG_0003", "IMG_0005"], "NM": ["IMG_0004"]}


def build_db(path):
    con = sqlite3.connect(path)
    con.executescript(dd.SCHEMA)
    con.executescript(dd.INDEXES)
    con.create_function("norm_text", 1, dd.normalize_text)
    con.executescript(dd.FTS_SCHEMA)
    for rid, artist, title, label, catno, country, year, formats in RELEASES:
        con.execute("INSERT INTO releases VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (rid, title, artist, f"{label} ({catno})", catno, formats, country, str(year), year,
                     "", "", None, "Accepted", ""))
        con.execute("INSERT INTO catnos VALUES (?,?,?,?)", (rid, label, catno, dd.normalize_catno(catno)))
    con.execute("INSERT INTO releases_fts (rowid, artists, title) "
                "SELECT id, norm_text(artists), norm_text(title) FROM releases")
    con.execute("INSERT INTO meta VALUES ('schema_version', ?)", (str(dd.SCHEMA_VERSION),))
    con.commit()
    con.close()


class FakeAPI:
    MIN_INTERVAL = 0

    def __init__(self, token=None):
        self.calls = 0
        self.listings = []

    def identity(self):
        return {"username": "test"}

    def user(self, username):
        return {"curr_abbr": "EUR"}

    def search(self, **params):
        return {"results": []}

    def price_suggestions(self, rid):
        value = MARKET[rid][0]
        return {grade: {"value": value, "currency": "EUR"} for grade in vendi.GRADES.values()}

    def release(self, rid):
        return {"community": MARKET[rid][1]}

    def marketplace_stats(self, rid, currency):
        stats = dict(MARKET[rid][2])
        if "lowest_price" in stats:
            stats["lowest_price"] = {**stats["lowest_price"], "currency": "EUR"}
        return stats

    def create_listing(self, *args, **kwargs):
        self.listings.append(args)
        return {"listing_id": len(self.listings)}

    def inventory_page(self, *args, **kwargs):
        return {"listings": [], "pagination": {"pages": 1}}


class FakeAI:
    """Al posto di vendi.AIVision: risposte scritte sopra, costo finto di 0,01 € a chiamata."""
    reads = []

    def __init__(self, model, budget, spent):
        self.spent = spent

    @staticmethod
    def prepare(img):
        return img  # il nome della foto, al posto dell'immagine da inviare

    def read(self, image):
        FakeAI.reads.append(image)
        self.spent += 0.01
        return dict(AI_READ.get(image, {})), 0.01

    def choose(self, image, candidates):
        self.spent += 0.01
        assert AI_CHOICE[image]["release_id"] in [c["id"] for c in candidates]
        return dict(AI_CHOICE[image]), 0.01


class Run:
    """Ambiente di prova: cartella delle foto, database, stato e risultati in una cartella temporanea."""

    def __init__(self, tmp):
        self.tmp = Path(tmp)
        self.photos = self.tmp / "Dischi"
        for grade, names in PHOTOS.items():
            (self.photos / grade).mkdir(parents=True)
            for name in names:
                (self.photos / grade / f"{name}.JPG").write_bytes(b"foto finta")
        self.db = self.tmp / "discogs.sqlite"
        build_db(self.db)
        self.out = self.tmp / "risultati"
        self.api = FakeAPI()

    def main(self, *options):
        argv = ["vendi.py", str(self.photos), "--db", str(self.db), "--uscita", str(self.out), *options]
        output = io.StringIO()
        with contextlib.ExitStack() as stack:
            for target, value in [
                ("sys.argv", argv),
                ("vendi.STATE_DB", self.tmp / "vendita_stato.sqlite"),
                ("vendi.load_token", lambda: "token-finto"),
                ("vendi.DiscogsAPI", lambda token: self.api),
                ("vendi.AIVision", FakeAI),
                ("vendi.load_image", lambda path: Path(path).stem),
                ("vendi.read_barcodes", lambda img: []),
                ("vendi.ocr_available", lambda: True),
                ("vendi.ocr_lines", lambda img: list(OCR[img])),
            ]:
                stack.enter_context(mock.patch(target, value))
            stack.enter_context(contextlib.redirect_stdout(output))
            vendi.main()
        return output.getvalue()

    def read_csv(self, name):
        with open(self.out / name, newline="", encoding="utf-8") as f:
            return list(csv.DictReader(f))

    def inventory(self):
        rows = []
        for path in sorted(self.out.glob("inventario_[0-9]*.csv")):
            rows += self.read_csv(path.name)
        return rows

    def to_check(self):
        return {Path(r["foto"]).stem: r for r in self.read_csv("da_controllare.csv")}


class TestProtezioni(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.run = Run(self._tmp.name)
        FakeAI.reads = []

    def tearDown(self):
        self._tmp.cleanup()

    def test_casi_reali(self):
        self.run.main("--bozza")
        listed = {r["external_id"]: r for r in self.run.inventory()}
        check = self.run.to_check()

        # Caso 1: la compilation di Theo Parrish scambiata per The Awakening - Mirage (240 €)
        self.assertNotIn("IMG_0001", listed)
        row = check["IMG_0001"]
        self.assertEqual(row["release_id_proposto"], "1901512")
        self.assertIn("The Awakening - Mirage", row["disco_proposto"])
        self.assertEqual(row["metodo"], "ai")
        self.assertIn("scaletta", row["motivo"])
        self.assertEqual(row["prezzo_calcolato"], "240.00")

        # Caso 2: white label abbinata a una release russa per il solo titolo
        self.assertNotIn("IMG_0002", listed)
        row = check["IMG_0002"]
        self.assertEqual(row["release_id_proposto"], "5819891")
        self.assertEqual(row["metodo"], "locale-testo")
        self.assertIn("non si può confrontare", row["motivo"])
        self.assertNotIn("IMG_0002", FakeAI.reads)  # trovato in locale: l'AI non è stata chiamata

        # Match pulito per catalogo: nel CSV come prima
        self.assertEqual(listed["IMG_0003"]["release_id"], "3993455")
        self.assertEqual(listed["IMG_0003"]["price"], "20.00")
        self.assertEqual(listed["IMG_0003"]["status"], "DRAFT")
        self.assertNotIn("IMG_0003", check)

        # Match pulito per artista e titolo: supera la verifica e va nel CSV
        self.assertEqual(listed["IMG_0004"]["release_id"], "3993455")
        self.assertNotIn("IMG_0004", check)

        # Rete di sicurezza sul prezzo: riconosciuto per artista e titolo ma vale 120 € (> 100)
        self.assertNotIn("IMG_0005", listed)
        row = check["IMG_0005"]
        self.assertEqual(row["release_id_proposto"], "1111111")
        self.assertEqual(row["metodo"], "locale-testo")
        self.assertEqual(row["prezzo_calcolato"], "120.00")
        self.assertIn("soglia di controllo", row["motivo"])

        # Nessun annuncio via API e nessun collezionistico messo in vendita
        self.assertEqual(self.run.api.listings, [])
        self.assertEqual(self.run.read_csv("collezionistici.csv"), [])

        # Rilanciando, le foto da verificare restano fuori dal CSV
        self.run.main("--bozza")
        self.assertEqual(sorted(r["external_id"] for r in self.run.inventory()), ["IMG_0003", "IMG_0004"])

    def test_soglia_controllo_configurabile(self):
        self.run.main("--bozza", "--soglia-controllo", "150")
        listed = {r["external_id"]: r for r in self.run.inventory()}
        self.assertEqual(listed["IMG_0005"]["price"], "120.00")  # 120 € sotto la soglia di 150
        self.assertIn("IMG_0001", self.run.to_check())           # il caso 1 resta da controllare

    def test_rielabora_solo_con_bozza(self):
        with self.assertRaises(SystemExit) as e:
            self.run.main("--rielabora")
        self.assertIn("--bozza", str(e.exception))

    def test_rielabora_ripete_le_foto(self):
        self.run.main("--bozza")
        self.assertEqual(FakeAI.reads, ["IMG_0001"])
        out = self.run.main("--bozza")  # senza --rielabora: tutto già fatto, l'AI non viene richiamata
        self.assertEqual(FakeAI.reads, ["IMG_0001"])
        self.assertIn("foto già in vendita:         2", out)

        out = self.run.main("--bozza", "--rielabora")
        self.assertIn("5 foto verranno rielaborate", out)
        self.assertEqual(FakeAI.reads, ["IMG_0001", "IMG_0001"])  # l'AI rilegge la foto
        self.assertEqual(sorted(r["external_id"] for r in self.run.inventory()), ["IMG_0003", "IMG_0004"])
        self.assertIn("IMG_0001", self.run.to_check())
        # La spesa AI della prima esecuzione resta contata nel tetto
        state = sqlite3.connect(self.run.tmp / "vendita_stato.sqlite")
        self.assertAlmostEqual(state.execute("SELECT SUM(ai_costo) FROM foto").fetchone()[0], 0.04)
        self.assertGreater(state.execute("SELECT COUNT(*) FROM rielaborati").fetchone()[0], 0)

    def test_rielabora_non_tocca_le_foto_in_vendita(self):
        self.run.main()  # lancio vero, For Sale
        out = self.run.main("--bozza", "--rielabora")
        self.assertIn("saltate perché già in vendita", out)
        rows = self.run.inventory()
        self.assertEqual(sorted(r["external_id"] for r in rows), ["IMG_0003", "IMG_0004"])
        self.assertTrue(all(r["status"] == "FOR_SALE" for r in rows))  # nessun doppione in bozza


class TestVerifica(unittest.TestCase):
    """check_match da solo, con il testo letto nella foto simulato."""

    def evidence(self, ocr=(), ai=None):
        ev = vendi.Evidence()
        if ocr:
            ev.add_lines(list(ocr))
        if ai:
            vendi.ai_evidence(ev, ai)
        return ev

    def release(self, rid):
        r = next(x for x in RELEASES if x[0] == rid)
        return {"id": r[0], "artists": r[1], "title": r[2]}

    def test_caso_1_riga_della_scaletta(self):
        ev = self.evidence(ai=AI_READ["IMG_0001"])
        self.assertIn("scaletta", vendi.check_match(self.release(1901512), ev, AI_READ["IMG_0001"]))
        # il catno della scaletta non vale come catno del disco, nemmeno insieme ad altre parole
        self.assertFalse([c for c in ev.catnos if "BJQD15" in c])

    def test_caso_1_lettura_corretta(self):
        """Con la lettura giusta (intestazione, compilation) la release giusta passa, quella sbagliata no."""
        read = {**AI_READ["IMG_0001"], "artist": "Theo Parrish", "title": "Theo Parrish's Black Jazz Signature",
                "catno": "", "compilation": True}
        ev = self.evidence(ai=read)
        self.assertEqual(vendi.check_match(self.release(5206239), ev, read), "")
        self.assertIn("scaletta", vendi.check_match(self.release(1901512), ev, read))

    def test_caso_2_artista_in_altro_alfabeto(self):
        ev = self.evidence(ocr=OCR["IMG_0002"])
        self.assertIn("non si può confrontare", vendi.check_match(self.release(5819891), ev))

    def test_caso_3_various_senza_compilation(self):
        ev = self.evidence(ocr=[("FXHE", 0.07), ("FOE DA-INTERNATIONAL DJ ONLY", 0.05), ("Omar-S", 0.03),
                                ("A1", 0.01), ("B1", 0.01)])
        self.assertIn("Various", vendi.check_match(self.release(473428), ev))

    def test_una_sola_parola(self):
        ev = self.evidence(ocr=[("MIRAGE", 0.06), ("Side A", 0.01)])
        self.assertIn("non compare", vendi.check_match(self.release(1901512), ev))

    def test_match_pulito(self):
        ev = self.evidence(ocr=OCR["IMG_0004"])
        self.assertEqual(vendi.check_match(self.release(3993455), ev), "")

    def test_compilation_dalla_scaletta(self):
        ev = self.evidence(ocr=[("FXHE COMPULATION #1", 0.06), ("A1 Omar-S - Uno", 0.01),
                                ("A2 Kyle Hall - Due", 0.01), ("B1 Big Strick - Tre", 0.01)])
        self.assertTrue(vendi.is_compilation(ev))
        self.assertEqual(vendi.check_match(self.release(473428), ev), "")

    def test_metodo(self):
        self.assertEqual(vendi.method_of("locale-catno", {"_code": "catno"}), "catno")
        self.assertEqual(vendi.method_of("ai-scelta+locale", {"_code": "barcode"}), "barcode")
        self.assertEqual(vendi.method_of("ai-scelta+locale", {}), "ai")
        self.assertEqual(vendi.method_of("ai+locale-testo", {}), "ai")
        self.assertEqual(vendi.method_of("locale-testo", {}), "locale-testo")


class TestBozzeDoppie(unittest.TestCase):
    def test_bozze_vecchie_dopo_rielabora(self):
        drafts = [({"id": 10, "posted": "2026-10-10T09:00:00-07:00"}, "IMG_0003", "CSV"),   # prima: vecchia
                  ({"id": 11, "posted": "2026-10-10T09:00:00-07:00"}, "IMG_0004", "CSV"),   # mai rielaborata
                  ({"id": 25, "posted": "2026-10-13T09:00:00-07:00"}, "IMG_0003", "CSV"),   # dopo: nuova
                  ({"id": 26, "posted": "2026-10-13T09:00:00-07:00"}, "IMG_0003", "CSV")]   # altra copia (quantity 2)
        keep, old = pubblica_bozze.drop_old_drafts(drafts, {"IMG_0003": "2026-10-12T10:00:00"})
        self.assertEqual([d[0]["id"] for d in keep], [11, 25, 26])
        self.assertEqual([d[0]["id"] for d in old], [10])


if __name__ == "__main__":
    unittest.main()
