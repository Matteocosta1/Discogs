"""
Test dei dischi con più foto (una sottocartella = un disco) e di raggruppa_foto.py.
Immagini, barcode, OCR, AI ed EXIF simulati: niente rete, niente spesa.

    python3 -m unittest discover tests
"""

import contextlib
import io
import json
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_protezioni as tp  # noqa: E402
from test_lotto import TempRun, write_jpeg  # noqa: E402

import raggruppa_foto  # noqa: E402

vendi = tp.vendi

FRANCISCO_BARCODE = "8012345678901"   # release 572658 (Francisco - Music Business, LP)
# Foto dei dischi in sottocartella: nome -> righe OCR
OCR = {
    "d1_fronte": [],                                                     # nessun indizio
    "d1_retro": [],                                                      # solo il barcode
    "d2_etichetta": [], "d2_fronte": [], "d2_retro": [],                 # niente in locale: serve l'AI
    "d3_retro": [],                                                      # barcode di Francisco
    "d3_etichetta": [("Sound Signature", 0.03), ("SS049", 0.012)],       # catalogo di Theo Parrish
    "d4_fronte": [("THEO PARRISH", 0.06), ("DANCE OF THE MEDUSA", 0.05)],
    "d4_etichetta": [("Sound Signature", 0.03), ("SS049", 0.012)],
}
BARCODES = {"d1_retro": [FRANCISCO_BARCODE], "d3_retro": [FRANCISCO_BARCODE]}
# Disco 2: l'AI vede tutte e tre le foto insieme e legge il catalogo dall'etichetta
AI_READ = {"d2_etichetta+d2_fronte+d2_retro": {
    "photo_type": "label", "compilation": False, "artist": "Theo Parrish", "title": "Dance Of The Medusa",
    "label": "Sound Signature", "catno": "SS049", "year": "2012", "country": "US", "barcode": "",
    "readable_text": "THEO PARRISH\nDANCE OF THE MEDUSA\nSound Signature\nSS049",
    "recognized_artist": "", "recognized_title": ""}}


class DiscBase(TempRun):
    photos = {"VG+": []}

    def setUp(self):
        super().setUp()
        for target, values in ((tp.OCR, OCR), (tp.BARCODES, BARCODES), (tp.AI_READ, AI_READ)):
            patcher = mock.patch.dict(target, values)
            patcher.start()
            self.addCleanup(patcher.stop)

    def disc(self, name, *photos, grade="VG+", copies=None):
        folder = self.run.photos / grade / name
        folder.mkdir(parents=True)
        for photo in photos:
            (folder / f"{photo}.jpg").write_bytes(f"foto finta {name}/{photo}".encode())
        if copies:
            (folder / f"copie-{copies}").write_bytes(b"")
        return folder

    def foto(self):
        return {r["external_id"]: r for r in self.state().execute("SELECT * FROM foto")}


class TestDiscoInSottocartella(DiscBase):
    def test_fronte_senza_indizi_e_retro_con_barcode(self):
        self.disc("disco-001", "d1_fronte", "d1_retro")
        out = self.run.main()
        rows = self.run.inventory()
        self.assertEqual(len(rows), 1)
        eid = rows[0]["external_id"]
        self.assertRegex(eid, r"^disco-001-[0-9a-f]{8}$")          # sottocartella + impronta breve
        self.assertEqual((rows[0]["release_id"], rows[0]["quantity"]), ("572658", "1"))
        self.assertEqual(tp.FakeAI.calls, [])                         # il barcode basta: niente AI
        row = self.foto()[eid]
        self.assertEqual((row["fonte"], row["n_foto"]), ("locale-barcode", 2))
        recog = self.run.read_csv("riconoscimento.csv")
        self.assertEqual(recog[0]["foto"], "VG+/disco-001 (2 foto)")
        self.assertIn("dischi elaborati:            1 (foto totali: 2)", out)
        self.assertIn("1 al primo colpo (senza AI), 0 con l'AI, 0 con il secondo tentativo", out)
        # Rilanciando non succede niente: il disco è già in vendita
        self.run.main()
        self.assertEqual(len(self.run.inventory()), 1)

    def test_senza_indizi_locali_una_sola_chiamata_ai_con_tutte_le_foto(self):
        self.disc("disco-002", "d2_fronte", "d2_retro", "d2_etichetta")
        out = self.run.main("--senza-secondo-tentativo")
        self.assertEqual(tp.FakeAI.calls, [("claude-haiku-4-5", "d2_etichetta+d2_fronte+d2_retro")])
        rows = self.run.inventory()
        self.assertEqual([(r["release_id"], r["quantity"]) for r in rows], [("4207270", "1")])
        row = self.foto()[rows[0]["external_id"]]
        self.assertAlmostEqual(row["ai_costo"], 0.01)                 # una chiamata, costo conteggiato
        self.assertIn("spesa AI: 0.010 € in questa esecuzione", out)
        self.assertIn("0 al primo colpo (senza AI), 1 con l'AI", out)

    def test_ai_max_foto(self):
        self.disc("disco-002", "d2_fronte", "d2_retro", "d2_etichetta")
        with mock.patch.dict(tp.AI_READ, {"d2_etichetta+d2_fronte": AI_READ["d2_etichetta+d2_fronte+d2_retro"]}):
            self.run.main("--senza-secondo-tentativo", "--ai-max-foto", "2")
        self.assertEqual(tp.FakeAI.calls, [("claude-haiku-4-5", "d2_etichetta+d2_fronte")])

    def test_foto_in_contrasto_da_controllare(self):
        self.disc("disco-003", "d3_retro", "d3_etichetta")
        self.run.main()
        self.assertEqual(self.run.inventory(), [])
        self.assertEqual(tp.FakeAI.calls, [])                         # inutile pagare l'AI
        check = self.run.read_csv("da_controllare.csv")
        self.assertEqual(len(check), 1)
        self.assertEqual(check[0]["foto"], "VG+/disco-003 (2 foto)")
        self.assertIn("foto della cartella in contrasto", check[0]["motivo"])
        self.assertIn("d3_retro.jpg: barcode 8012345678901 -> release 572658", check[0]["motivo"])
        self.assertIn("d3_etichetta.jpg: catalogo SS049 -> release 4207270", check[0]["motivo"])

    def test_indizi_uniti_e_coerenti(self):
        # Fronte con artista e titolo, etichetta con il catalogo: stessa release, nessun contrasto
        self.disc("disco-004", "d4_fronte", "d4_etichetta")
        self.run.main()
        self.assertEqual([r["release_id"] for r in self.run.inventory()], ["4207270"])
        self.assertEqual(self.foto()[self.run.inventory()[0]["external_id"]]["metodo"], "catno")

    def test_foto_sciolte_come_oggi(self):
        self.run = tp.Run(self._tmp.name + "/b", photos={"VG+": ["IMG_0003", "IMG_0006"]})
        self.run.main()
        self.assertEqual(sorted((r["external_id"], r["quantity"]) for r in self.run.inventory()),
                         [("IMG_0003", "1"), ("IMG_0006", "1")])
        self.assertEqual({r["foto"] for r in self.run.read_csv("riconoscimento.csv")},
                         {"VG+/IMG_0003.JPG", "VG+/IMG_0006.JPG"})

    def test_foto_sciolte_e_sottocartelle_insieme(self):
        (self.run.photos / "VG+" / "IMG_0006.JPG").write_bytes(b"foto finta IMG_0006")
        self.disc("disco-001", "d1_fronte", "d1_retro")
        self.run.main()
        self.assertEqual(sorted(r["release_id"] for r in self.run.inventory()), ["4207270", "572658"])

    def test_copie_2(self):
        self.disc("disco-001", "d1_fronte", "d1_retro", copies=2)
        self.run.main()
        rows = self.run.inventory()
        self.assertEqual([(r["release_id"], r["quantity"]) for r in rows], [("572658", "2")])

    def test_copie_2_in_bozza_due_annunci(self):
        self.disc("disco-001", "d1_fronte", "d1_retro", copies=2)
        self.run.main("--bozza")
        eids = sorted(listing[4] for listing in self.run.api.listings)
        self.assertEqual(len(eids), 2)
        self.assertRegex(eids[0], r"^disco-001-[0-9a-f]{8}$")
        self.assertEqual(eids[1], eids[0] + "-copia2")
        self.run.main("--bozza")                                      # nessun doppione
        self.assertEqual(len(self.run.api.listings), 2)

    def test_due_sottocartelle_stessa_release_si_fermano(self):
        """Lotto-05: disco-013 e disco-019 erano lo stesso disco fotografato due volte, finiti come 2 copie."""
        self.disc("disco-001", "d1_fronte", "d1_retro")
        self.disc("disco-005", "d3_retro")                            # stesso barcode: stesso disco o copia?
        out = self.run.main()
        self.assertEqual(self.run.inventory(), [])
        self.assertIn("--copie-diverse disco-001,disco-005", out)
        self.assertNotIn("date di scatto usate", out)
        self.assertEqual({r["esito"] for r in self.foto().values()}, {"stesso_disco"})
        self.assertEqual(len(self.run.read_csv("da_controllare.csv")), 2)

    def test_due_sottocartelle_copie_diverse_confermate(self):
        self.disc("disco-001", "d1_fronte", "d1_retro")
        self.disc("disco-005", "d3_retro")
        self.run.main()                                               # si fermano
        self.run.main("--copie-diverse", "disco-001,disco-005")       # confermate: 2 copie
        self.assertEqual([(r["release_id"], r["quantity"]) for r in self.run.inventory()], [("572658", "2")])

    def test_conferma_parziale_non_basta(self):
        self.disc("disco-001", "d1_fronte", "d1_retro")
        self.disc("disco-005", "d3_retro")
        self.run.main("--copie-diverse", "disco-001")
        self.assertEqual(self.run.inventory(), [])

    def test_tolta_la_cartella_in_piu_resta_una_copia(self):
        import shutil
        self.disc("disco-001", "d1_fronte", "d1_retro")
        extra = self.disc("disco-005", "d3_retro")
        self.run.main()
        shutil.rmtree(extra)
        self.run.main()
        self.assertEqual([(r["release_id"], r["quantity"]) for r in self.run.inventory()], [("572658", "1")])


class TestTogli(DiscBase):
    """--togli: un disco già finito in una riga CSV (non ancora caricata) va tolto."""

    def due_copie(self):
        self.disc("disco-013", "d1_fronte", "d1_retro")
        self.disc("disco-019", "d3_retro")
        self.run.main("--copie-diverse", "disco-013,disco-019")      # come il lotto-05: riga con 2 copie
        self.assertEqual([r["quantity"] for r in self.run.inventory()], ["2"])
        return {eid.rsplit("-", 1)[0]: eid for eid in self.foto()}

    def test_togli_un_doppione(self):
        ids = self.due_copie()
        out = self.run.main("--togli", "disco-019")                   # basta l'inizio del nome, se univoco
        self.assertIn(f"Tolto: {ids['disco-019']}", out)
        self.assertEqual(self.run.inventory(), [])                    # la riga è tolta, niente più x2
        archived = list((self.run.out / "archivio").glob("inventario_001_*.csv"))
        self.assertEqual(len(archived), 1)                            # il file di prima non si perde
        self.run.main()                                               # disco-013 torna da solo, file nuovo
        rows = self.run.inventory()
        self.assertEqual([(r["release_id"], r["quantity"]) for r in rows], [("572658", "1")])
        self.assertEqual(rows[0]["external_id"], ids["disco-013"])
        self.assertTrue((self.run.out / "inventario_002.csv").exists())
        self.assertEqual(self.foto()[ids["disco-019"]]["esito"], "tolto")
        self.assertEqual(self.run.read_csv("da_controllare.csv"), [])  # il tolto non è un problema
        out = self.run.main()                                         # e non torna più
        self.assertIn("dischi tolti (--togli):      1", out)
        reg = self.run.read_csv("registro.csv")                       # il registro segue lo stato
        self.assertEqual([(r["file"], r["external_id"], r["grado_disco"], r["copie"], r["foto"]) for r in reg],
                         [("inventario_002.csv", ids["disco-013"], "VG+", "1", "VG+/disco-013 (2 foto)")])
        self.assertEqual(reg[0]["lotto"], "Dischi")
        self.assertIn("Francisco - Music Business", reg[0]["disco"])
        self.assertEqual(len(self.run.inventory()), 1)

    def test_togli_riga_gia_online_si_rifiuta(self):
        ids = self.due_copie()
        con = self.state()
        con.execute("UPDATE righe_csv SET online = 'in_vendita', online_visto = '2026-10-14'")
        con.commit()
        with self.assertRaises(SystemExit) as e:
            self.run.main("--togli", ids["disco-019"])
        self.assertIn("già online", str(e.exception))
        self.assertEqual([r["quantity"] for r in self.run.inventory()], ["2"])

    def test_togli_nome_ambiguo_o_assente(self):
        self.due_copie()
        with self.assertRaises(SystemExit) as e:
            self.run.main("--togli", "disco")
        self.assertIn("corrisponde a più dischi", str(e.exception))
        with self.assertRaises(SystemExit) as e:
            self.run.main("--togli", "disco-099")
        self.assertIn("nessun disco", str(e.exception))
        self.assertEqual([r["quantity"] for r in self.run.inventory()], ["2"])   # niente toccato

    def test_stessa_foto_in_due_sottocartelle_si_ferma(self):
        self.disc("disco-001", "d1_fronte", "d1_retro")
        other = self.disc("disco-002", "d2_fronte")
        (other / "d1_retro.jpg").write_bytes((self.run.photos / "VG+" / "disco-001" / "d1_retro.jpg").read_bytes())
        with self.assertRaises(SystemExit) as e:
            self.run.main()
        self.assertIn("contengono la stessa foto", str(e.exception))
        self.assertEqual(self.run.api.listings, [])

    def test_foto_aggiunta_a_un_disco_gia_elaborato_si_ferma(self):
        folder = self.disc("disco-001", "d1_fronte", "d1_retro")
        self.run.main()
        (folder / "d1_extra.jpg").write_bytes(b"una foto in piu")
        with mock.patch.dict(tp.OCR, {"d1_extra": []}), self.assertRaises(SystemExit) as e:
            self.run.main()
        self.assertIn("contiene una foto già elaborata come disco-001-", str(e.exception))
        self.assertEqual(len(self.run.inventory()), 1)


class FakeClient:
    """Al posto del client di Anthropic: registra la richiesta e risponde con una lettura vuota."""

    def __init__(self):
        self.requests = []
        self.messages = self

    def create(self, **request):
        self.requests.append(request)
        answer = {k: "" for k in vendi.AI_READ_SCHEMA["required"]}
        answer.update(photo_type="front", compilation=False)
        return SimpleNamespace(usage=SimpleNamespace(input_tokens=3500, output_tokens=200), stop_reason="end_turn",
                               content=[SimpleNamespace(type="text", text=json.dumps(answer))])


class TestCostoPiuFoto(unittest.TestCase):
    def ai(self, budget):
        ai = vendi.AIVision.__new__(vendi.AIVision)   # senza chiave API: client finto
        ai.client, ai.model = FakeClient(), "claude-haiku-4-5"
        ai.price_in, ai.price_out = vendi.AI_MODELS[ai.model]
        ai.wallet = vendi.Wallet(budget, 0.0)
        return ai

    def test_una_chiamata_con_tutte_le_immagini(self):
        ai = self.ai(1.0)
        _data, cost = ai.read([("aaa", 1000), ("bbb", 1000), ("ccc", 1000)])
        request = ai.client.requests[0]
        content = request["messages"][0]["content"]
        self.assertEqual([c["type"] for c in content], ["image", "image", "image", "text"])
        self.assertTrue(content[-1]["text"].startswith("These 3 photos all show the SAME single vinyl record"))
        self.assertAlmostEqual(cost, (3500 * 1 + 200 * 5) / 1e6)
        self.assertAlmostEqual(ai.spent, cost)

    def test_stima_del_costo_somma_le_immagini(self):
        # stima massima: (token immagini + 600) × 1 $ + 1200 × 5 $ per milione di token
        one = ((1000 + 600) * 1 + 1200 * 5) / 1e6          # 0,0076
        three = ((3000 + 600) * 1 + 1200 * 5) / 1e6        # 0,0096
        ai = self.ai((one + three) / 2)
        ai.read(("aaa", 1000))                              # una foto: sta nel tetto
        ai.wallet.spent = 0.0
        with self.assertRaises(vendi.BudgetReached):        # tre foto: la stima supera il tetto
            ai.read([("aaa", 1000), ("bbb", 1000), ("ccc", 1000)])
        self.assertEqual(len(ai.client.requests), 1)


class TestRaggruppaFoto(TempRun):
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

    def shot(self, name, when, color="red"):
        write_jpeg(self.source / f"{name}.jpg", color, date_time_original=f"2026:10:13 {when}" if when else None)

    def raggruppa(self, *options, answer="s"):
        output = io.StringIO()
        argv = ["raggruppa_foto.py", str(self.source), "--grado", "VG+", "--destinazione", str(self.dest), *options]
        with mock.patch("sys.argv", argv), mock.patch("builtins.input", lambda prompt="": answer), \
                contextlib.redirect_stdout(output):
            raggruppa_foto.main()
        return output.getvalue()

    def discs(self):
        grade = self.dest / "VG+"
        return {d.name: sorted(f.name for f in d.iterdir()) for d in sorted(grade.iterdir())} if grade.exists() else {}

    def test_pausa_divide_i_dischi(self):
        self.shot("a", "12:00:00", "red")
        self.shot("b", "12:00:05", "blue")       # 5 s dopo
        self.shot("c", "12:00:13", "green")      # 8 s dopo
        self.shot("d", "12:01:13", "white")      # 60 s dopo: nuovo disco
        out = self.raggruppa()
        self.assertIn("disco-001: 3 foto, 12:00:00-12:00:13", out)
        self.assertIn("disco-002: 1 foto, 12:01:13-12:01:13", out)
        self.assertIn("disco-002: 1 sola foto", out)                  # gruppo sospetto
        self.assertEqual(self.discs(), {"disco-001": ["a.jpg", "b.jpg", "c.jpg"], "disco-002": ["d.jpg"]})
        self.assertEqual(list(self.source.iterdir()), [])            # spostate, non copiate

    def test_piu_di_quattro_foto_sospetto_e_numerazione_continua(self):
        (self.dest / "VG+" / "disco-007").mkdir(parents=True)
        for n in range(5):
            self.shot(f"f{n}", f"12:00:0{n}", ("red", "blue", "green", "white", "black")[n])
        out = self.raggruppa()
        self.assertIn("disco-008: 5 foto", out)
        self.assertIn("più di 4 foto", out)

    def test_foto_senza_exif_si_ferma(self):
        self.shot("a", "12:00:00", "red")
        self.shot("b", None, "blue")
        with self.assertRaises(SystemExit) as e:
            self.raggruppa()
        self.assertIn("1 foto senza data di scatto", str(e.exception))
        self.assertIn("b.jpg", str(e.exception))
        self.assertEqual(sorted(f.name for f in self.source.iterdir()), ["a.jpg", "b.jpg"])
        self.assertEqual(self.discs(), {})

    def test_simula_non_sposta_niente(self):
        self.shot("a", "12:00:00", "red")
        self.shot("b", "12:00:05", "blue")
        out = self.raggruppa("--simula")
        self.assertIn("disco-001: 2 foto", out)
        self.assertIn("nessuna foto è stata spostata", out)
        self.assertEqual(sorted(f.name for f in self.source.iterdir()), ["a.jpg", "b.jpg"])
        self.assertEqual(self.discs(), {})

    def test_senza_conferma_non_sposta(self):
        self.shot("a", "12:00:00", "red")
        self.raggruppa(answer="n")
        self.assertEqual([f.name for f in self.source.iterdir()], ["a.jpg"])


if __name__ == "__main__":
    unittest.main()
