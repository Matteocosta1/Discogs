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
    (4207270, "Theo Parrish", "Dance Of The Medusa", "Sound Signature", "SS049", "US", 2012, "Vinyl, 12\""),
    (807332, "Omar-S", "Test Omar-S EP", "FXHE Records", "FXHE-TEST", "US", 2006, "Vinyl, 12\""),
]

# Prezzo suggerito (uguale per tutti i gradi) e dati del marketplace di ogni release.
MARKET = {
    1901512: (120.0, {"want": 50, "have": 100}, {"num_for_sale": 0}),           # 240 €, collezionistico
    5206239: (13.0, {"want": 10, "have": 100}, {"num_for_sale": 12, "lowest_price": {"value": 26.0}}),
    5819891: (15.0, {"want": 1, "have": 5}, {"num_for_sale": 3, "lowest_price": {"value": 15.0}}),
    473428: (20.0, {"want": 5, "have": 50}, {"num_for_sale": 8, "lowest_price": {"value": 20.0}}),
    3993455: (20.0, {"want": 30, "have": 100}, {"num_for_sale": 10, "lowest_price": {"value": 18.0}}),
    1111111: (80.0, {"want": 10, "have": 100}, {"num_for_sale": 2, "lowest_price": {"value": 80.0}}),  # 120 €
    4207270: (25.0, {"want": 40, "have": 100}, {"num_for_sale": 6, "lowest_price": {"value": 25.0}}),
    807332: (15.0, {"want": 30, "have": 100}, {"num_for_sale": 8, "lowest_price": {"value": 15.0}}),
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
    # Release vendibile, trovata per catalogo.
    "IMG_0006": [("THEO PARRISH", 0.06), ("DANCE OF THE MEDUSA", 0.05), ("SS049", 0.012),
                 ("Sound Signature", 0.02)],
    # Etichetta Omar-S al limite: l'OCR non legge nulla, il primo modello nemmeno.
    "IMG_0007": [],
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

    def __init__(self, token=None, blocked=(), failing=()):
        self.calls = 0
        self.listings = []
        self.blocked = set(blocked)    # release bloccate dal marketplace
        self.failing = set(failing)    # release per cui GET /releases/{id} fallisce (rete)
        self.log = []                  # (richiesta, release_id) fatte a Discogs per le release
        self.inventory = []            # annunci del venditore su Discogs (come li restituisce l'inventario)
        self.inventory_error = False   # True: la lettura dell'inventario fallisce
        self.orders = []               # i miei ordini (come li restituisce /marketplace/orders)
        self.orders_error = False      # True: la lettura degli ordini fallisce
        self.page_size = 100

    def identity(self):
        return {"username": "test"}

    def user(self, username):
        return {"curr_abbr": "EUR"}

    def search(self, **params):
        return {"results": []}

    def price_suggestions(self, rid):
        self.log.append(("price_suggestions", rid))
        value = MARKET[rid][0]
        return {grade: {"value": value, "currency": "EUR"} for grade in vendi.GRADES.values()}

    def release(self, rid):
        self.log.append(("release", rid))
        if rid in self.failing:
            raise vendi.ApiError(0, f"nessuna risposta da Discogs per /releases/{rid}")
        return {"id": rid, "community": MARKET[rid][1], vendi.BLOCKED_FIELD: rid in self.blocked}

    def marketplace_stats(self, rid, currency):
        self.log.append(("marketplace_stats", rid))
        stats = dict(MARKET[rid][2])
        if "lowest_price" in stats:
            stats["lowest_price"] = {**stats["lowest_price"], "currency": "EUR"}
        return stats

    def create_listing(self, release_id, condition, sleeve_condition, price, external_id, status="For Sale"):
        self.listings.append((release_id, condition, sleeve_condition, price, external_id, status))
        item = self.add_listing(external_id, release_id, price, status)  # su Discogs compare subito
        return {"listing_id": item["id"]}

    def inventory_page(self, username, page, status=None):
        self.log.append(("inventory", status))
        if self.inventory_error:
            raise vendi.ApiError(0, "nessuna risposta da Discogs per l'inventario")
        items = [i for i in self.inventory if status is None or i["status"] == status]
        pages = max(1, -(-len(items) // self.page_size))
        start = (page - 1) * self.page_size
        return {"listings": items[start:start + self.page_size], "pagination": {"pages": pages}}

    # --- annunci: lettura e modifica (per riprezza.py e verifica_modifica_annuncio.py) ---
    minimal_edit_resets = False   # True: una modifica con i soli campi obbligatori azzera gli altri

    def _item(self, listing_id):
        return next(i for i in self.inventory if i["id"] == listing_id)

    def get_listing(self, listing_id):
        import copy
        self.log.append(("get_listing", listing_id))
        return {**copy.deepcopy(self._item(listing_id)), "seller": {"username": "test"}}

    def _apply(self, item, body):
        for key, value in body.items():
            if key == "price":
                item["price"] = {**item.get("price", {}), "value": value}
            elif key == "release_id":
                item["release"] = {**item.get("release", {}), "id": value}
            else:
                item[key] = value

    def edit_listing(self, listing_id, release_id, condition, sleeve_condition, price, status):
        self.log.append(("edit", listing_id))
        item = self._item(listing_id)
        if self.minimal_edit_resets:
            for key in ("comments", "external_id", "location", "weight", "format_quantity", "allow_offers"):
                item.pop(key, None)
        self._apply(item, {"release_id": release_id, "condition": condition, "sleeve_condition": sleeve_condition,
                           "price": price, "status": status})
        return {}

    def edit_listing_fields(self, listing_id, body):
        self.log.append(("edit", listing_id))
        self._apply(self._item(listing_id), body)
        return {}

    def orders_page(self, page):
        self.log.append(("orders", page))
        if self.orders_error:
            raise vendi.ApiError(0, "nessuna risposta da Discogs per gli ordini")
        start = (page - 1) * self.page_size
        pages = max(1, -(-len(self.orders) // self.page_size))
        return {"orders": self.orders[start:start + self.page_size], "pagination": {"pages": pages}}

    def sell(self, item, status="Shipped"):
        """Simula una vendita: l'annuncio sparisce dall'inventario e compare in un ordine."""
        self.inventory.remove(item)
        order = {"id": f"1234567-{len(self.orders) + 1}", "status": status,
                 "items": [{"id": item["id"], "release": {"id": item["release"]["id"]},
                            "price": item["price"], "media_condition": item.get("condition")}]}
        self.orders.append(order)
        return order

    def upload_csv(self, rows):
        """Simula il caricamento di un CSV su Discogs: le righe vanno In vendita (Discogs ignora DRAFT)."""
        for r in rows:
            for _ in range(int(r["quantity"])):
                self.add_listing(r["external_id"], int(r["release_id"]), float(r["price"]), "For Sale")

    def add_listing(self, external_id, release_id, price, status, **extra):
        item = {"id": 9000 + len(self.inventory), "status": status, "external_id": external_id,
                "release": {"id": release_id}, "price": {"value": price, "currency": "EUR"},
                "condition": "Very Good Plus (VG+)", "sleeve_condition": "Very Good Plus (VG+)",
                "posted": "2026-10-13T10:00:00-07:00", **extra}
        self.inventory.append(item)
        return item


class FakeAI:
    """Al posto di vendi.AIVision: risposte scritte sopra, costo finto di 0,01 € a chiamata.
    by_model: risposte diverse per un modello, {modello: (letture, scelte)} (es. il secondo tentativo)."""
    reads = []        # foto lette, da tutti i modelli
    calls = []        # (modello, foto)
    by_model = {}

    def __init__(self, model, budget, spent, wallet=None):
        self.model = model
        self.wallet = wallet or vendi.Wallet(budget, spent)

    @property
    def spent(self):
        return self.wallet.spent

    @staticmethod
    def prepare(img):
        return img  # il nome della foto, al posto dell'immagine da inviare

    def _pay(self):
        if self.wallet.spent + 0.01 > self.wallet.budget + 1e-9:
            raise vendi.BudgetReached()
        self.wallet.spent += 0.01

    def answers(self):
        return FakeAI.by_model.get(self.model, (AI_READ, AI_CHOICE))

    def read(self, image):
        self._pay()
        FakeAI.reads.append(image)
        FakeAI.calls.append((self.model, image))
        return dict(self.answers()[0].get(image, {})), 0.01

    def choose(self, image, candidates):
        self._pay()
        choice = self.answers()[1][image]
        assert choice["release_id"] in [c["id"] for c in candidates]
        return dict(choice), 0.01


class Run:
    """Ambiente di prova: cartella delle foto, database, stato e risultati in una cartella temporanea."""

    def __init__(self, tmp, photos=PHOTOS):
        self.tmp = Path(tmp)
        self.photos = self.tmp / "Dischi"
        for grade, names in photos.items():
            (self.photos / grade).mkdir(parents=True)
            for name in names:
                (self.photos / grade / f"{name}.JPG").write_bytes(f"foto finta {name}".encode())
        self.db = self.tmp / "discogs.sqlite"
        build_db(self.db)
        self.out = self.tmp / "risultati"
        self.api = FakeAPI()

    def main(self, *options, corsie=False):
        """Lancia vendi.py. I test scritti per la regola unica la usano con --corsie-off; corsie=True per
        provare le tre corsie di prezzo (il default di vendi.py)."""
        if not corsie:
            options = (*options, "--corsie-off")
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
        FakeAI.reads, FakeAI.calls, FakeAI.by_model = [], [], {}

    def tearDown(self):
        self._tmp.cleanup()

    def test_casi_reali(self):
        self.run.main()
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
        self.assertEqual(listed["IMG_0003"]["status"], "FOR_SALE")
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
        self.run.main()
        self.assertEqual(sorted(r["external_id"] for r in self.run.inventory()), ["IMG_0003", "IMG_0004"])

    def test_soglia_controllo_configurabile(self):
        self.run.main("--soglia-controllo", "150")
        listed = {r["external_id"]: r for r in self.run.inventory()}
        self.assertEqual(listed["IMG_0005"]["price"], "120.00")  # 120 € sotto la soglia di 150
        self.assertIn("IMG_0001", self.run.to_check())           # il caso 1 resta da controllare

    def test_rielabora_solo_con_bozza(self):
        with self.assertRaises(SystemExit) as e:
            self.run.main("--rielabora")
        self.assertIn("--bozza", str(e.exception))

    def test_rielabora_ripete_le_foto(self):
        self.run.main("--bozza")  # IMG_0003 e IMG_0004 diventano bozze via API
        self.assertEqual(FakeAI.reads, ["IMG_0001"])
        out = self.run.main("--bozza")  # senza --rielabora: tutto già fatto, l'AI non viene richiamata
        self.assertEqual(FakeAI.reads, ["IMG_0001"])
        self.assertIn("foto già in vendita:         2", out)

        # Le bozze sono online su Discogs: --rielabora non le tocca, rielabora solo le altre 3 foto
        out = self.run.main("--bozza", "--rielabora")
        self.assertIn("3 foto verranno rielaborate", out)
        self.assertIn("saltate perché online", out)
        self.assertEqual(FakeAI.reads, ["IMG_0001", "IMG_0001"])  # l'AI rilegge la foto
        self.assertEqual(len(self.run.api.listings), 2)            # nessun doppione

        # Cancellate le bozze su Discogs, si rielabora tutto
        self.run.api.inventory = []
        out = self.run.main("--bozza", "--rielabora")
        self.assertIn("5 foto verranno rielaborate", out)
        self.assertEqual(sorted(l[4] for l in self.run.api.listings), ["IMG_0003", "IMG_0003", "IMG_0004", "IMG_0004"])
        self.assertEqual(self.run.inventory(), [])
        self.assertIn("IMG_0001", self.run.to_check())
        # La spesa AI delle esecuzioni precedenti resta contata nel tetto
        state = sqlite3.connect(self.run.tmp / "vendita_stato.sqlite")
        self.addCleanup(state.close)
        self.assertAlmostEqual(state.execute("SELECT SUM(ai_costo) FROM foto").fetchone()[0], 0.06)
        self.assertGreater(state.execute("SELECT COUNT(*) FROM rielaborati").fetchone()[0], 0)

    def test_rielabora_non_tocca_le_foto_in_vendita(self):
        self.run.main()  # lancio vero, For Sale
        self.run.api.upload_csv(self.run.inventory())  # CSV caricato su Discogs
        out = self.run.main("--bozza", "--rielabora")
        self.assertIn("saltate perché online su Discogs", out)
        rows = self.run.inventory()
        self.assertEqual(sorted(r["external_id"] for r in rows), ["IMG_0003", "IMG_0004"])
        self.assertTrue(all(r["status"] == "FOR_SALE" for r in rows))  # nessun doppione in bozza


class TestNonVendibili(unittest.TestCase):
    """Release bloccate dal marketplace (es. la 3993455, scartata da Discogs al caricamento del CSV)."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        # IMG_0003: Moodymann - Picture This Sampler 3 (THIS003), IMG_0006: Theo Parrish - Dance Of The Medusa (SS049)
        self.run = Run(self._tmp.name, photos={"VG+": ["IMG_0003", "IMG_0006"]})
        self.run.api.blocked = {3993455}

    def tearDown(self):
        self._tmp.cleanup()

    def test_bloccata_in_non_vendibili_vendibile_nel_csv(self):
        out = self.run.main()
        listed = {r["external_id"]: r for r in self.run.inventory()}

        # 1. Bloccata: in non_vendibili.csv, non nel CSV, nessuna richiesta di prezzo o statistiche
        self.assertNotIn("IMG_0003", listed)
        blocked = self.run.read_csv("non_vendibili.csv")
        self.assertEqual(len(blocked), 1)
        self.assertEqual(blocked[0]["foto"], "VG+/IMG_0003.JPG")
        self.assertEqual(blocked[0]["grado"], "VG+")
        self.assertEqual(blocked[0]["release_id"], "3993455")
        self.assertEqual(blocked[0]["artista_titolo"], "Moodymann - Picture This Sampler 3")
        self.assertEqual(blocked[0]["metodo"], "catno")
        self.assertEqual(blocked[0]["link"], "https://www.discogs.com/release/3993455")
        self.assertEqual(blocked[0]["motivo"], "bloccata dal marketplace Discogs")
        self.assertEqual([c for c in self.run.api.log if c[1] == 3993455], [("release", 3993455)])
        self.assertNotIn("IMG_0003", self.run.to_check())
        self.assertIn("dischi non vendibili (bloccati da Discogs): 1", out)

        # 2. Vendibile: nel CSV come prima; GET /releases/{id} fatta una volta sola (riusata per want/have)
        self.assertEqual(listed["IMG_0006"]["release_id"], "4207270")
        self.assertEqual(listed["IMG_0006"]["price"], "25.00")
        self.assertEqual(self.run.api.log.count(("release", 4207270)), 1)

    def test_verifica_fallita_va_in_da_controllare(self):
        self.run.api.failing = {4207270}
        out = self.run.main()
        self.assertNotIn("IMG_0006", {r["external_id"] for r in self.run.inventory()})
        row = self.run.to_check()["IMG_0006"]
        self.assertIn("impossibile verificare se è vendibile", row["motivo"])
        self.assertEqual(row["release_id_proposto"], "4207270")
        self.assertNotIn(("price_suggestions", 4207270), self.run.api.log)
        self.assertIn("ATTENZIONE", out)

        # Al giro dopo, con Discogs di nuovo raggiungibile, la verifica viene rifatta e va nel CSV
        self.run.api.failing = set()
        self.run.main()
        self.assertIn("IMG_0006", {r["external_id"] for r in self.run.inventory()})
        self.assertNotIn("IMG_0006", self.run.to_check())

    def test_campo_assente_va_in_da_controllare(self):
        with mock.patch.object(FakeAPI, "release", lambda self, rid: {"id": rid, "community": MARKET[rid][1]}):
            self.run.main()
        self.assertEqual(self.run.inventory(), [])
        self.assertIn("blocked_from_sale", self.run.to_check()["IMG_0006"]["motivo"])

    def test_secondo_giro_senza_chiamate(self):
        self.run.main()
        self.run.api.log = []
        out = self.run.main()
        # 4. La release non vendibile viene saltata senza nessuna richiesta a Discogs
        self.assertEqual(self.run.api.log, [])
        self.assertEqual(len(self.run.read_csv("non_vendibili.csv")), 1)
        self.assertIn("dischi non vendibili (bloccati da Discogs): 1", out)

        # Con --rielabora invece la vendibilità viene ricontrollata (il CSV non era stato caricato)
        self.run.api.blocked = set()
        self.run.main("--bozza", "--rielabora")
        self.assertIn(("release", 3993455), self.run.api.log)
        self.assertEqual(self.run.inventory(), [])
        self.assertEqual(sorted((l[4], l[5]) for l in self.run.api.listings),
                         [("IMG_0003", "Draft"), ("IMG_0006", "Draft")])
        self.assertEqual(self.run.read_csv("non_vendibili.csv"), [])


class TestGriglia(unittest.TestCase):
    """Arrotondamento per eccesso alla griglia di 2,50 €, ultimo passaggio del prezzo."""

    EXAMPLES = [("1.80", "2.50"), ("2.50", "2.50"), ("3.00", "5.00"), ("6.10", "7.50"), ("10.00", "10.00"),
                ("10.40", "12.50"), ("19.50", "20.00"), ("21.50", "22.50"), ("23.00", "25.00"),
                ("29.15", "30.00"), ("37.91", "40.00"), ("99.99", "100.00"), ("100.01", "102.50")]

    def test_esempi(self):
        for price, expected in self.EXAMPLES:
            with self.subTest(price=price):
                self.assertEqual(str(vendi.to_grid(price, "2.50", "2.50")), expected)
                self.assertEqual(str(vendi.to_grid(float(price), "2.50", "2.50")), expected)

    def test_errori_di_virgola_mobile(self):
        self.assertEqual(str(vendi.to_grid(10.000000001, "2.50", "2.50")), "10.00")
        self.assertEqual(str(vendi.to_grid(0.1 + 0.2 + 9.7, "2.50", "2.50")), "10.00")  # 10.000000000000002

    def test_minimo_e_passo_configurabili(self):
        self.assertEqual(str(vendi.to_grid("0.50", "2.50", "2.50")), "2.50")
        self.assertEqual(str(vendi.to_grid("0", "2.50", "2.50")), "2.50")
        self.assertEqual(str(vendi.to_grid("10.40", "1.00", "2.50")), "11.00")
        self.assertEqual(str(vendi.to_grid("1.20", "1.00", "4.00")), "4.00")

    def test_calcolo_prezzo(self):
        args = mock.Mock(premio_zero_copie=100.0, copie_poche=2, premio_poche_copie=50.0, copie_alcune=5,
                         premio_alcune_copie=25.0, scalini_richiesta=vendi.parse_steps(vendi.DEMAND_STEPS),
                         passo_prezzo=vendi.decimal.Decimal("2.50"), prezzo_minimo=vendi.decimal.Decimal("2.50"))
        data = {"num_for_sale": 6, "lowest_price": 10.40, "lowest_currency": "EUR", "want": 10, "have": 100}
        price, calc = vendi.compute_price(10.40, data, "M", "EUR", args)
        self.assertEqual(price, 12.50)
        self.assertTrue(calc.endswith("= 10,40 EUR → arrotondato a griglia 2,50 = 12,50 EUR"), calc)
        price, calc = vendi.compute_price(1.80, None, "VG", "EUR", args)  # senza dati del marketplace
        self.assertEqual(price, 2.50)
        self.assertIn("arrotondato a griglia 2,50 = 2,50 EUR", calc)

    def run_photos(self, photos, *options):
        with tempfile.TemporaryDirectory() as tmp:
            run = Run(tmp, photos=photos)
            run.main(*options)
            return run.inventory(), run.to_check(), run.read_csv("inventario_foto.csv")

    def test_end_to_end_csv(self):
        # 4207270: suggerito M 10,40, nessun premio -> 12.50 nel CSV per Discogs
        market = (10.40, {"want": 10, "have": 100}, {"num_for_sale": 6, "lowest_price": {"value": 10.40}})
        with mock.patch.dict(MARKET, {4207270: market}):
            rows, check, info = self.run_photos({"M": ["IMG_0006"]})
        self.assertEqual([(r["release_id"], r["price"], r["media_condition"]) for r in rows],
                         [("4207270", "12.50", "Mint (M)")])
        self.assertEqual(check, {})
        self.assertIn("= 10,40 EUR → arrotondato a griglia 2,50 = 12,50 EUR", info[0]["calcolo_prezzo"])

    def test_soglia_sul_prezzo_arrotondato(self):
        # IMG_0005 (Moodymann - Silentintroduction) riconosciuto per artista e titolo
        market = (100.01, {"want": 10, "have": 100}, {"num_for_sale": 10, "lowest_price": {"value": 100.01}})
        with mock.patch.dict(MARKET, {1111111: market}):
            rows, check, _ = self.run_photos({"VG+": ["IMG_0005"]})
        self.assertEqual(rows, [])
        self.assertEqual(check["IMG_0005"]["prezzo_calcolato"], "102.50")
        self.assertIn("prezzo 102.50 EUR sopra la soglia di controllo (100)", check["IMG_0005"]["motivo"])

        # 98,00 prima dell'arrotondamento è sotto una soglia di 99, ma il prezzo finale (100,00) no
        market = (98.0, {"want": 10, "have": 100}, {"num_for_sale": 10, "lowest_price": {"value": 98.0}})
        with mock.patch.dict(MARKET, {1111111: market}):
            rows, check, _ = self.run_photos({"VG+": ["IMG_0005"]}, "--soglia-controllo", "99")
        self.assertEqual(rows, [])
        self.assertEqual(check["IMG_0005"]["prezzo_calcolato"], "100.00")


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
