#!/usr/bin/env python3
"""
Mette in vendita su Discogs i dischi fotografati.

Le foto stanno in una cartella per grado (M, NM, VG+, VG, G+, G), una foto del
retro per disco, numerate: 0001.jpg, 0002.jpg... Il numero è quello scritto
sulla busta e diventa l'external_id dell'annuncio.
  0002_x3.jpg  -> 3 copie dello stesso disco, stesso grado
  0002_2.jpg   -> seconda foto facoltativa, usata solo se la prima non basta

Per ogni disco:
  1. legge il barcode (zxing-cpp) e, se serve, il numero di catalogo con l'OCR
     di macOS (ocrmac), e li cerca nel database di discogs_dump.py;
  2. se non lo trova in locale, lo cerca su Discogs via API (barcode, poi catno);
  3. prende il grado dal nome della cartella;
  4. chiede il prezzo suggerito a Discogs e aggiunge il ricarico;
  5. se trovato in locale -> una riga nel CSV di caricamento inventario con
     quantity = N (max 1.000 dischi per file); se trovato solo via API ->
     annuncio via API. L'API non ha un campo quantità: con N copie crea N
     annunci con external_id 0002-1, 0002-2...

Tutto lo stato è salvato in data/vendita_stato.sqlite: se lo script si
interrompe, rilanciando lo stesso comando riparte da dove era, senza annunci doppi.

Esempi:
    python3 vendi.py ~/Foto/Dischi --limite 20 --simula
    python3 vendi.py ~/Foto/Dischi
"""

import argparse
import csv
import datetime as dt
import json
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

import discogs_dump as dd

STATE_DB = dd.DATA_DIR / "vendita_stato.sqlite"
OUT_DIR = dd.BASE_DIR / "risultati"
ENV_FILE = dd.BASE_DIR / ".env"
API_URL = os.environ.get("DISCOGS_API_URL", "https://api.discogs.com")
USER_AGENT = "DiscogsVendita/1.0 (+https://github.com/Matteocosta1/Discogs)"

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".tif", ".tiff", ".webp"}
BARCODE_FORMATS = {"EAN13", "EAN8", "UPCA", "UPCE"}
ROWS_PER_FILE = 1000
MAX_CANDIDATES_SHOWN = 10

# Nome della cartella -> condizione come la vuole Discogs (CSV e API).
GRADES = {
    "M": "Mint (M)",
    "NM": "Near Mint (NM or M-)",
    "VG+": "Very Good Plus (VG+)",
    "VG": "Very Good (VG)",
    "G+": "Good Plus (G+)",
    "G": "Good (G)",
}

# Esiti del riconoscimento che finiscono nel file da controllare.
PROBLEMS = {"non_trovato", "multiplo", "senza_prezzo", "errore"}


def now():
    return dt.datetime.now().isoformat(timespec="seconds")


def natural_key(s):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", s)]


# --------------------------------------------------------------------------
# Foto e gradi
# --------------------------------------------------------------------------

def read_grades(folder_name):
    """(grado disco, grado copertina) dal nome della cartella, o None se non è un grado.

    Oggi il grado della cartella vale per entrambi ('VG+' -> VG+ e VG+).
    Per aggiungere un grado separato della copertina (es. 'VG+_VG') basta
    dividere qui il nome su '_' e controllare le due parti: il resto dello
    script usa già due gradi distinti.
    """
    grade = folder_name.strip().upper()
    if grade in GRADES:
        return grade, grade
    return None


@dataclass
class Disc:
    external_id: str          # numero della foto (es. "0002") = numero sulla busta
    folder: str
    media: str                # grado del disco (chiave di GRADES)
    sleeve: str               # grado della copertina (chiave di GRADES)
    photos: list = field(default_factory=list)  # foto principale ed eventuale _2
    quantity: int = 1         # copie dello stesso grado (_xN nel nome)

    def listing_ids(self):
        """external_id degli annunci via API: '0002' con una copia, '0002-1'... con più copie."""
        if self.quantity == 1:
            return [self.external_id]
        return [f"{self.external_id}-{i}" for i in range(1, self.quantity + 1)]

    def fingerprint(self):
        parts = [self.folder]
        for p in self.photos:
            st = p.stat()
            parts.append(f"{p.name}:{st.st_size}:{st.st_mtime_ns}")
        return "|".join(parts)


PHOTO_NAME_RE = re.compile(r"^(\d+)((?:_(?:[xX]\d+|2))*)$")


def parse_photo_name(stem):
    """'0002_x3_2' -> ('0002', quantità 3 o None, seconda foto True). None se il nome non è valido."""
    m = PHOTO_NAME_RE.match(stem)
    if not m:
        return None
    number, quantity, second = m.group(1), None, False
    for token in m.group(2).split("_")[1:]:
        if token == "2" and not second:
            second = True
        elif token[0] in "xX" and quantity is None and int(token[1:]) >= 1:
            quantity = int(token[1:])
        else:
            return None  # suffisso ripetuto o _x0
    return number, quantity, second


def scan_photos(root):
    """Trova i dischi nelle cartelle dei gradi. Si ferma subito se qualcosa non va."""
    root = Path(root).expanduser()
    if not root.is_dir():
        raise SystemExit(f"Cartella non trovata: {root}")
    discs, errors, warnings = [], [], []
    seen = {}
    for sub in sorted(root.iterdir()):
        if sub.name.startswith("."):
            continue
        if not sub.is_dir():
            if sub.suffix.lower() in IMAGE_EXTS:
                warnings.append(f"foto fuori dalle cartelle dei gradi, ignorata: {sub.name}")
            continue
        grades = read_grades(sub.name)
        if not grades:
            errors.append(f"la cartella '{sub.name}' non è un grado valido ({', '.join(GRADES)})")
            continue
        groups = {}  # numero -> {"main": [...], "second": [...], "qty": set()}
        for f in sorted(sub.iterdir()):
            if not f.is_file() or f.name.startswith(".") or f.suffix.lower() not in IMAGE_EXTS:
                continue
            parsed = parse_photo_name(f.stem)
            if not parsed:
                errors.append(f"{sub.name}/{f.name}: nome non valido (usa 0001.jpg, 0001_x3.jpg, 0001_2.jpg)")
                continue
            number, quantity, second = parsed
            g = groups.setdefault(number, {"main": [], "second": [], "qty": set()})
            g["second" if second else "main"].append(f)
            if quantity:
                g["qty"].add(quantity)
        for number, g in groups.items():
            where = f"{sub.name}/{number}"
            if not g["main"]:
                errors.append(f"{where}: c'è la seconda foto ma manca la foto principale")
                continue
            if len(g["main"]) > 1 or len(g["second"]) > 1:
                names = ", ".join(f.name for f in g["main"] + g["second"])
                errors.append(f"{where}: troppe foto per lo stesso disco ({names})")
                continue
            if len(g["qty"]) > 1:
                errors.append(f"{where}: quantità diverse nei nomi delle foto ({', '.join(f'x{q}' for q in sorted(g['qty']))})")
                continue
            if number in seen:
                errors.append(f"il numero {number} è in due cartelle: {seen[number]} e {sub.name}")
                continue
            seen[number] = sub.name
            quantity = g["qty"].pop() if g["qty"] else 1
            discs.append(Disc(number, sub.name, grades[0], grades[1], g["main"] + g["second"], quantity))
    if errors:
        raise SystemExit("Sistema prima le cartelle delle foto:\n  " + "\n  ".join(errors))
    discs.sort(key=lambda d: natural_key(d.external_id))
    return discs, warnings


# --------------------------------------------------------------------------
# Lettura locale: barcode e OCR (librerie gratuite, niente servizi esterni)
# --------------------------------------------------------------------------

def load_image(path):
    from PIL import Image, ImageOps
    try:
        import pillow_heif  # foto HEIC dell'iPhone
        pillow_heif.register_heif_opener()
    except ImportError:
        pass
    img = Image.open(path)
    img = ImageOps.exif_transpose(img)
    return img.convert("RGB")


def read_barcodes(img):
    import zxingcpp
    found = []
    candidates = [img]
    if max(img.size) > 2000:
        small = img.copy()
        small.thumbnail((1600, 1600))
        candidates.append(small)
    for candidate in candidates:
        for r in zxingcpp.read_barcodes(candidate):
            fmt = getattr(r.format, "name", str(r.format)).upper().replace("-", "").replace("_", "")
            if fmt in BARCODE_FORMATS and r.text and r.text not in found:
                found.append(r.text)
        if found:
            break
    return found


def ocr_available():
    try:
        import ocrmac  # noqa: F401
        return True
    except ImportError:
        return False


def ocr_lines(img):
    """Righe di testo lette con il riconoscimento testo di macOS (Vision)."""
    from ocrmac import ocrmac
    return [text for text, _conf, _box in ocrmac.OCR(img, recognition_level="accurate").recognize()]


YEAR_RE = re.compile(r"^(19|20)\d\d$")


def catno_candidates(lines):
    """Possibili numeri di catalogo nel testo: {normalizzato: testo originale}."""
    found = {}
    for line in lines:
        tokens = re.findall(r"[A-Za-z0-9][A-Za-z0-9.\-/]*", line)
        for i in range(len(tokens)):
            for n in (1, 2, 3):  # "SHVL 804", "2C 062-04512"...
                if i + n > len(tokens):
                    break
                raw = " ".join(tokens[i:i + n])
                norm = dd.normalize_catno(raw)
                if not (3 <= len(norm) <= 20) or not any(c.isdigit() for c in norm):
                    continue
                if norm.isdigit() and (len(norm) < 4 or len(norm) >= 12 or YEAR_RE.match(norm)):
                    continue  # troppo corto, un anno o un barcode
                found.setdefault(norm, raw)
    return found


def is_strong_catno(norm):
    return len(norm) >= 4 and any(c.isdigit() for c in norm) and any(c.isalpha() for c in norm)


def label_in_text(label, text):
    """True se il nome dell'etichetta compare nel testo letto dall'OCR."""
    label = re.sub(r" \(\d+\)$", "", label or "")
    compact = re.sub(r"[^a-z0-9]", "", label.lower())
    text_compact = re.sub(r"[^a-z0-9]", "", text.lower())
    if len(compact) >= 3 and compact in text_compact:
        return True
    words = [w for w in re.findall(r"[a-z0-9]+", label.lower()) if len(w) >= 3]
    return bool(words) and words[0] in set(re.findall(r"[a-z0-9]+", text.lower()))


@dataclass
class Evidence:
    barcodes: list = field(default_factory=list)
    catnos: dict = field(default_factory=dict)   # normalizzato -> originale
    text: str = ""
    ocr_done: bool = False

    def describe(self):
        bits = []
        if self.barcodes:
            bits.append("barcode letti: " + ", ".join(self.barcodes))
        else:
            bits.append("nessun barcode letto")
        strong = [raw for norm, raw in self.catnos.items() if is_strong_catno(norm)]
        if strong:
            bits.append("catno possibili: " + ", ".join(strong[:8]))
        elif self.ocr_done:
            bits.append("nessun catno riconoscibile")
        if self.ocr_done and self.text:
            bits.append("testo: " + " / ".join(self.text.splitlines())[:200])
        return "; ".join(bits)


# --------------------------------------------------------------------------
# Ricerca nel database locale (funzioni di discogs_dump.py)
# --------------------------------------------------------------------------

def local_catno_matches(con, ev):
    """Release il cui catno è nel testo E la cui etichetta compare nel testo."""
    confirmed, unconfirmed = {}, {}
    for norm in ev.catnos:
        for r in dd.search_by_catno(con, norm):
            if label_in_text(r["catno_label"], ev.text):
                confirmed[r["id"]] = r
            elif is_strong_catno(norm):
                unconfirmed[r["id"]] = r
    return confirmed, unconfirmed


def search_local(con, ev):
    """(fonte, candidati) cercando prima per barcode, poi per catno + etichetta."""
    by_barcode = {}
    for b in ev.barcodes:
        for r in dd.search_by_barcode(con, b):
            by_barcode[r["id"]] = r
    if by_barcode:
        candidates = by_barcode
        if len(candidates) > 1 and ev.catnos:
            # stesso barcode per più stampe: restringo con il catno letto dall'OCR
            confirmed, unconfirmed = local_catno_matches(con, ev)
            narrowed = {k: v for k, v in candidates.items() if k in confirmed or k in unconfirmed}
            if narrowed:
                candidates = narrowed
        return "locale-barcode", list(candidates.values())
    if ev.catnos:
        confirmed, _ = local_catno_matches(con, ev)
        if confirmed:
            return "locale-catno", list(confirmed.values())
    return None, []


# --------------------------------------------------------------------------
# API Discogs
# --------------------------------------------------------------------------

class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(f"HTTP {status}: {message}")
        self.status = status
        self.message = message


class ApiUncertain(Exception):
    """Richiesta di creazione inviata ma esito sconosciuto (rete o errore del server)."""


def load_token():
    token = os.environ.get("DISCOGS_TOKEN", "").strip()
    if not token and ENV_FILE.exists():
        for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
            key, sep, value = line.partition("=")
            if sep and key.strip() == "DISCOGS_TOKEN":
                token = value.strip().strip('"').strip("'")
    if not token:
        raise SystemExit(
            f"Manca il token di Discogs. Crea il file {ENV_FILE} con la riga:\n"
            "  DISCOGS_TOKEN=il_tuo_token\n"
            "(il token si genera su https://www.discogs.com/settings/developers)"
        )
    return token


class DiscogsAPI:
    """Client minimo che rispetta il limite di 60 richieste al minuto."""

    MIN_INTERVAL = 1.05  # secondi tra una richiesta e l'altra (< 60 al minuto)

    def __init__(self, token):
        self._token = token
        self._next = 0.0
        self.calls = 0

    def _wait_turn(self):
        delay = self._next - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        self._next = time.monotonic() + self.MIN_INTERVAL

    def request(self, method, path, params=None, body=None):
        url = API_URL + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        headers = {
            "User-Agent": USER_AGENT,
            "Authorization": f"Discogs token={self._token}",
            "Accept": "application/json",
        }
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        for attempt in range(6):
            self._wait_turn()
            req = urllib.request.Request(url, data=data, method=method, headers=headers)
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    self.calls += 1
                    self._respect_remaining(resp.headers)
                    raw = resp.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as e:
                self.calls += 1
                self._respect_remaining(e.headers)
                if e.code == 429:  # troppe richieste: non è stato creato nulla, si può riprovare
                    print("  limite di richieste raggiunto, attendo 60 secondi...")
                    time.sleep(60)
                    continue
                if e.code >= 500:
                    if method == "POST":
                        raise ApiUncertain(f"errore del server {e.code}")
                    time.sleep(5 * (attempt + 1))
                    continue
                try:
                    message = json.loads(e.read() or b"{}").get("message", e.reason)
                except (ValueError, AttributeError):
                    message = e.reason
                raise ApiError(e.code, message)
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                if method == "POST":
                    raise ApiUncertain(str(e))
                time.sleep(5 * (attempt + 1))
        raise ApiError(0, f"nessuna risposta da Discogs per {path}")

    def _respect_remaining(self, headers):
        try:
            remaining = int(headers.get("X-Discogs-Ratelimit-Remaining", "60"))
        except (TypeError, ValueError):
            return
        if remaining <= 3:
            self._next = max(self._next, time.monotonic() + 15)

    def identity(self):
        return self.request("GET", "/oauth/identity")

    def search(self, **params):
        params = {"type": "release", "per_page": 25, **params}
        return self.request("GET", "/database/search", params)

    def price_suggestions(self, release_id):
        try:
            return self.request("GET", f"/marketplace/price_suggestions/{release_id}")
        except ApiError as e:
            if e.status == 404:
                return {}
            raise

    def create_listing(self, release_id, condition, sleeve_condition, price, external_id):
        return self.request("POST", "/marketplace/listings", body={
            "release_id": release_id,
            "condition": condition,
            "sleeve_condition": sleeve_condition,
            "price": price,
            "status": "For Sale",
            "external_id": external_id,
        })

    def inventory_page(self, username, page):
        return self.request("GET", f"/users/{urllib.parse.quote(username)}/inventory", {
            "sort": "listed", "sort_order": "desc", "per_page": 100, "page": page,
        })


def api_result_as_release(r):
    return {"id": r["id"], "artists": "", "title": r.get("title", ""), "labels": ", ".join(r.get("label", []))}


def search_api(api, ev):
    """(fonte, candidati) cercando su Discogs per barcode, poi per catno."""
    for b in ev.barcodes:
        res = api.search(barcode=b)
        results = {r["id"]: api_result_as_release(r) for r in res.get("results", [])}
        if results:
            return "api-barcode", list(results.values())
    strong = [(norm, raw) for norm, raw in ev.catnos.items() if is_strong_catno(norm)]
    strong.sort(key=lambda x: -len(x[0]))
    for _norm, raw in strong[:3]:  # al massimo 3 tentativi per non sprecare richieste
        res = api.search(catno=raw)
        confirmed = {
            r["id"]: api_result_as_release(r)
            for r in res.get("results", [])
            if any(label_in_text(l, ev.text) for l in r.get("label", []))
        }
        if confirmed:
            return "api-catno", list(confirmed.values())
    return None, []


# --------------------------------------------------------------------------
# Riconoscimento di un disco
# --------------------------------------------------------------------------

@dataclass
class Recognition:
    esito: str                 # trovato / multiplo / non_trovato / errore
    fonte: str = ""
    release_id: int = None
    candidates: list = field(default_factory=list)
    details: str = ""


def recognize(disc, con, api, use_ocr):
    ev = Evidence()
    fonte, candidates = None, []
    for photo in disc.photos:  # la seconda foto solo se la prima non basta
        img = load_image(photo)
        for b in read_barcodes(img):
            if b not in ev.barcodes:
                ev.barcodes.append(b)
        fonte, candidates = search_local(con, ev)
        if len(candidates) == 1:
            break
        if use_ocr:
            lines = ocr_lines(img)
            ev.ocr_done = True
            ev.text = (ev.text + "\n" + "\n".join(lines)).strip()
            for norm, raw in catno_candidates(lines).items():
                ev.catnos.setdefault(norm, raw)
            fonte, candidates = search_local(con, ev)
            if len(candidates) == 1:
                break

    if not candidates:
        fonte, candidates = search_api(api, ev)

    details = ev.describe()
    if len(candidates) == 1:
        return Recognition("trovato", fonte, candidates[0]["id"], candidates, details)
    if candidates:
        return Recognition("multiplo", fonte, None, candidates, details)
    _, unconfirmed = local_catno_matches(con, ev) if ev.catnos else ({}, {})
    if unconfirmed:
        details += "; catno presente nel database ma etichetta non riconosciuta nella foto"
        return Recognition("non_trovato", "", None, list(unconfirmed.values()), details)
    return Recognition("non_trovato", "", None, [], details)


def format_candidates(candidates):
    out = []
    for c in candidates[:MAX_CANDIDATES_SHOWN]:
        name = " - ".join(x for x in (c.get("artists"), c.get("title")) if x)
        out.append(f"{c['id']} {name} https://www.discogs.com/release/{c['id']}")
    if len(candidates) > MAX_CANDIDATES_SHOWN:
        out.append(f"... e altre {len(candidates) - MAX_CANDIDATES_SHOWN}")
    return " | ".join(out)


# --------------------------------------------------------------------------
# Stato (ripresa dopo un'interruzione)
# --------------------------------------------------------------------------

STATE_SCHEMA = """
CREATE TABLE IF NOT EXISTS dischi (
    external_id TEXT PRIMARY KEY,   -- numero della foto
    cartella    TEXT,
    foto        TEXT,
    impronta    TEXT,
    media       TEXT,
    sleeve      TEXT,
    esito       TEXT,     -- trovato / multiplo / non_trovato / senza_prezzo / errore
    fonte       TEXT,     -- locale-barcode / locale-catno / api-barcode / api-catno
    release_id  INTEGER,
    candidati   TEXT,
    dettagli    TEXT,
    aggiornato  TEXT,
    quantita    INTEGER DEFAULT 1
);
CREATE TABLE IF NOT EXISTS prezzi (      -- prezzi suggeriti per release, tutti i gradi
    release_id INTEGER PRIMARY KEY,
    suggeriti  TEXT,
    ottenuto   TEXT
);
CREATE TABLE IF NOT EXISTS csv_righe (   -- dischi già assegnati a un file CSV
    external_id TEXT PRIMARY KEY,
    parte       INTEGER,
    release_id  INTEGER,
    price       REAL,
    media       TEXT,
    sleeve      TEXT,
    quantita    INTEGER DEFAULT 1
);
CREATE TABLE IF NOT EXISTS annunci (     -- annunci creati via API, uno per copia
    external_id TEXT PRIMARY KEY,   -- external_id dell'annuncio: 0002, oppure 0002-1, 0002-2...
    release_id  INTEGER,
    price       REAL,
    media       TEXT,
    sleeve      TEXT,
    stato       TEXT,     -- in_corso / pubblicato / rifiutato
    listing_id  INTEGER,
    messaggio   TEXT,
    inviato     TEXT,
    disco       TEXT,     -- numero della foto
    copie       INTEGER   -- quante copie aveva il disco quando è stato pubblicato
);
"""


def open_state(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(path)
    con.row_factory = sqlite3.Row
    con.executescript(STATE_SCHEMA)
    # Stato creato da una versione precedente dello script: aggiungo le colonne nuove.
    for table, column, decl in [("dischi", "quantita", "INTEGER DEFAULT 1"),
                                ("csv_righe", "quantita", "INTEGER DEFAULT 1"),
                                ("annunci", "disco", "TEXT"),
                                ("annunci", "copie", "INTEGER")]:
        if column not in {r["name"] for r in con.execute(f"PRAGMA table_info({table})")}:
            con.execute(f"ALTER TABLE {table} ADD COLUMN {column} {decl}")
    con.execute("UPDATE annunci SET disco = external_id, copie = 1 WHERE disco IS NULL")
    con.commit()
    return con


def get_price_suggestions(state, api, release_id, refresh=False):
    row = state.execute("SELECT suggeriti FROM prezzi WHERE release_id = ?", (release_id,)).fetchone()
    if row and not refresh:
        return json.loads(row["suggeriti"]), False
    sugg = api.price_suggestions(release_id)
    state.execute("INSERT OR REPLACE INTO prezzi VALUES (?, ?, ?)", (release_id, json.dumps(sugg), now()))
    state.commit()
    return sugg, True


def recover_pending_listings(state, api, username):
    """Annunci rimasti 'in_corso' per un'interruzione: controlla su Discogs se esistono già."""
    pending = state.execute("SELECT * FROM annunci WHERE stato = 'in_corso'").fetchall()
    if not pending:
        return
    print(f"Controllo su Discogs {len(pending)} annunci rimasti in sospeso dall'ultima esecuzione...")
    oldest = min(p["inviato"] for p in pending)
    cutoff = (dt.datetime.fromisoformat(oldest) - dt.timedelta(days=1)).date().isoformat()
    wanted = {p["external_id"] for p in pending}
    found, saw_external_id, page, seen_items = {}, False, 1, 0
    while wanted - set(found):
        data = api.inventory_page(username, page)
        items = data.get("listings", [])
        seen_items += len(items)
        for item in items:
            if "external_id" in item:
                saw_external_id = True
            if item.get("external_id") in wanted:
                found[item["external_id"]] = item["id"]
        pages = data.get("pagination", {}).get("pages", 1)
        if not items or page >= pages or (items[-1].get("posted", "")[:10] < cutoff):
            break
        page += 1
    for p in pending:
        eid = p["external_id"]
        if eid in found:
            state.execute("UPDATE annunci SET stato = 'pubblicato', listing_id = ? WHERE external_id = ?",
                          (found[eid], eid))
            print(f"  {eid}: l'annuncio esisteva già (listing {found[eid]})")
        elif saw_external_id or seen_items == 0:  # inventario vuoto: sicuramente non creato
            state.execute("DELETE FROM annunci WHERE external_id = ?", (eid,))
            print(f"  {eid}: annuncio non creato, verrà pubblicato ora")
        else:
            print(f"  {eid}: impossibile verificare, lo lascio da controllare a mano (niente doppioni)")
    state.commit()


# --------------------------------------------------------------------------
# File di uscita
# --------------------------------------------------------------------------

# Colonne del caricamento inventario di Discogs (i valori di status sono FOR_SALE o DRAFT).
CSV_HEADER = ["release_id", "price", "media_condition", "sleeve_condition", "quantity", "external_id", "status"]
CSV_STATUS = "FOR_SALE"
LISTING_HEADER = ["external_id", "numero", "release_id", "price", "media_condition", "sleeve_condition"]


def csv_row(release_id, price, media, sleeve, quantity, external_id):
    return [release_id, f"{price:.2f}", GRADES[media], GRADES[sleeve], quantity, external_id, CSV_STATUS]


def write_csv(path, header, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


def photo_name(path):
    """'VG+/0001.jpg' invece del percorso completo."""
    return f"{Path(path).parent.name}/{Path(path).name}" if path else ""


class PartAllocator:
    """Divide le righe del CSV in parti da massimo ROWS_PER_FILE dischi (contando le copie)."""

    def __init__(self, first_part):
        self.part, self.copies = first_part, 0

    def assign(self, quantity):
        if self.copies and self.copies + quantity > ROWS_PER_FILE:
            self.part, self.copies = self.part + 1, 0
        self.copies += quantity
        return self.part


REASONS = {
    "non_trovato": "non trovato né nel database locale né su Discogs",
    "multiplo": "più release possibili",
    "senza_prezzo": "nessun prezzo suggerito da Discogs",
    "errore": "errore durante l'elaborazione",
}
CHECK_HEADER = ["numero", "foto", "cartella", "quantita", "motivo", "dettagli", "candidati"]


def write_outputs(state, out_dir, simulated_csv, simulated_listings, extra_checks):
    out_dir.mkdir(parents=True, exist_ok=True)

    # CSV di inventario: ogni disco resta per sempre nella sua parte.
    parts = {}
    for r in state.execute("SELECT * FROM csv_righe"):
        parts.setdefault(r["parte"], []).append(r)
    for part, rows in parts.items():
        rows.sort(key=lambda r: natural_key(r["external_id"]))
        write_csv(out_dir / f"inventario_{part:03d}.csv", CSV_HEADER,
                  [csv_row(r["release_id"], r["price"], r["media"], r["sleeve"], r["quantita"], r["external_id"])
                   for r in rows])

    published = sorted(state.execute("SELECT * FROM annunci WHERE stato = 'pubblicato'").fetchall(),
                       key=lambda r: natural_key(r["external_id"]))
    write_csv(out_dir / "annunci_pubblicati_api.csv", LISTING_HEADER + ["listing_id", "link"],
              [[r["external_id"], r["disco"], r["release_id"], f"{r['price']:.2f}", GRADES[r["media"]],
                GRADES[r["sleeve"]], r["listing_id"], f"https://www.discogs.com/sell/item/{r['listing_id']}"]
               for r in published])

    # Da controllare a mano.
    rows = []
    for r in state.execute("SELECT * FROM dischi WHERE esito IN ({})".format(",".join("?" * len(PROBLEMS))),
                           sorted(PROBLEMS)):
        rows.append([r["external_id"], photo_name(r["foto"]), r["cartella"], r["quantita"], REASONS[r["esito"]],
                     r["dettagli"] or "", r["candidati"] or ""])
    for r in state.execute("SELECT a.*, d.foto, d.cartella FROM annunci a LEFT JOIN dischi d ON d.external_id = a.disco "
                           "WHERE a.stato IN ('in_corso', 'rifiutato')"):
        if r["stato"] == "in_corso":
            motivo = f"pubblicazione dell'annuncio {r['external_id']} non confermata: controlla su Discogs se esiste già"
        else:
            motivo = f"Discogs ha rifiutato l'annuncio {r['external_id']}"
        rows.append([r["disco"], photo_name(r["foto"]), r["cartella"], r["copie"], motivo,
                     f"release {r['release_id']}, prezzo {r['price']:.2f}; {r['messaggio'] or ''}",
                     f"https://www.discogs.com/release/{r['release_id']}"])
    rows.extend(extra_checks)
    rows.sort(key=lambda r: natural_key(r[0]))
    write_csv(out_dir / "da_controllare.csv", CHECK_HEADER, rows)

    if simulated_csv or simulated_listings:
        sim_dir = out_dir / "simulazione"
        for old in sim_dir.glob("inventario_*.csv"):
            old.unlink()
        parts, alloc = {}, PartAllocator(1)
        for row in simulated_csv:
            parts.setdefault(alloc.assign(row[4]), []).append(row)
        for part, part_rows in parts.items():
            write_csv(sim_dir / f"inventario_{part:03d}.csv", CSV_HEADER, part_rows)
        write_csv(sim_dir / "annunci_api_simulati.csv", LISTING_HEADER, simulated_listings)
    return len(rows)


# --------------------------------------------------------------------------
# Programma principale
# --------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Metti in vendita su Discogs i dischi fotografati")
    parser.add_argument("cartella", help="cartella che contiene le sottocartelle dei gradi (M, NM, VG+, VG, G+, G)")
    parser.add_argument("--ricarico", type=float, default=12.0, help="ricarico in %% sul prezzo suggerito (default 12)")
    parser.add_argument("--limite", type=int, help="elabora solo i primi N dischi (prova)")
    parser.add_argument("--simula", action="store_true",
                        help="non pubblica annunci via API e non modifica i CSV veri: scrive tutto in risultati/simulazione/")
    parser.add_argument("--riprova", action="store_true",
                        help="rianalizza anche i dischi finiti da controllare (non trovati, più release, senza prezzo)")
    parser.add_argument("--db", default=str(dd.DEFAULT_DB), help="database creato da discogs_dump.py")
    parser.add_argument("--uscita", default=str(OUT_DIR), help="cartella dei risultati (default: risultati/)")
    args = parser.parse_args()

    discs, warnings = scan_photos(args.cartella)
    for w in warnings:
        print(f"Attenzione: {w}")
    if args.limite:
        discs = discs[:args.limite]
    copies = sum(d.quantity for d in discs)
    print(f"Dischi da elaborare: {len(discs)} ({copies} copie)"
          + (" (SIMULAZIONE: nessun annuncio verrà pubblicato)" if args.simula else ""))

    con = dd.open_db(args.db)
    use_ocr = ocr_available()
    if not use_ocr:
        print("Attenzione: OCR non disponibile (serve macOS con 'pip install ocrmac'): uso solo il barcode.")
    api = DiscogsAPI(load_token())
    identity = api.identity()  # controlla subito che il token funzioni
    print(f"Collegato a Discogs come {identity.get('username')}")

    state = open_state(STATE_DB)
    if not args.simula:
        recover_pending_listings(state, api, identity["username"])

    max_part = state.execute("SELECT COALESCE(MAX(parte), 0) FROM csv_righe").fetchone()[0]
    parts = PartAllocator(max_part + 1)   # i dischi nuovi vanno sempre in file nuovi
    simulated_csv, simulated_listings, extra_checks = [], [], []
    stats = {"csv": 0, "csv_copie": 0, "api": 0, "problemi": 0, "gia_fatti": 0}
    price_calls = 0
    total = len(discs)

    def quantity_changed(disc, before):
        extra_checks.append([disc.external_id, photo_name(disc.photos[0]), disc.folder, disc.quantity,
                             f"quantità cambiata dopo la messa in vendita: erano {before} copie, ora {disc.quantity}; "
                             "l'annuncio esistente non è stato modificato", "", ""])

    try:
        for n, disc in enumerate(discs, 1):
            eid = disc.external_id
            qty_label = f" x{disc.quantity}" if disc.quantity > 1 else ""
            prefix = f"[{n}/{total}] {eid}{qty_label} ({disc.folder})"

            # Già nel CSV o già messo in vendita via API?
            done_csv = state.execute("SELECT quantita FROM csv_righe WHERE external_id = ?", (eid,)).fetchone()
            if done_csv:
                if done_csv["quantita"] != disc.quantity:
                    quantity_changed(disc, done_csv["quantita"])
                stats["gia_fatti"] += 1
                continue
            existing = state.execute("SELECT * FROM annunci WHERE disco = ?", (eid,)).fetchall()
            if existing:
                if existing[0]["copie"] != disc.quantity:
                    quantity_changed(disc, existing[0]["copie"])
                    stats["gia_fatti"] += 1
                    continue
                if len(existing) >= disc.quantity:
                    stats["gia_fatti"] += 1
                    continue
                # altrimenti: pubblicazione interrotta a metà, mancano delle copie

            row = state.execute("SELECT * FROM dischi WHERE external_id = ?", (eid,)).fetchone()
            fingerprint = disc.fingerprint()
            redo = (row is None or row["impronta"] != fingerprint or row["esito"] == "errore"
                    or (args.riprova and row["esito"] in PROBLEMS))
            if redo and not existing:
                try:
                    rec = recognize(disc, con, api, use_ocr)
                except (ApiError, OSError, ValueError) as e:
                    rec = Recognition("errore", details=str(e))
                state.execute(
                    "INSERT OR REPLACE INTO dischi (external_id, cartella, foto, impronta, media, sleeve, esito, fonte,"
                    " release_id, candidati, dettagli, aggiornato, quantita) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (eid, disc.folder, str(disc.photos[0]), fingerprint, disc.media, disc.sleeve,
                     rec.esito, rec.fonte, rec.release_id, format_candidates(rec.candidates), rec.details, now(),
                     disc.quantity),
                )
                state.commit()
                row = state.execute("SELECT * FROM dischi WHERE external_id = ?", (eid,)).fetchone()

            if row["esito"] not in ("trovato", "senza_prezzo"):
                stats["problemi"] += 1
                print(f"{prefix}: da controllare ({row['esito']})")
                continue

            release_id = row["release_id"]
            try:
                sugg, fetched = get_price_suggestions(
                    state, api, release_id, refresh=args.riprova and row["esito"] == "senza_prezzo")
            except ApiError as e:
                state.execute("UPDATE dischi SET esito = 'errore', dettagli = ? WHERE external_id = ?",
                              (f"prezzo: {e}", eid))
                state.commit()
                stats["problemi"] += 1
                print(f"{prefix}: errore nel prezzo ({e})")
                continue
            price_calls += fetched
            suggestion = sugg.get(GRADES[disc.media])
            if not suggestion or not suggestion.get("value"):
                state.execute("UPDATE dischi SET esito = 'senza_prezzo' WHERE external_id = ?", (eid,))
                state.commit()
                stats["problemi"] += 1
                print(f"{prefix}: release {release_id}, nessun prezzo suggerito per {disc.media}")
                continue
            if row["esito"] == "senza_prezzo":
                state.execute("UPDATE dischi SET esito = 'trovato' WHERE external_id = ?", (eid,))
            price = round(float(suggestion["value"]) * (1 + args.ricarico / 100), 2)
            if existing:  # copie mancanti di una pubblicazione interrotta: stesso prezzo delle altre
                price = existing[0]["price"]
            currency = suggestion.get("currency", "")
            info = f"release {release_id}, {price:.2f} {currency}"

            if row["fonte"].startswith("locale"):
                # Trovato in locale: una riga nel CSV con quantity = copie.
                if args.simula:
                    simulated_csv.append(csv_row(release_id, price, disc.media, disc.sleeve, disc.quantity, eid))
                else:
                    state.execute(
                        "INSERT INTO csv_righe (external_id, parte, release_id, price, media, sleeve, quantita)"
                        " VALUES (?,?,?,?,?,?,?)",
                        (eid, parts.assign(disc.quantity), release_id, price, disc.media, disc.sleeve, disc.quantity))
                state.commit()
                stats["csv"] += 1
                stats["csv_copie"] += disc.quantity
                print(f"{prefix}: {info} -> CSV (trovato in locale, {row['fonte'].split('-')[1]})")
                continue

            # Trovato solo via API: un annuncio per copia (l'API non ha un campo quantità).
            already = {r["external_id"] for r in existing}
            for listing_eid in disc.listing_ids():
                if listing_eid in already:
                    continue
                listing_info = [listing_eid, eid, release_id, f"{price:.2f}", GRADES[disc.media], GRADES[disc.sleeve]]
                if args.simula:
                    simulated_listings.append(listing_info)
                    stats["api"] += 1
                    print(f"{prefix}: {info} -> annuncio API {listing_eid} (simulato)")
                    continue
                state.execute(
                    "INSERT INTO annunci (external_id, release_id, price, media, sleeve, stato, inviato, disco, copie)"
                    " VALUES (?,?,?,?,?,'in_corso',?,?,?)",
                    (listing_eid, release_id, price, disc.media, disc.sleeve, now(), eid, disc.quantity))
                state.commit()  # segnato PRIMA di inviare: niente doppioni se si interrompe
                try:
                    resp = api.create_listing(release_id, GRADES[disc.media], GRADES[disc.sleeve], price, listing_eid)
                except ApiUncertain as e:
                    print(f"{prefix}: esito della pubblicazione di {listing_eid} incerto ({e}), "
                          "verrà controllato al prossimo avvio")
                    continue
                except ApiError as e:
                    state.execute("UPDATE annunci SET stato = 'rifiutato', messaggio = ? WHERE external_id = ?",
                                  (str(e), listing_eid))
                    state.commit()
                    stats["problemi"] += 1
                    print(f"{prefix}: annuncio {listing_eid} rifiutato da Discogs ({e})")
                    continue
                state.execute("UPDATE annunci SET stato = 'pubblicato', listing_id = ? WHERE external_id = ?",
                              (resp.get("listing_id"), listing_eid))
                state.commit()
                stats["api"] += 1
                print(f"{prefix}: {info} -> annuncio {listing_eid} pubblicato via API (listing {resp.get('listing_id')})")
    except KeyboardInterrupt:
        print("\nInterrotto. Rilancia lo stesso comando per riprendere da qui.")
    finally:
        out_dir = Path(args.uscita).expanduser()
        to_check = write_outputs(state, out_dir, simulated_csv, simulated_listings, extra_checks)
        print()
        print("Riepilogo di questa esecuzione")
        print(f"  nel CSV di inventario:  {stats['csv']} dischi ({stats['csv_copie']} copie)")
        print(f"  annunci via API{' (simulati)' if args.simula else ''}: {stats['api']}")
        print(f"  da controllare:         {stats['problemi'] + len(extra_checks)}")
        print(f"  già fatti in precedenza: {stats['gia_fatti']}")
        print(f"  richieste API: {api.calls} (di cui prezzi: {price_calls})")
        print(f"Risultati in {out_dir}/  (righe in da_controllare.csv: {to_check})")
        if args.simula:
            print(f"Simulazione in {out_dir / 'simulazione'}/")
        state.close()
        con.close()


if __name__ == "__main__":
    main()
