"""
Test degli 8 punti della revisione prima del primo lotto vero (backup, verifica
dell'inventario, --rielabora, --bozza, nomi ripetuti, scadenza delle cache,
stesso disco fotografato più volte, secondo tentativo AI).

Usano l'ambiente simulato di test_protezioni.py: niente rete, niente spesa.

    python3 -m unittest discover tests
"""

import contextlib
import io
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_protezioni as tp  # noqa: E402
from test_protezioni import Run  # noqa: E402

import rinomina_foto  # noqa: E402
import verifica_inventario  # noqa: E402

vendi = tp.vendi


def run_script(run, module, *options, answer="n"):
    """Lancia verifica_inventario.py (o un altro script con main()) nell'ambiente di prova."""
    output = io.StringIO()
    with contextlib.ExitStack() as stack:
        for target, value in [("sys.argv", [module.__name__, "--uscita", str(run.out), *options]),
                              ("vendi.STATE_DB", run.tmp / "vendita_stato.sqlite"),
                              (f"{module.__name__}.load_token", lambda: "token-finto"),
                              (f"{module.__name__}.DiscogsAPI", lambda token: run.api),
                              ("builtins.input", lambda prompt="": answer)]:
            stack.enter_context(mock.patch(target, value))
        stack.enter_context(contextlib.redirect_stdout(output))
        module.main()
    return output.getvalue()


class TempRun(unittest.TestCase):
    """Base: un ambiente di prova nuovo per ogni test."""
    photos = {"VG+": ["IMG_0003", "IMG_0006"]}

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.run = Run(self._tmp.name, photos=self.photos)
        tp.FakeAI.reads = []

    def tearDown(self):
        self._tmp.cleanup()

    def state(self):
        con = sqlite3.connect(self.run.tmp / "vendita_stato.sqlite")
        con.row_factory = sqlite3.Row
        self.addCleanup(con.close)
        return con


# --------------------------------------------------------------------------
# Punto 7: backup automatico dello stato
# --------------------------------------------------------------------------

class TestBackup(TempRun):
    def backups(self):
        return sorted((self.run.tmp / "backup").glob("vendita_stato_*.sqlite"))

    def test_backup_a_ogni_lancio(self):
        self.run.main()
        self.assertEqual(self.backups(), [])  # primo lancio: lo stato non esisteva ancora
        self.run.main()
        copies = self.backups()
        self.assertEqual(len(copies), 1)
        con = sqlite3.connect(copies[0])
        self.addCleanup(con.close)
        self.assertGreater(con.execute("SELECT COUNT(*) FROM foto").fetchone()[0], 0)  # copia completa

    def test_nessun_backup_in_simulazione(self):
        self.run.main()
        self.run.main("--simula")
        self.assertEqual(self.backups(), [])

    def test_tiene_solo_le_ultime(self):
        self.run.main()
        state = self.run.tmp / "vendita_stato.sqlite"
        for _ in range(7):
            vendi.backup_state(state, keep=5)
            time.sleep(0.01)
        copies = self.backups()
        self.assertEqual(len(copies), 5)
        self.run.main("--backup-da-tenere", "3")
        self.assertEqual(len(self.backups()), 3)


# --------------------------------------------------------------------------
# Punto 3: verifica_inventario.py
# --------------------------------------------------------------------------

class TestVerificaInventario(TempRun):
    """Situazione di oggi: inventario_001.csv con 2 righe DRAFT caricate su Discogs; Discogs ha messo
    in vendita una riga (IMG_0006) e scartato l'altra (IMG_0003)."""

    def setUp(self):
        super().setUp()
        self.run.main()
        state = self.state()
        state.execute("UPDATE righe_csv SET status = 'DRAFT'")  # come le righe create con il vecchio --bozza
        state.commit()
        uploaded = [r for r in self.run.inventory() if r["external_id"] == "IMG_0006"]
        self.run.api.upload_csv(uploaded)

    def rows(self):
        return {r["external_id"]: r for r in self.state().execute("SELECT * FROM righe_csv")}

    def test_online_scartate_e_status_corretto(self):
        out = run_script(self.run, verifica_inventario)
        rows = self.rows()
        self.assertEqual(rows["IMG_0006"]["online"], "in_vendita")
        self.assertEqual(rows["IMG_0006"]["status"], "FOR_SALE")   # DRAFT caricata = in vendita
        self.assertIsNotNone(rows["IMG_0006"]["online_visto"])
        self.assertEqual(rows["IMG_0003"]["online"], "assente")
        self.assertEqual(rows["IMG_0003"]["status"], "DRAFT")      # non online: resta com'era
        self.assertIn("in vendita: 1", out)
        self.assertIn("NON online", out)
        self.assertIn("inventario_001.csv: 1", out)
        self.assertIn("IMG_0003", out)
        check = self.run.read_csv("verifica_inventario.csv")
        self.assertEqual({r["external_id"]: r["online"] for r in check},
                         {"IMG_0003": "non online", "IMG_0006": "in vendita"})

    def test_libera_le_righe_mai_online(self):
        run_script(self.run, verifica_inventario, "--libera", answer="n")
        self.assertIn("IMG_0003", self.rows())                    # risposta N: niente cambia

        out = run_script(self.run, verifica_inventario, "--libera", answer="s")
        self.assertIn("Liberate 1 righe", out)
        self.assertEqual(set(self.rows()), {"IMG_0006"})
        archived = list((self.run.out / "archivio").glob("inventario_001_PRIMA_*.csv"))
        self.assertEqual(len(archived), 1)                        # il file vecchio non viene perso
        self.assertEqual([r["external_id"] for r in self.run.read_csv("inventario_001.csv")], ["IMG_0006"])

        # Al giro dopo la foto torna in un CSV nuovo, senza rifare il riconoscimento né pagare l'AI
        tp.FakeAI.reads = []
        self.run.main()
        new = self.run.read_csv("inventario_002.csv")
        self.assertEqual([r["external_id"] for r in new], ["IMG_0003"])
        self.assertEqual(tp.FakeAI.reads, [])

    def test_mai_liberare_righe_gia_viste_online(self):
        run_script(self.run, verifica_inventario)
        self.run.api.inventory = []                               # venduta o cancellata a mano
        out = run_script(self.run, verifica_inventario, "--libera", answer="s")
        rows = self.rows()
        self.assertEqual(rows["IMG_0006"]["online"], "sparito")
        self.assertIn("IMG_0006", rows)                           # resta: non torna in vendita
        self.assertIn("Erano online e ora non ci sono più", out)

    def test_inventario_non_leggibile(self):
        self.run.api.inventory_error = True
        with self.assertRaises(SystemExit) as e:
            run_script(self.run, verifica_inventario, "--libera", answer="s")
        self.assertIn("Impossibile leggere l'inventario", str(e.exception))
        self.assertEqual(set(self.rows()), {"IMG_0003", "IMG_0006"})
        self.assertIsNone(self.rows()["IMG_0006"]["online"])

    def test_campo_external_id_assente(self):
        for item in self.run.api.inventory:
            del item["external_id"]
        with self.assertRaises(SystemExit) as e:
            run_script(self.run, verifica_inventario)
        self.assertIn("external_id", str(e.exception))

    def test_tutte_le_pagine(self):
        self.run.api.page_size = 1
        for n in range(3):
            self.run.api.add_listing(f"ALTRO_{n}", 1111111, 10.0, "For Sale")
        run_script(self.run, verifica_inventario)
        self.assertEqual(self.rows()["IMG_0006"]["online"], "in_vendita")
        self.assertGreaterEqual(self.run.api.log.count(("inventory", "For Sale")), 4)


# --------------------------------------------------------------------------
# Punto 1: --rielabora non crea mai doppioni
# --------------------------------------------------------------------------

class TestRielaboraSicuro(TempRun):
    def setUp(self):
        super().setUp()
        self.run.main()
        state = self.state()
        state.execute("UPDATE righe_csv SET status = 'DRAFT'")  # righe DRAFT come quelle di inventario_003
        state.commit()
        vendi.write_outputs(state, self.run.out, [], [])
        self.csv = self.run.out / "inventario_001.csv"
        self.before = self.csv.read_text()

    def rows(self):
        return {r["external_id"]: r for r in self.state().execute("SELECT * FROM righe_csv")}

    def test_riga_draft_online_non_rielaborata(self):
        self.run.api.upload_csv(self.run.inventory())       # caricato: Discogs le ha messe in vendita
        tp.FakeAI.reads = []
        out = self.run.main("--bozza", "--rielabora")
        self.assertIn("saltate perché online", out)
        self.assertEqual(set(self.rows()), {"IMG_0003", "IMG_0006"})
        self.assertTrue(self.csv.exists())
        # stesse righe e stessi prezzi; lo status passa a FOR_SALE, com'è davvero su Discogs
        self.assertEqual(self.csv.read_text(), self.before.replace(",DRAFT", ",FOR_SALE"))
        self.assertEqual(self.run.api.listings, [])            # nessun nuovo annuncio
        self.assertEqual(self.rows()["IMG_0006"]["status"], "FOR_SALE")

    def test_inventario_non_leggibile_nessuna_riga_toccata(self):
        self.run.api.inventory_error = True
        out = self.run.main("--bozza", "--rielabora")
        self.assertIn("impossibile leggere l'inventario", out)
        self.assertEqual(set(self.rows()), {"IMG_0003", "IMG_0006"})
        self.assertEqual(self.csv.read_text(), self.before)
        self.assertEqual(self.run.api.listings, [])

    def test_riga_mai_caricata_archiviata_non_cancellata(self):
        self.run.api.add_listing("IMG_0006", 4207270, 25.0, "For Sale")  # solo IMG_0006 è online
        self.run.main("--bozza", "--rielabora")
        rows = self.rows()
        self.assertEqual(rows["IMG_0006"]["parte"], 1)   # online: intatta
        self.assertNotIn("IMG_0003", rows)                # non era online: rielaborata, ora bozza via API
        self.assertEqual([(l[4], l[5]) for l in self.run.api.listings], [("IMG_0003", "Draft")])
        archived_rows = self.state().execute("SELECT external_id FROM rielaborati WHERE tabella = 'righe_csv'")
        self.assertEqual([r[0] for r in archived_rows], ["IMG_0003"])
        archived = list((self.run.out / "archivio").glob("inventario_001_PRIMA_*.csv"))
        self.assertEqual(len(archived), 1)
        self.assertEqual(archived[0].read_text(), self.before)

    def test_parte_svuotata_va_in_archivio(self):
        self.run.main("--bozza", "--rielabora")    # inventario vuoto: niente è online
        self.assertFalse(self.csv.exists())       # nessun file nuovo con lo stesso nome
        annullato = self.run.out / "archivio" / "inventario_001_ANNULLATO.csv"
        self.assertEqual(annullato.read_text(), self.before)
        self.assertEqual(self.rows(), {})                  # con --bozza le foto diventano bozze via API
        self.assertEqual(sorted(l[4] for l in self.run.api.listings), ["IMG_0003", "IMG_0006"])


# --------------------------------------------------------------------------
# Punto 2: --bozza crea bozze vere via API, il CSV è sempre FOR_SALE
# --------------------------------------------------------------------------

class TestBozza(TempRun):
    photos = {"VG+": ["IMG_0003", "IMG_0006"], "NM": ["IMG_0004"]}

    def test_bozza_solo_via_api(self):
        out = self.run.main("--bozza")
        self.assertEqual(self.run.inventory(), [])                     # nessuna riga nel CSV
        self.assertEqual(sorted((l[4], l[5]) for l in self.run.api.listings),
                         [("IMG_0003", "Draft"), ("IMG_0004", "Draft"), ("IMG_0006", "Draft")])
        state = self.state()
        self.assertEqual({r["external_id"]: (r["stato"], r["status"])
                          for r in state.execute("SELECT * FROM annunci_api")},
                         {e: ("pubblicato", "DRAFT") for e in ("IMG_0003", "IMG_0004", "IMG_0006")})
        self.assertIn("creato in bozza", out)

    def test_senza_bozza_csv_for_sale(self):
        self.run.main()
        rows = self.run.inventory()
        self.assertEqual(sorted(r["external_id"] for r in rows), ["IMG_0003", "IMG_0004", "IMG_0006"])
        self.assertTrue(all(r["status"] == "FOR_SALE" for r in rows))
        self.assertEqual(self.run.api.listings, [])

    def test_nessun_csv_con_draft(self):
        self.run.main()
        state = self.state()
        state.execute("UPDATE righe_csv SET status = 'DRAFT'")  # righe del vecchio --bozza nello stato
        state.commit()
        vendi.write_outputs(state, self.run.out, [], [])
        text = "".join(p.read_text() for p in self.run.out.glob("inventario_*.csv"))
        self.assertNotIn("DRAFT", text)

    def test_salvato_in_corso_prima_dell_invio(self):
        seen = []
        original = self.run.api.create_listing

        def create(release_id, *args):
            row = self.state().execute("SELECT stato FROM annunci_api WHERE external_id = ?", (args[3],)).fetchone()
            seen.append(row["stato"])
            return original(release_id, *args)

        self.run.api.create_listing = create
        self.run.main("--bozza")
        self.assertEqual(seen, ["in_corso"] * 3)


# --------------------------------------------------------------------------
# Punto 4: nomi delle foto ripetuti tra lotti diversi
# --------------------------------------------------------------------------

class TestNomiRipetuti(TempRun):
    photos = {"VG+": ["IMG_0001", "IMG_0003", "IMG_0006"]}

    def foto(self, eid):
        return self.state().execute("SELECT * FROM foto WHERE external_id = ?", (eid,)).fetchone()

    def test_stesso_nome_contenuto_diverso_si_ferma(self):
        self.run.main("--bozza")
        listings = len(self.run.api.listings)
        # Nuovo lotto: un'altra foto (da un altro telefono) con lo stesso nome di una già in vendita
        (self.run.photos / "VG+" / "IMG_0006.JPG").unlink()
        (self.run.photos / "NM").mkdir()
        (self.run.photos / "NM" / "IMG_0006.JPG").write_bytes(b"un altro disco")
        tp.FakeAI.reads = []
        with self.assertRaises(SystemExit) as e:
            self.run.main("--bozza")
        self.assertIn("NM/IMG_0006.JPG", str(e.exception))
        self.assertIn("DIVERSA con lo stesso nome", str(e.exception))
        self.assertIn("rinomina_foto.py", str(e.exception))
        self.assertEqual(len(self.run.api.listings), listings)   # niente elaborato
        self.assertEqual(tp.FakeAI.reads, [])

    def test_stessa_foto_con_due_nomi_si_ferma(self):
        (self.run.photos / "VG+" / "IMG_0099.JPG").write_bytes((self.run.photos / "VG+" / "IMG_0003.JPG").read_bytes())
        with self.assertRaises(SystemExit) as e:
            self.run.main()
        self.assertIn("stessa foto con due nomi", str(e.exception))
        self.assertEqual(self.run.inventory(), [])

    def test_foto_spostata_di_cartella_e_la_stessa(self):
        self.run.main()
        cost = self.foto("IMG_0001")["ai_costo"]
        (self.run.photos / "NM").mkdir()
        (self.run.photos / "VG+" / "IMG_0001.JPG").rename(self.run.photos / "NM" / "IMG_0001.JPG")
        tp.FakeAI.reads = []
        self.run.main()
        self.assertEqual(tp.FakeAI.reads, [])                     # nessun costo AI
        row = self.foto("IMG_0001")
        self.assertEqual(row["ai_costo"], cost)
        self.assertEqual((row["cartella"], row["media"]), ("NM", "NM"))
        self.assertEqual(row["esito"], "da_verificare")           # il riconoscimento resta

    def test_migrazione_stato_senza_impronta(self):
        self.run.main()
        state = self.state()
        state.execute("UPDATE foto SET hash = NULL")              # stato di una versione precedente
        state.commit()
        cost = self.foto("IMG_0001")["ai_costo"]
        tp.FakeAI.reads = []
        self.run.main()
        self.assertEqual(tp.FakeAI.reads, [])                     # la stessa foto: niente AI
        self.assertEqual(self.foto("IMG_0001")["ai_costo"], cost)
        self.assertEqual(self.foto("IMG_0001")["hash"],
                         vendi.file_sha256(self.run.photos / "VG+" / "IMG_0001.JPG"))

    def test_migrazione_dimensione_diversa_e_un_conflitto(self):
        self.run.main()
        state = self.state()
        state.execute("UPDATE foto SET hash = NULL")
        state.commit()
        (self.run.photos / "VG+" / "IMG_0003.JPG").write_bytes(b"altra foto, altra dimensione")
        with self.assertRaises(SystemExit) as e:
            self.run.main()
        self.assertIn("IMG_0003", str(e.exception))


class TestRinominaFoto(TempRun):
    photos = {"VG+": ["IMG_0003", "IMG_0006"]}
    TAKEN = {"IMG_2087": vendi.dt.datetime(2026, 10, 13, 15, 42, 33), "IMG_0006": None}

    def rename(self, answer):
        output = io.StringIO()
        with mock.patch("sys.argv", ["rinomina_foto.py", str(self.run.photos)]), \
                mock.patch("vendi.STATE_DB", self.run.tmp / "vendita_stato.sqlite"), \
                mock.patch("vendi.photo_taken_at", lambda path: self.TAKEN.get(Path(path).stem)), \
                mock.patch("builtins.input", lambda prompt="": answer), contextlib.redirect_stdout(output):
            rinomina_foto.main()
        return output.getvalue()

    def names(self):
        return sorted(p.name for p in self.run.photos.rglob("*.JPG"))

    def test_rinomina_solo_le_foto_nuove(self):
        self.run.main()                                           # IMG_0003 e IMG_0006 nello stato
        (self.run.photos / "NM").mkdir()
        (self.run.photos / "NM" / "IMG_2087.JPG").write_bytes(b"foto nuova")
        out = self.rename("n")
        self.assertIn("NM/IMG_2087.JPG -> 20261013_154233_IMG_2087.JPG", out)
        self.assertIn("già nello stato", out)
        self.assertEqual(self.names(), ["IMG_0003.JPG", "IMG_0006.JPG", "IMG_2087.JPG"])  # N: niente cambia

        self.rename("s")
        self.assertEqual(self.names(), ["20261013_154233_IMG_2087.JPG", "IMG_0003.JPG", "IMG_0006.JPG"])
        self.assertIn("Nessuna foto da rinominare", self.rename("s"))  # già rinominata

    def test_senza_exif_usa_la_data_del_file_e_lo_segnala(self):
        out = self.rename("s")                                    # stato vuoto: tutte nuove
        self.assertIn("senza data di scatto", out)
        renamed = [n for n in self.names() if n.endswith("_IMG_0006.JPG")]
        self.assertEqual(len(renamed), 1)
        mtime = vendi.dt.datetime.fromtimestamp((self.run.photos / "VG+" / renamed[0]).stat().st_mtime)
        self.assertTrue(renamed[0].startswith(f"{mtime:%Y%m%d_%H%M%S}_"))


# --------------------------------------------------------------------------
# Punto 5: cache dei prezzi e della vendibilità con scadenza
# --------------------------------------------------------------------------

class TestCacheScadenza(TempRun):
    def age(self, table, days):
        state = self.state()
        when = (vendi.dt.datetime.now() - vendi.dt.timedelta(days=days)).isoformat(timespec="seconds")
        state.execute(f"UPDATE {table} SET ottenuto = ?", (when,))
        state.commit()

    def calls(self, rid):
        return [c[0] for c in self.run.api.log if len(c) > 1 and c[1] == rid]

    def fresh_state(self):
        self.run.main()  # riempie le cache per 4207270 (IMG_0006)
        state = vendi.open_state(self.run.tmp / "vendita_stato.sqlite")
        self.addCleanup(state.close)
        self.run.api.log = []
        return state

    def test_prezzi_e_collezione(self):
        state = self.fresh_state()
        vendi.get_price_suggestions(state, self.run.api, 4207270, max_age_days=30)
        vendi.get_collector_data(state, self.run.api, None, 4207270, "EUR", max_age_days=30)
        self.assertEqual(self.calls(4207270), [])                        # recenti: nessuna richiesta

        self.age("prezzi", 31)
        self.age("collezione", 31)
        state = vendi.open_state(self.run.tmp / "vendita_stato.sqlite")
        self.addCleanup(state.close)
        with mock.patch("discogs_dump.get_releases", lambda con, ids: []):
            vendi.get_price_suggestions(state, self.run.api, 4207270, max_age_days=30)
            vendi.get_collector_data(state, self.run.api, None, 4207270, "EUR", max_age_days=30)
        self.assertEqual(self.calls(4207270), ["price_suggestions", "release", "marketplace_stats"])

    def test_vendibilita(self):
        state = self.fresh_state()
        self.assertEqual(vendi.check_sellable(state, self.run.api, 4207270, max_age_days=90)[2], 0)
        self.age("vendibilita", 89)
        self.assertEqual(vendi.check_sellable(state, self.run.api, 4207270, max_age_days=90)[2], 0)
        self.age("vendibilita", 91)
        self.assertEqual(vendi.check_sellable(state, self.run.api, 4207270, max_age_days=90)[2], 1)
        self.assertEqual(self.calls(4207270), ["release"])

    def test_non_vendibile_ricontrollata_alla_scadenza(self):
        self.run.api.blocked = {3993455}
        self.run.main()
        self.assertEqual(len(self.run.read_csv("non_vendibili.csv")), 1)
        self.run.api.blocked = set()                                       # Discogs l'ha sbloccata

        self.age("vendibilita", 30)
        self.run.api.log = []
        self.run.main()
        self.assertEqual(self.calls(3993455), [])                          # controllo recente: niente
        self.assertEqual(len(self.run.read_csv("non_vendibili.csv")), 1)

        self.age("vendibilita", 91)
        self.run.main("--cache-vendibilita-giorni", "90")
        self.assertIn("release", self.calls(3993455))
        self.assertEqual(self.run.read_csv("non_vendibili.csv"), [])
        self.assertIn("IMG_0003", [r["external_id"] for r in self.run.inventory()])

    def test_opzione_prezzi_giorni(self):
        self.run.main()
        self.age("prezzi", 10)
        state = vendi.open_state(self.run.tmp / "vendita_stato.sqlite")
        self.addCleanup(state.close)
        self.run.api.log = []
        vendi.get_price_suggestions(state, self.run.api, 4207270, max_age_days=7)   # --cache-prezzi-giorni 7
        self.assertEqual(self.calls(4207270), ["price_suggestions"])


# --------------------------------------------------------------------------
# Punto 6: fronte e retro dello stesso disco non diventano 2 copie
# --------------------------------------------------------------------------

class TestStessoDisco(TempRun):
    # IMG_0003 e IMG_0004 sono entrambe 3993455 (Moodymann - Picture This Sampler 3), stesso grado
    photos = {"VG+": ["IMG_0003", "IMG_0004"]}
    BASE = vendi.dt.datetime(2026, 10, 13, 15, 0, 0)

    def main_with_exif(self, seconds, *options):
        taken = {"IMG_0003": self.BASE,
                 "IMG_0004": None if seconds is None else self.BASE + vendi.dt.timedelta(seconds=seconds)}
        with mock.patch("vendi.photo_taken_at", lambda path: taken.get(Path(path).stem)):
            return self.run.main(*options)

    def listed(self):
        return [(r["external_id"], r["quantity"]) for r in self.run.inventory()]

    def test_scatti_a_20_secondi_da_controllare(self):
        out = self.main_with_exif(20)
        self.assertEqual(self.listed(), [])
        check = self.run.to_check()
        self.assertEqual(set(check), {"IMG_0003", "IMG_0004"})
        self.assertIn("stesso disco fotografato più volte (scatti a 20 secondi di distanza)",
                      check["IMG_0003"]["motivo"])
        self.assertIn("DA CONTROLLARE", out)
        self.assertNotIn(("price_suggestions", 3993455), self.run.api.log)   # nessuna richiesta a Discogs

    def test_scatti_a_10_minuti_due_copie(self):
        self.main_with_exif(600)
        self.assertEqual(self.listed(), [("IMG_0003", "2")])

    def test_senza_exif_due_copie_con_avviso(self):
        out = self.main_with_exif(None)
        self.assertEqual(self.listed(), [("IMG_0003", "2")])
        self.assertIn("senza data di scatto EXIF (IMG_0004)", out)

    def test_copie_consecutive(self):
        self.main_with_exif(20, "--copie-consecutive")
        self.assertEqual(self.listed(), [("IMG_0003", "2")])

    def test_soglia_configurabile_e_ripresa(self):
        self.main_with_exif(20, "--secondi-stesso-disco", "10")   # 20 s > 10 s: copie diverse
        self.assertEqual(self.listed(), [("IMG_0003", "2")])

    def test_tolta_la_foto_doppia_va_in_vendita(self):
        self.main_with_exif(20)
        (self.run.photos / "VG+" / "IMG_0004.JPG").unlink()       # tengo solo il fronte
        self.main_with_exif(20)
        self.assertEqual(self.listed(), [("IMG_0003", "1")])


if __name__ == "__main__":
    unittest.main()
