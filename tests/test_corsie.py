"""
Test delle tre corsie di prezzo (LENTA / NORMALE / CALDA) in base al rapporto want/have,
in vendi.py e in riprezza.py. Dati di mercato simulati: niente rete.

    python3 -m unittest discover tests
"""

import argparse
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_protezioni as tp  # noqa: E402
from test_lotto import TempRun  # noqa: E402
from test_riprezza import RiprezzaBase  # noqa: E402

vendi = tp.vendi


def price_args(*options):
    parser = argparse.ArgumentParser()
    vendi.add_price_args(parser)
    args = parser.parse_args(list(options))
    vendi.check_price_args(args)
    return args


def market(want, have=100, copies=6, lowest=20.0):
    return {"want": want, "have": have, "num_for_sale": copies, "lowest_price": lowest, "lowest_currency": "EUR"}


class TestCorsie(unittest.TestCase):
    def price(self, suggested, data, *options, competitors=None):
        return vendi.compute_price(suggested, data, "VG+", "EUR", price_args(*options), competitors)

    def test_lenta_cinque_per_cento_sotto_e_griglia_per_difetto(self):
        price, calc = self.price(10.0, market(40), competitors=(6, 20.0))
        self.assertEqual(price, 17.5)
        self.assertIn("corsia LENTA (want/have 0,40 < 1): 5% sotto concorrenza 20,00 = 19,00 "
                      "→ griglia per difetto 17,50", calc)

    def test_lenta_mai_sotto_il_suggerito(self):
        price, calc = self.price(18.70, market(40), competitors=(6, 20.0))
        self.assertEqual(price, 20.0)                      # 19,00 -> 17,50 < suggerito 18,70 -> 20,00
        self.assertIn("sotto il suggerito VG+ 18,70: prezzo = suggerito sulla griglia 20,00", calc)
        price, _ = self.price(1.0, market(40, lowest=2.0), competitors=(6, 2.0))
        self.assertEqual(price, 2.5)                       # mai sotto il prezzo minimo

    def test_lenta_senza_concorrenti_e_normale(self):
        price, calc = self.price(10.0, market(40, copies=0, lowest=None), competitors=(0, None))
        self.assertIn("nessun concorrente da sottoquotare, regola NORMALE", calc)
        self.assertEqual(price, 20.0)                      # regola normale: 0 copie, suggerito +100%
        # il più basso in vendita sono io: nessun prezzo della concorrenza da sottoquotare
        others, lowest, maybe_me = vendi.competition(market(40, copies=3, lowest=17.5), [17.5], "EUR")
        self.assertEqual((others, lowest, maybe_me), (2, None, True))
        _, calc = self.price(10.0, market(40, copies=3, lowest=17.5), competitors=(others, lowest))
        self.assertIn("regola NORMALE", calc)

    def test_normale_come_oggi(self):
        data = market(150)
        price, calc = self.price(10.0, data)
        standard, standard_calc = vendi.standard_price(10.0, data, "VG+", "EUR", price_args())
        self.assertEqual(price, standard)
        self.assertEqual(price, 22.5)                      # base 20 +10% = 22 -> 22,50
        self.assertTrue(calc.startswith("corsia NORMALE (want/have 1,50 tra 1 e 2); "))
        self.assertTrue(calc.endswith(standard_calc))

    def test_calda_premi_a_scalini(self):
        price, calc = self.price(10.0, market(300))
        self.assertIn("corsia CALDA (want/have 3,00 > 2)", calc)
        self.assertIn("> 2 +25%", calc)
        self.assertEqual(price, 25.0)                      # 20 × 1,25
        price, _ = self.price(10.0, market(500))
        self.assertEqual(price, 30.0)                      # 20 × 1,50

    def test_corsie_off_regola_unica(self):
        for want in (40, 150, 300):
            data = market(want)
            price, calc = self.price(10.0, data, "--corsie-off")
            self.assertEqual((price, calc), vendi.standard_price(10.0, data, "VG+", "EUR", price_args()))
            self.assertNotIn("corsia", calc)

    def test_soglie_configurabili(self):
        price, calc = self.price(10.0, market(150), "--corsia-lenta-sotto", "2", "--corsia-calda-sopra", "3",
                                 "--sconto-corsia-lenta", "10", competitors=(6, 30.0))
        self.assertIn("corsia LENTA (want/have 1,50 < 2): 10% sotto concorrenza 30,00 = 27,00", calc)
        self.assertEqual(price, 25.0)
        with self.assertRaises(SystemExit):
            price_args("--corsia-lenta-sotto", "3", "--corsia-calda-sopra", "2")


class TestCorsieVendi(TempRun):
    photos = {"VG+": ["IMG_0006"]}

    def test_corsia_lenta_nel_csv(self):
        # Theo Parrish - Dance Of The Medusa: want/have 0,4, concorrenza a 20,00, suggerito 10,00
        with mock.patch.dict(tp.MARKET, {4207270: (10.0, {"want": 40, "have": 100},
                                                   {"num_for_sale": 6, "lowest_price": {"value": 20.0}})}):
            self.run.main(corsie=True)
            rows = self.run.inventory()
            self.assertEqual([(r["external_id"], r["price"]) for r in rows], [("IMG_0006", "17.50")])
            info = self.run.read_csv("inventario_foto.csv")
            self.assertIn("corsia LENTA", info[0]["calcolo_prezzo"])

            # Una nuova copia della stessa release: il più basso in vendita (17,50) ora potrei essere io
            (self.run.photos / "NM").mkdir()
            (self.run.photos / "NM" / "IMG_0008.JPG").write_bytes(b"altra copia")
            with mock.patch.dict(tp.OCR, {"IMG_0008": tp.OCR["IMG_0006"]}), \
                    mock.patch.dict(tp.MARKET, {4207270: (10.0, {"want": 40, "have": 100},
                                                          {"num_for_sale": 7, "lowest_price": {"value": 17.5}})}):
                self.run.main(corsie=True)
            info = {r["external_id"]: r for r in self.run.read_csv("inventario_foto.csv")}
            self.assertIn("nessun concorrente da sottoquotare", info["IMG_0008"]["calcolo_prezzo"])

    def test_rete_di_sicurezza_resta(self):
        # Riconosciuto per artista e titolo, corsia CALDA: 80 × (1 + 50% + 25%) = 140 > 100 -> da controllare
        self.run = tp.Run(self._tmp.name + "/b", photos={"VG+": ["IMG_0005"]})
        with mock.patch.dict(tp.MARKET, {1111111: (80.0, {"want": 300, "have": 100},
                                                   {"num_for_sale": 2, "lowest_price": {"value": 80.0}})}):
            self.run.main(corsie=True)
        self.assertEqual(self.run.inventory(), [])
        row = self.run.to_check()["IMG_0005"]
        self.assertEqual(row["prezzo_calcolato"], "140.00")
        self.assertIn("riconosciuto con locale-testo (non con barcode o catalogo esatto)", row["motivo"])


class TestCorsieRiprezza(RiprezzaBase):
    def test_calda_alza_lenta_non_abbassa(self):
        hot = self.listing(3501, 20.0, suggested=20.0, for_sale=8, lowest=18.0, want=300, have=100)   # -> 25
        slow = self.listing(3502, 30.0, suggested=10.0, for_sale=8, lowest=20.0, want=40, have=100)   # -> 17,50
        self.riprezza(corsie=True)
        res = self.results()
        self.assertEqual((res[hot["id"]]["esito"], res[hot["id"]]["prezzo_proposto"]), ("da alzare", "25.00"))
        self.assertIn("corsia CALDA", res[hot["id"]]["calcolo_prezzo"])
        self.assertEqual((res[slow["id"]]["esito"], res[slow["id"]]["prezzo_proposto"]), ("invariato", "17.50"))
        self.assertIn("corsia LENTA", res[slow["id"]]["calcolo_prezzo"])


if __name__ == "__main__":
    unittest.main()
