"""
Test del pannello collegato (python pannello.py): pagina viva, azioni "È questo" (abbina) e "Togli",
comandi in sottoprocesso. Ambiente simulato di test_protezioni.py: niente rete, niente spesa.

    python3 -m unittest discover tests
"""

import http.server
import json
import sys
import threading
import unittest
import urllib.request
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_protezioni as tp  # noqa: E402
from test_lotto import TempRun  # noqa: E402

import pannello  # noqa: E402

vendi = tp.vendi


class TestParseCandidati(unittest.TestCase):
    def test_parse(self):
        text = ("123 Artista - Titolo (Label (CAT1) US 1999) [punteggio 0.80: catno] https://www.discogs.com/release/123"
                " | 456 Altro - Disco (L2 (X) UK 2000) https://www.discogs.com/release/456 | ... e altre 3")
        got = pannello.parse_candidates(text, 456, "Altro - Disco (L2 (X) UK 2000)")
        self.assertEqual([c["id"] for c in got], [456, 123])              # il proposto per primo, senza doppioni
        self.assertEqual(got[1]["testo"], "Artista - Titolo (Label (CAT1) US 1999)")
        self.assertEqual(pannello.parse_candidates("", None, ""), [])


class TestPannelloVivo(TempRun):
    photos = {"VG+": ["IMG_0001", "IMG_0003"]}   # uno da verificare (AI sbaglia), uno pronto

    def setUp(self):
        super().setUp()
        self.run.main(csv=False)
        patches = [("vendi.STATE_DB", self.run.tmp / "vendita_stato.sqlite"),
                   ("vendi.load_token", lambda: "token-finto"),
                   ("vendi.DiscogsAPI", lambda token: self.run.api),
                   ("discogs_dump.DEFAULT_DB", self.run.db)]
        for target, value in patches:
            p = mock.patch(target, value)
            p.start()
            self.addCleanup(p.stop)
        self.job = pannello.Job()
        handler = pannello.make_handler(vendi, self.run.out, self.job)
        self.server = http.server.HTTPServer(("127.0.0.1", 0), handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.server.server_close)

    def get(self, path):
        with urllib.request.urlopen(self.url + path, timeout=5) as r:
            return r.read().decode("utf-8")

    def post(self, body):
        req = urllib.request.Request(self.url + "/api/azione", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read().decode("utf-8"))

    def page_data(self):
        page = self.get("/")
        self.assertIn("const LIVE = true;", page)
        return json.loads(page.split("const DATA = ", 1)[1].split(";\n", 1)[0].replace("<\\/", "</"))

    def test_pagina_viva_con_candidati(self):
        data = self.page_data()
        self.assertEqual([d["id"] for d in data["vendita"]], ["IMG_0003"])
        self.assertTrue(data["vendita"][0]["pronto"])
        check = data["controllo"][0]
        self.assertEqual(check["id"], "IMG_0001")
        self.assertEqual(check["scelte"][0]["id"], 1901512)               # la proposta (sbagliata) per prima

    def test_e_questo_abbina(self):
        r = self.post({"azione": "abbina", "disco": "IMG_0001", "release": 5206239})
        self.assertTrue(r["ok"], r)
        self.assertIn("Theo Parrish", r["messaggio"])
        data = self.page_data()
        self.assertEqual(data["controllo"], [])                            # non è più da controllare
        row = self.state().execute("SELECT esito, release_id FROM foto WHERE external_id = 'IMG_0001'").fetchone()
        self.assertEqual(tuple(row), ("trovato", 5206239))

    def test_conferma_poi_prezzo_e_pronto(self):
        import metti_in_vendita
        page = self.get("/")
        self.assertIn('data-act="conferma"', page)                         # il pulsante c'è
        r = self.post({"azione": "abbina", "disco": "IMG_0001", "release": 1901512})   # Conferma = la proposta
        self.assertTrue(r["ok"], r)
        data = self.page_data()
        waiting = [d for d in data["vendita"] if d["id"] == "IMG_0001"]
        self.assertEqual(waiting[0]["online"], "Confermato: da pubblicare")
        self.assertEqual([w["external_id"] for w in metti_in_vendita.waiting(self.state())], ["IMG_0001"])
        # il lancio sul lotto senza AI lo prezza: diventa un annuncio pronto
        self.run.main("--senza-ai", csv=False)
        self.assertEqual(metti_in_vendita.waiting(self.state()), [])
        row = self.state().execute("SELECT stato, release_id FROM annunci_api WHERE external_id = 'IMG_0001'").fetchone()
        self.assertEqual(tuple(row), ("pronto", 1901512))

    def test_bozza_rimessa_in_vendita(self):
        con = self.state()
        con.execute("INSERT INTO annunci_api (external_id, release_id, price, media, sleeve, stato, listing_id, status, online) "
                    "VALUES ('IMG_0077', 1901512, 10, 'M', 'M', 'pubblicato', 777, 'DRAFT', 'bozza')")
        con.commit()
        self.run.api.inventory.append({"id": 777, "status": "Draft", "external_id": "IMG_0077",
                                       "release": {"id": 1901512}, "price": {"value": 10.0, "currency": "EUR"},
                                       "condition": "Mint (M)", "sleeve_condition": "Mint (M)"})
        r = self.post({"azione": "bozza_vendita", "disco": "IMG_0077"})
        self.assertTrue(r["ok"], r)
        self.assertEqual(self.run.api._item(777)["status"], "For Sale")
        row = self.state().execute("SELECT online, status FROM annunci_api WHERE external_id = 'IMG_0077'").fetchone()
        self.assertEqual(tuple(row), ("in_vendita", "FOR_SALE"))

    def test_togli_un_pronto(self):
        r = self.post({"azione": "togli", "disco": "IMG_0003"})
        self.assertTrue(r["ok"], r)
        self.assertEqual(self.page_data()["vendita"], [])
        self.assertEqual(self.state().execute("SELECT esito FROM foto WHERE external_id = 'IMG_0003'").fetchone()[0],
                         "tolto")

    def test_errore_torna_come_messaggio(self):
        r = self.post({"azione": "abbina", "disco": "IMG_0099", "release": 5206239})
        self.assertFalse(r["ok"])
        self.assertIn("nessun disco", r["messaggio"])
        r = self.post({"azione": "boh"})
        self.assertFalse(r["ok"])

    def test_elabora_cartella_inesistente(self):
        r = self.post({"azione": "elabora", "cartella": "/non/esiste"})
        self.assertFalse(r["ok"])
        self.assertIn("Cartella non trovata", r["messaggio"])

    def test_job_in_sottoprocesso(self):
        self.assertTrue(self.job.start([sys.executable, "-c", "print('ciao dal job')"], str(self.run.tmp)))
        if self.job.active:
            self.assertFalse(self.job.start([sys.executable, "-c", "pass"], str(self.run.tmp)))  # uno alla volta
        self.job.thread.join(timeout=10)
        self.assertIn("ciao dal job", self.job.log)
        self.assertIn("[finito, codice 0]", self.job.log)
        st = json.loads(self.get("/api/log"))
        self.assertFalse(st["attivo"])
        self.assertIn("ciao dal job", st["log"])


if __name__ == "__main__":
    unittest.main()
