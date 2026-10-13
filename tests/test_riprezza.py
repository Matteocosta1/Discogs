"""
Test di riprezza.py (riprezzamento solo al rialzo) e del premio richiesta a scalini.
Inventario e mercato Discogs simulati: niente rete.

    python3 -m unittest discover tests
"""

import datetime as dt
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_protezioni as tp  # noqa: E402
from test_lotto import TempRun, run_script  # noqa: E402

import riprezza  # noqa: E402

vendi = tp.vendi


def market(suggested, for_sale, lowest=None, want=10, have=100):
    stats = {"num_for_sale": for_sale}
    if lowest is not None:
        stats["lowest_price"] = {"value": lowest}
    return (suggested, {"want": want, "have": have}, stats)


class RiprezzaBase(TempRun):
    photos = {}

    def setUp(self):
        super().setUp()
        self.market = {}
        patcher = mock.patch.dict(tp.MARKET, self.market)
        patcher.start()
        self.addCleanup(patcher.stop)

    def listing(self, rid, price, **market_args):
        """Un mio annuncio In vendita e i dati di mercato della sua release."""
        if market_args:
            tp.MARKET[rid] = market(**market_args)
        return self.run.api.add_listing(f"EID_{rid}_{len(self.run.api.inventory)}", rid, price, "For Sale",
                                        comments="Copertina con firma", location="B3", allow_offers=False)

    def riprezza(self, *options, answer="n", corsie=False):
        """Lancia riprezza.py; questi test provano la regola unica (--corsie-off), corsie=True per le corsie."""
        return run_script(self.run, riprezza, *options, *(() if corsie else ("--corsie-off",)), answer=answer)

    def results(self):
        path = self.run.out / f"riprezzamento_{dt.date.today():%Y%m%d}.csv"
        return {int(r["listing_id"]): r for r in self.run.read_csv(path.name)}

    def edits(self):
        return [c[1] for c in self.run.api.log if c[0] == "edit"]

    def price(self, item):
        return item["price"]["value"]


class TestRegolaRialzo(RiprezzaBase):
    def test_alza_solo_di_almeno_un_gradino_mai_abbassa(self):
        # Mercato: suggerito 20, 3 copie in vendita (2 concorrenti + me), il più basso 18 è un concorrente
        up = self.listing(3001, 20.0, suggested=20.0, for_sale=3, lowest=18.0)        # proposta 30 (+50%)
        same = self.listing(3002, 30.0, suggested=20.0, for_sale=3, lowest=18.0)      # proposta 30 = attuale
        small = self.listing(3003, 28.0, suggested=20.0, for_sale=3, lowest=18.0)     # +2 < un gradino
        lower = self.listing(3004, 40.0, suggested=20.0, for_sale=3, lowest=18.0)     # proposta 30 < 40
        out = self.riprezza()
        res = self.results()
        self.assertEqual((res[up["id"]]["esito"], res[up["id"]]["prezzo_proposto"]), ("da alzare", "30.00"))
        for item in (same, small, lower):
            self.assertEqual(res[item["id"]]["esito"], "invariato")
        self.assertEqual(self.edits(), [])                                   # senza --applica nessuna modifica
        self.assertIn("da alzare: 1", out)
        self.assertIn("aumento totale del valore dell'inventario se applichi: +10,00", out)

    def test_unico_venditore_non_sale_all_infinito(self):
        # Sono l'unico a 30 €, suggerito 20: le statistiche dicono "1 copia, più basso 30" (sono io)
        item = self.listing(3010, 30.0, suggested=20.0, for_sale=1, lowest=30.0)
        self.riprezza()
        first = self.results()[item["id"]]
        self.riprezza()
        second = self.results()[item["id"]]
        self.assertEqual(first["prezzo_proposto"], second["prezzo_proposto"])   # stessa proposta, non più alta
        self.assertEqual(first["prezzo_proposto"], "40.00")                     # 0 concorrenti: suggerito +100%
        self.assertIn("copie della concorrenza 0", first["calcolo_prezzo"])

        # Applicato a 40, il mese dopo le statistiche dicono "1 copia, più basso 40" (sempre io): invariato
        self.riprezza("--applica", answer="s")
        self.assertEqual(self.price(item), 40.0)
        tp.MARKET[3010] = market(20.0, 1, 40.0)
        state = self.state()
        state.execute("UPDATE prezzi SET ottenuto = '2000-01-01T00:00:00'")
        state.execute("UPDATE collezione SET ottenuto = '2000-01-01T00:00:00'")
        state.commit()
        self.riprezza()
        self.assertEqual(self.results()[item["id"]]["esito"], "invariato")
        self.assertEqual(self.results()[item["id"]]["prezzo_proposto"], "40.00")

    def test_da_controllare_non_applicati(self):
        big = self.listing(3020, 10.0, suggested=20.0, for_sale=6, lowest=8.0)     # 10 -> 25: +150%
        high = self.listing(3021, 100.0, suggested=100.0, for_sale=3, lowest=90.0)  # 100 -> 150: sopra 100
        out = self.riprezza("--applica", answer="s")
        res = self.results()
        self.assertEqual(res[big["id"]]["esito"], "da controllare")
        self.assertIn("oltre il massimo automatico (50%)", res[big["id"]]["motivo"])
        self.assertEqual(res[high["id"]]["esito"], "da controllare")
        self.assertIn("sopra la soglia di controllo", res[high["id"]]["motivo"])
        self.assertEqual(self.edits(), [])
        self.assertIn("Nessun prezzo da alzare", out)
        self.riprezza("--rialzo-massimo", "200")
        self.assertEqual(self.results()[big["id"]]["esito"], "da alzare")

    def test_senza_dati_di_mercato_non_si_tocca(self):
        item = self.listing(3030, 10.0, suggested=20.0, for_sale=6, lowest=8.0)
        self.run.api.failing = {3030}
        with mock.patch.object(tp.FakeAPI, "marketplace_stats",
                               lambda self, rid, cur: (_ for _ in ()).throw(vendi.ApiError(0, "rete"))):
            self.riprezza("--applica", answer="s")
        self.assertEqual(self.results()[item["id"]]["esito"], "dati non disponibili")
        self.assertEqual(self.edits(), [])


class TestApplica(RiprezzaBase):
    def setUp(self):
        super().setUp()
        self.a = self.listing(3101, 20.0, suggested=20.0, for_sale=3, lowest=18.0)   # -> 30
        self.b = self.listing(3102, 20.0, suggested=20.0, for_sale=3, lowest=18.0)   # -> 30

    def test_conferma_si_e_no(self):
        self.riprezza("--applica", answer="n")
        self.assertEqual(self.edits(), [])
        self.assertEqual(self.price(self.a), 20.0)
        out = self.riprezza("--applica", answer="s")
        self.assertEqual(sorted(self.edits()), [self.a["id"], self.b["id"]])
        self.assertEqual((self.price(self.a), self.price(self.b)), (30.0, 30.0))
        self.assertIn("Prezzi aggiornati: 2 su 2", out)
        history = self.state().execute("SELECT listing_id, prezzo_vecchio, prezzo_nuovo, calcolo FROM riprezzamenti"
                                       " ORDER BY listing_id").fetchall()
        self.assertEqual([tuple(h)[:3] for h in history], [(self.a["id"], 20.0, 30.0), (self.b["id"], 20.0, 30.0)])
        self.assertIn("arrotondato a griglia", history[0]["calcolo"])

    def test_altri_campi_identici_dopo_la_modifica(self):
        self.run.api.minimal_edit_resets = True          # anche se Discogs azzerasse i campi non inviati
        before = vendi.listing_fields(self.a)
        self.riprezza("--applica", answer="s")
        after = vendi.listing_fields(self.a)
        self.assertEqual(after.pop("price"), 30.0)
        before.pop("price")
        self.assertEqual(after, before)                   # commenti, external_id, posizione... intatti

    def test_si_ferma_se_un_campo_cambia(self):
        original = self.run.api.edit_listing_fields

        def edit_losing_comments(listing_id, body):
            original(listing_id, {**body, "comments": ""})
        self.run.api.edit_listing_fields = edit_losing_comments
        with self.assertRaises(SystemExit) as e:
            self.riprezza("--applica", answer="s")
        self.assertIn("ha cambiato anche altri campi", str(e.exception))
        self.assertEqual(len(self.edits()), 1)            # si ferma subito: il secondo annuncio non si tocca

    def test_interruzione_e_ripresa_senza_ripetere(self):
        original = self.run.api.edit_listing_fields
        calls = []

        def edit_then_interrupt(listing_id, body):
            calls.append(listing_id)
            if len(calls) == 2:
                raise KeyboardInterrupt
            original(listing_id, body)
        self.run.api.edit_listing_fields = edit_then_interrupt
        out = self.riprezza("--applica", answer="s")
        self.assertIn("Interrotto", out)
        done = [i for i in (self.a, self.b) if self.price(i) == 30.0]
        self.assertEqual(len(done), 1)

        self.run.api.edit_listing_fields = original
        self.run.api.log = []
        out = self.riprezza()                             # senza --applica: avvisa delle modifiche rimaste
        self.assertIn("1 modifiche approvate e non ancora applicate", out)
        self.riprezza("--applica", answer="s")
        self.assertEqual((self.price(self.a), self.price(self.b)), (30.0, 30.0))
        self.assertEqual(len(self.edits()), 1)            # solo quella rimasta, nessuna ripetuta


class TestAggiunte(RiprezzaBase):
    def test_sei_il_piu_economico(self):
        # Il più basso (15) sono io e ci sono altri 3 venditori, più cari
        item = self.listing(3201, 15.0, suggested=10.0, for_sale=4, lowest=15.0)
        out = self.riprezza("--applica", answer="s")
        row = self.results()[item["id"]]
        self.assertEqual(row["esito"], "sei il più economico")
        self.assertEqual(row["link_vendite_release"], "https://www.discogs.com/sell/release/3201")
        self.assertIn("Sei il più economico (controlla a mano)", out)
        self.assertIn("https://www.discogs.com/sell/release/3201", out)
        self.assertEqual(self.edits(), [])

    def test_want_in_crescita(self):
        grow = self.listing(3301, 20.0, suggested=20.0, for_sale=8, lowest=20.0, want=100, have=100)
        slow = self.listing(3302, 20.0, suggested=20.0, for_sale=8, lowest=20.0, want=100, have=100)
        self.riprezza()
        self.assertEqual(self.results()[grow["id"]]["in_crescita"], "")      # nessun controllo precedente
        state = self.state()
        state.execute("UPDATE collezione SET ottenuto = '2026-09-01T10:00:00'")
        state.execute("UPDATE want_storico SET data = '2026-09-01T10:00:00'")
        state.commit()
        tp.MARKET[3301] = market(20.0, 8, 20.0, want=140, have=100)          # +40%
        tp.MARKET[3302] = market(20.0, 8, 20.0, want=120, have=100)          # +20%
        out = self.riprezza()
        res = self.results()
        self.assertEqual(res[grow["id"]]["in_crescita"], "want +40%")
        self.assertEqual(res[slow["id"]]["in_crescita"], "")
        self.assertIn("in crescita (want aumentati): 1", out)
        history = state.execute("SELECT COUNT(*) FROM want_storico WHERE release_id = 3301").fetchone()[0]
        self.assertEqual(history, 2)

    def test_premio_richiesta_a_scalini(self):
        args = mock.Mock(premio_zero_copie=100.0, copie_poche=2, premio_poche_copie=50.0, copie_alcune=5,
                         premio_alcune_copie=25.0, scalini_richiesta=vendi.parse_steps(vendi.DEMAND_STEPS),
                         passo_prezzo=vendi.decimal.Decimal("2.50"), prezzo_minimo=vendi.decimal.Decimal("2.50"))
        for want, premium in ((80, None), (150, 10), (300, 25), (500, 50)):
            data = {"num_for_sale": 10, "lowest_price": 20.0, "lowest_currency": "EUR", "want": want, "have": 100}
            price, calc = vendi.compute_price(20.0, data, "VG+", "EUR", args)
            with self.subTest(want_have=want / 100):
                if premium is None:
                    self.assertIn("nessun premio richiesta", calc)
                    self.assertEqual(price, 20.0)
                else:
                    self.assertIn(f"+{premium}%", calc)
                    self.assertEqual(price, float(vendi.to_grid(20 * (1 + premium / 100), "2.5", "2.5")))
        self.assertEqual(vendi.parse_steps("2:30,1:5"), [(1.0, 5.0), (2.0, 30.0)])

    def test_solo_script_e_rotazione(self):
        mine = self.listing(3401, 20.0, suggested=20.0, for_sale=8, lowest=20.0)
        vendi.open_state(self.run.tmp / "vendita_stato.sqlite").close()   # stato di vendi.py
        state = self.state()
        state.execute("INSERT INTO foto (external_id, esito) VALUES (?, 'trovato')", (mine["external_id"],))
        state.commit()
        manual = [self.listing(3402 + n, 20.0, suggested=20.0, for_sale=8, lowest=20.0) for n in range(2)]
        self.riprezza("--solo-script")
        self.assertEqual(set(self.results()), {mine["id"]})
        self.assertEqual(self.results()[mine["id"]]["creato_da"], "script")

        self.riprezza("--max-annunci", "2")
        first = set(self.results())
        self.assertEqual(first, {manual[0]["id"], manual[1]["id"]})          # prima i mai controllati
        self.riprezza("--max-annunci", "2")
        self.assertIn(mine["id"], set(self.results()))                       # poi quelli controllati da più tempo


if __name__ == "__main__":
    unittest.main()
