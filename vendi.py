#!/usr/bin/env python3
"""
Mette in vendita su Discogs i dischi fotografati.

Struttura: Dischi/<grado>/<foto>, con i gradi M, NM, VG+, VG, G+, G e le foto
con i nomi originali dell'iPhone (JPG o HEIC). Ogni foto è una copia; il nome
del file senza estensione è l'external_id.

  1. riconosce ogni foto (fronte, retro o etichetta), senza interventi manuali:
     a. parte locale gratuita: barcode (zxing-cpp), testo con l'OCR di macOS
        (ocrmac), ricerca nel database di discogs_dump.py per barcode, catno +
        etichetta, artista + titolo; se il risultato è sicuro, niente AI;
     b. altrimenti un modello AI con visione dice cosa vede nella foto;
     c. con quei dati cerca i candidati nel database e, se non ci sono, su
        Discogs via API;
     d. l'AI sceglie tra i candidati reali (mai inventati) e la scelta deve
        combaciare con artista e titolo letti nella foto;
     l'AI ha un tetto di spesa totale e i suoi risultati restano in cache;
  2. raggruppa le foto della stessa release con lo stesso grado: sono copie
     dello stesso disco;
  3. chiede il prezzo suggerito a Discogs e aggiunge il ricarico; calcola un
     punteggio collezionistico (want/have, copie in vendita, prezzo più basso,
     caratteristiche della stampa, prezzo suggerito): se il disco è
     collezionistico usa il più alto tra suggerito e prezzo più basso in vendita,
     con un ricarico maggiore, e lo elenca in collezionistici.csv;
  4. trovato in locale -> una riga nel CSV di caricamento inventario con
     quantity = numero di foto (max 1.000 dischi per file);
     trovato solo via API -> un annuncio via API per foto (l'API non ha un
     campo quantità), con external_id = nome della foto.

Tutto lo stato è salvato in data/vendita_stato.sqlite: se lo script si
interrompe, rilanciando lo stesso comando riparte da dove era, senza annunci doppi.

Esempi:
    python3 vendi.py ~/Pictures/Dischi --limite 20 --simula
    python3 vendi.py ~/Pictures/Dischi
"""

import argparse
import csv
import datetime as dt
import json
import os
import re
import sqlite3
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

IMAGE_EXTS = {".jpg", ".jpeg", ".heic", ".heif", ".png"}
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
class Photo:
    path: Path
    folder: str
    media: str                # grado del disco (chiave di GRADES)
    sleeve: str               # grado della copertina (chiave di GRADES)

    @property
    def external_id(self):
        return self.path.stem  # es. "IMG_1234"

    @property
    def name(self):
        return f"{self.folder}/{self.path.name}"

    def fingerprint(self):
        st = self.path.stat()
        return f"{self.folder}|{self.path.name}|{st.st_size}|{st.st_mtime_ns}"


def scan_photos(root):
    """Trova le foto nelle cartelle dei gradi. Si ferma subito se qualcosa non va."""
    root = Path(root).expanduser()
    if not root.is_dir():
        raise SystemExit(f"Cartella non trovata: {root}")
    photos, errors, warnings = [], [], []
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
        for f in sorted(sub.iterdir()):
            if f.is_file() and not f.name.startswith(".") and f.suffix.lower() in IMAGE_EXTS:
                photos.append(Photo(f, sub.name, grades[0], grades[1]))
    # Il nome della foto è l'external_id: deve essere unico in tutte le cartelle.
    by_id = {}
    for p in photos:
        by_id.setdefault(p.external_id, []).append(p.name)
    for eid, names in by_id.items():
        if len(names) > 1:
            errors.append(f"nome ripetuto {eid}: {', '.join(names)} (rinomina una delle foto)")
    if errors:
        raise SystemExit("Sistema prima le cartelle delle foto:\n  " + "\n  ".join(errors))
    photos.sort(key=lambda p: natural_key(p.external_id))
    return photos, warnings


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
    """Righe lette con il riconoscimento testo di macOS (Vision): lista di (testo, altezza).
    L'altezza (0-1, rispetto alla foto) serve a capire quali scritte sono più grandi:
    di solito artista e titolo."""
    from ocrmac import ocrmac
    out = []
    for text, _conf, box in ocrmac.OCR(img, recognition_level="accurate").recognize():
        height = box[3] if box and len(box) >= 4 else 0
        out.append((text, float(height or 0)))
    return out


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
    compact = re.sub(r"[^a-z0-9]", "", dd.normalize_text(label))
    text_compact = re.sub(r"[^a-z0-9]", "", dd.normalize_text(text))
    if len(compact) >= 3 and compact in text_compact:
        return True
    words = [w for w in dd.normalize_text(label).split() if len(w) >= 3 and w not in STOPWORDS]
    return bool(words) and words[0] in set(dd.normalize_text(text).split())


# Parole frequenti su copertine ed etichette che non aiutano a trovare artista e titolo.
STOPWORDS = set("""
the a an and of in on to for by with from at is are
il lo la le i gli un una di da del della dei delle e ed per con su tra fra al alla
side lato facciata stereo mono quadraphonic rpm giri lp ep single album
record records recording recordings disc disco dischi vinyl vinile
made printed manufactured distributed marketed produced producer arranged
all rights reserved unauthorized copying ltd inc co srl spa gmbh corp company
copyright music musica edizioni publishing www com it net
""".split())

# Parole nella foto -> paese come lo scrive Discogs.
COUNTRY_WORDS = {
    "italy": "Italy", "italia": "Italy",
    "uk": "UK", "england": "UK", "britain": "UK",
    "germany": "Germany", "deutschland": "Germany",
    "france": "France", "usa": "US", "japan": "Japan",
    "holland": "Netherlands", "netherlands": "Netherlands",
    "spain": "Spain", "espana": "Spain", "canada": "Canada", "europe": "Europe",
}


@dataclass
class Evidence:
    barcodes: list = field(default_factory=list)
    catnos: dict = field(default_factory=dict)   # normalizzato -> originale
    lines: list = field(default_factory=list)    # (testo, altezza) letti dall'OCR (o dall'AI)
    ocr_done: bool = False
    ai_note: str = ""

    @property
    def text(self):
        return "\n".join(t for t, _h in self.lines)

    def add_lines(self, lines):
        self.lines.extend(lines)
        for norm, raw in catno_candidates([t for t, _h in lines]).items():
            self.catnos.setdefault(norm, raw)
        self.ocr_done = True

    def describe(self):
        bits = []
        if self.ai_note:
            bits.append(self.ai_note)
        bits.append("barcode letti: " + ", ".join(self.barcodes) if self.barcodes else "nessun barcode letto")
        strong = [raw for norm, raw in self.catnos.items() if is_strong_catno(norm)]
        if strong:
            bits.append("catno possibili: " + ", ".join(strong[:8]))
        if self.ocr_done and self.lines:
            bits.append("testo: " + " / ".join(self.text.splitlines())[:250])
        elif self.ocr_done:
            bits.append("nessun testo letto")
        return "; ".join(bits)


# --------------------------------------------------------------------------
# Punteggio dei candidati: quanto i dati della release combaciano con la foto
# --------------------------------------------------------------------------

class TextMatcher:
    """Confronto tollerante agli errori di lettura tra parole di una release e testo della foto."""

    def __init__(self, text):
        self.words = set(dd.normalize_text(text).split())
        self.compact = re.sub(r"[^a-z0-9]", "", dd.normalize_text(text))
        self.years = {int(y) for y in re.findall(r"\b(19[4-9]\d|20[0-3]\d)\b", text)}
        self.countries = {c for w, c in COUNTRY_WORDS.items() if w in self.words}
        self._cache = {}

    def word_found(self, word):
        """1 se la parola è nel testo, un valore tra 0.8 e 1 se c'è una parola molto simile, 0 altrimenti."""
        if word in self.words:
            return 1.0
        if word not in self._cache:
            import difflib
            close = difflib.get_close_matches(word, self.words, n=1, cutoff=0.8) if len(word) >= 4 else []
            self._cache[word] = difflib.SequenceMatcher(None, word, close[0]).ratio() if close else 0.0
        return self._cache[word]

    def coverage(self, value):
        """Parte (0-1) delle parole di value ritrovate nel testo, pesate per lunghezza."""
        words = [w for w in dd.normalize_text(value).split() if w not in STOPWORDS] or dd.normalize_text(value).split()
        if not words:
            return 0.0
        compact = re.sub(r"[^a-z0-9]", "", dd.normalize_text(value))
        if len(compact) >= 6 and compact in self.compact:  # es. "PINKFLOYD" scritto senza spazi
            return 1.0
        total = sum(len(w) for w in words)
        return sum(len(w) * self.word_found(w) for w in words) / total


def score_candidates(candidates, ev):
    """Candidati ordinati per punteggio: [(punteggio, release, motivi)]."""
    m = TextMatcher(ev.text)
    ranked = []
    for r in candidates:
        artist = re.sub(r"\s*\(\d+\)", "", r.get("artists") or "")
        various = dd.normalize_text(artist) in ("various", "")
        artist_cov = 1.0 if various else m.coverage(artist)
        title_cov = m.coverage(r.get("title") or "")
        score = (artist_cov + title_cov) / 2
        why = [f"artista {artist_cov:.0%}", f"titolo {title_cov:.0%}"]
        r["_coverage"] = (artist_cov, title_cov)
        if any(label_in_text(l, ev.text) for l in r.get("label_names", [])):
            score += 0.15
            why.append("etichetta")
        if any(c in ev.catnos for c in r.get("catno_norms", [])):
            score += 0.3
            why.append("catno")
        if r.get("year") and r["year"] in m.years:
            score += 0.1
            why.append("anno")
        if r.get("country") and r["country"] in m.countries:
            score += 0.05
            why.append("paese")
        ranked.append((round(score, 3), r, why))
    ranked.sort(key=lambda x: -x[0])
    return ranked


def clear_winner(ranked, min_score=0.0):
    """La release migliore se è chiaramente davanti alle altre, altrimenti None."""
    if not ranked or ranked[0][0] < min_score:
        return None
    if len(ranked) == 1 or ranked[0][0] - ranked[1][0] >= CLEAR_MARGIN:
        return ranked[0][1]
    return None


CLEAR_MARGIN = 0.15      # distacco minimo dal secondo per accettare il primo
TEXT_MIN_SCORE = 0.9     # punteggio minimo per un riconoscimento solo da artista e titolo
TEXT_MIN_COVERAGE = 0.75


# --------------------------------------------------------------------------
# Ricerca nel database locale (funzioni di discogs_dump.py)
# --------------------------------------------------------------------------

def local_catno_matches(con, ev):
    """Release il cui catno è nel testo: (con etichetta confermata nel testo, senza conferma)."""
    confirmed, unconfirmed = {}, {}
    for norm in ev.catnos:
        for r in dd.search_by_catno(con, norm):
            if label_in_text(r["catno_label"], ev.text):
                confirmed[r["id"]] = r
            elif is_strong_catno(norm):
                unconfirmed[r["id"]] = r
    return confirmed, unconfirmed


def search_barcode_local(con, ev):
    ids = []
    for b in ev.barcodes:
        ids += [r["id"] for r in dd.search_by_barcode(con, b)]
    return [{**r, "_code": True} for r in dd.get_releases(con, ids)]


def search_catno_local(con, ev):
    confirmed, _ = local_catno_matches(con, ev)
    return [{**r, "_code": True} for r in dd.get_releases(con, list(confirmed))]


def text_lines_for_search(con, ev, max_lines=10):
    """Righe di testo utili per cercare artista e titolo: parole normalizzate, senza parole
    inutili, corrette dagli errori di lettura più comuni; prima le scritte più grandi."""
    vocab = {}

    def known(w):
        if w not in vocab:
            vocab[w] = dd.word_frequency(con, w)
        return vocab[w] > 0

    def fix(word):
        if known(word):
            return word
        for a, b in OCR_CONFUSIONS:
            if a in word:
                alt = word.replace(a, b)
                if known(alt):
                    return alt
        return None  # parola letta male o inesistente: la salto

    seen, out = set(), []
    for text, height in sorted(ev.lines, key=lambda x: -x[1]):
        # "ARTISTA - TITOLO" su una riga sola: provo anche le due parti
        pieces = [text] + [p for p in re.split(r"\s[-–—:/]\s|\s*[•·|]\s*", text) if p != text]
        for piece in pieces:
            words = [w for w in dd.normalize_text(piece).split()
                     if w not in STOPWORDS and len(w) >= 2 and not w.isdigit()]
            words = [f for f in (fix(w) for w in words) if f]
            key = " ".join(words)
            if 1 <= len(words) <= 8 and key not in seen:
                seen.add(key)
                out.append(words)
        if len(out) >= max_lines:
            break
    return out[:max_lines]


OCR_CONFUSIONS = [("0", "o"), ("1", "l"), ("1", "i"), ("5", "s"), ("8", "b"), ("rn", "m"), ("vv", "w")]


def search_text_local(con, ev):
    """Candidati cercando artista e titolo tra le righe lette nella foto."""
    lines = text_lines_for_search(con, ev)
    ids = []
    for words in lines:  # artista e titolo sulla stessa riga (o titolo omonimo)
        found, truncated = dd.search_by_words(con, any_words=words, limit=200)
        if not truncated:
            ids += found
    for a in lines:      # artista su una riga, titolo su un'altra
        for t in lines:
            if a is not t:
                found, _ = dd.search_by_words(con, artist_words=a, title_words=t, limit=200)
                ids += found
        if len(ids) > 3000:
            break
    return dd.get_releases(con, ids[:3000])


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


def load_env_value(key, what, where):
    """Valore di key dall'ambiente o dal file .env (mai scritto nel codice)."""
    value = os.environ.get(key, "").strip()
    if not value and ENV_FILE.exists():
        for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
            k, sep, v = line.partition("=")
            if sep and k.strip() == key:
                value = v.strip().strip('"').strip("'")
    if not value:
        raise SystemExit(f"Manca {what}. Aggiungi al file {ENV_FILE} la riga:\n  {key}=...\n(si genera su {where})")
    return value


def load_token():
    return load_env_value("DISCOGS_TOKEN", "il token di Discogs", "https://www.discogs.com/settings/developers")


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

    def release(self, release_id):
        return self.request("GET", f"/releases/{release_id}")

    def marketplace_stats(self, release_id, currency):
        params = {"curr_abbr": currency} if currency else None
        return self.request("GET", f"/marketplace/stats/{release_id}", params)

    def inventory_page(self, username, page):
        return self.request("GET", f"/users/{urllib.parse.quote(username)}/inventory", {
            "sort": "listed", "sort_order": "desc", "per_page": 100, "page": page,
        })


def api_result_as_release(r):
    """Risultato della ricerca Discogs nello stesso formato delle release del database locale."""
    artist, _, title = (r.get("title") or "").partition(" - ")
    year = str(r.get("year") or "")
    return {
        "id": r["id"], "artists": artist.strip() if title else "", "title": (title or artist).strip(),
        "labels": ", ".join(r.get("label", [])), "label_names": r.get("label", []),
        "catno_norms": [dd.normalize_catno(r.get("catno", ""))] if r.get("catno") else [],
        "country": r.get("country", ""), "year": int(year) if year.isdigit() else None,
        "formats": ", ".join(r.get("format", [])), "barcodes": r.get("barcode", [])[:3], "_fonte": "api",
    }


def search_api(api, ev, artist_titles=()):
    """(fonte, candidati) cercando su Discogs per barcode, poi per catno, poi per artista e titolo."""
    for b in ev.barcodes:
        res = api.search(barcode=b)
        results = {r["id"]: {**api_result_as_release(r), "_code": True} for r in res.get("results", [])}
        if results:
            return "api-barcode", list(results.values())
    strong = [(norm, raw) for norm, raw in ev.catnos.items() if is_strong_catno(norm)]
    strong.sort(key=lambda x: -len(x[0]))
    for _norm, raw in strong[:3]:  # al massimo 3 tentativi per non sprecare richieste
        res = api.search(catno=raw)
        confirmed = {
            r["id"]: {**api_result_as_release(r), "_code": True}
            for r in res.get("results", [])
            if any(label_in_text(l, ev.text) for l in r.get("label", []))
        }
        if confirmed:
            return "api-catno", list(confirmed.values())
    for artist, title in artist_titles:
        params = {"release_title": title}
        if artist:
            params["artist"] = artist
        res = api.search(**params)
        results = {r["id"]: api_result_as_release(r) for r in res.get("results", [])}
        if results:
            return "api-testo", list(results.values())
    return None, []


# --------------------------------------------------------------------------
# AI con visione: entra solo quando la parte locale non è sicura
# --------------------------------------------------------------------------

# Prezzi in dollari per milione di token (input, output). Per prudenza il tetto
# di spesa conta 1 $ = 1 €, quindi la spesa reale in euro è un po' più bassa.
AI_MODELS = {
    "claude-haiku-4-5": (1.00, 5.00),
    "claude-sonnet-5": (2.00, 10.00),
    "claude-opus-5": (5.00, 25.00),
}
AI_MAX_EDGE = 1568          # lato lungo massimo della foto inviata (pixel)
AI_MAX_CANDIDATES = 40      # candidati mostrati all'AI per la scelta finale

AI_READ_PROMPT = """This photo shows ONE vinyl record: its front cover, back cover or centre label.
Report what you can see. Transcribe printed details exactly; use an empty string when something is not clearly readable. Never guess printed details.
- photo_type: front, back, label or other.
- artist, title, label, catno (catalogue number, e.g. "SHVL 804"), year (e.g. after ℗ or ©), country (where made/printed), barcode (digits).
- readable_text: the most useful readable text, one item per line (titles, credits, codes, label, company names), at most 40 lines.
- recognized_artist / recognized_title: if you recognise the record from its artwork or overall look, the artist and album you believe it is, even if not printed; otherwise empty."""

AI_READ_SCHEMA = {
    "type": "object",
    "properties": {
        "photo_type": {"type": "string", "enum": ["front", "back", "label", "other"]},
        **{k: {"type": "string"} for k in ("artist", "title", "label", "catno", "year", "country", "barcode",
                                          "readable_text", "recognized_artist", "recognized_title")},
    },
    "required": ["photo_type", "artist", "title", "label", "catno", "year", "country", "barcode",
                 "readable_text", "recognized_artist", "recognized_title"],
    "additionalProperties": False,
}

AI_CHOOSE_PROMPT = """This photo shows ONE vinyl record (front cover, back cover or centre label).
Below is a list of candidate Discogs releases. Choose the one this record is.
Compare every visible clue: artist, title, label, catalogue number, barcode, country, year, format, artwork.
If the exact pressing cannot be determined, choose the most likely one based on the visible clues and set confidence to "low".
Only answer with an id from the list. Answer 0 only if NONE of the candidates is this record (different artist or album).

Candidates (id | artist | title | label (catno) | country | year | format | barcodes):
{candidates}"""

AI_CHOOSE_SCHEMA = {
    "type": "object",
    "properties": {
        "release_id": {"type": "integer"},
        "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
        "reason": {"type": "string"},
    },
    "required": ["release_id", "confidence", "reason"],
    "additionalProperties": False,
}
CONFIDENCE_IT = {"high": "alta", "medium": "media", "low": "bassa"}


class BudgetReached(Exception):
    """Il tetto di spesa AI non permette un'altra chiamata."""


class AIVision:
    """Chiamate al modello con visione, con tetto di spesa totale (in euro, 1 $ = 1 €)."""

    def __init__(self, model, budget_eur, spent_eur):
        import anthropic  # libreria ufficiale di Anthropic
        self.client = anthropic.Anthropic(api_key=load_env_value(
            "ANTHROPIC_API_KEY", "la chiave API di Anthropic (serve per l'AI; per farne a meno usa --senza-ai)",
            "https://console.anthropic.com/settings/keys"))
        self.model = model
        self.price_in, self.price_out = AI_MODELS[model]
        self.budget = budget_eur
        self.spent = spent_eur

    @staticmethod
    def prepare(img):
        """Foto ridotta e compressa, pronta da inviare: (base64, token stimati)."""
        import base64
        import io
        small = img.copy()
        small.thumbnail((AI_MAX_EDGE, AI_MAX_EDGE))
        buf = io.BytesIO()
        small.save(buf, format="JPEG", quality=85)
        return base64.standard_b64encode(buf.getvalue()).decode(), small.size[0] * small.size[1] / 750

    def _call(self, image, prompt, schema, max_tokens, extra_input_tokens=0):
        data, image_tokens = image
        max_cost = ((image_tokens + extra_input_tokens + 600) * self.price_in + max_tokens * self.price_out) / 1e6
        if self.spent + max_cost > self.budget:
            raise BudgetReached()
        response = self.client.messages.create(
            model=self.model,
            max_tokens=max_tokens,
            messages=[{"role": "user", "content": [
                {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": data}},
                {"type": "text", "text": prompt},
            ]}],
            output_config={"format": {"type": "json_schema", "schema": schema}},
        )
        cost = (response.usage.input_tokens * self.price_in + response.usage.output_tokens * self.price_out) / 1e6
        self.spent += cost
        text = next((b.text for b in response.content if b.type == "text"), "")
        try:
            result = json.loads(text) if response.stop_reason == "end_turn" else {}
        except ValueError:
            result = {}
        return result, cost

    def read(self, image):
        """Cosa vede l'AI nella foto (passo 2)."""
        data, cost = self._call(image, AI_READ_PROMPT, AI_READ_SCHEMA, 1200)
        return {k: (v.strip() if isinstance(v, str) else v) for k, v in data.items()}, cost

    def choose(self, image, candidates):
        """Quale candidato è il disco della foto (passo 4)."""
        lines = []
        for r in candidates:
            label = f"{r.get('labels') or ', '.join(r.get('label_names', []))}"
            lines.append(" | ".join(str(x) for x in (
                r["id"], clean_artist(r.get("artists")), r.get("title"), label, r.get("country") or "",
                r.get("year") or "", r.get("formats") or "", ", ".join(r.get("barcodes", [])[:3]))))
        text = "\n".join(lines)
        return self._call(image, AI_CHOOSE_PROMPT.format(candidates=text), AI_CHOOSE_SCHEMA, 400,
                          extra_input_tokens=len(text) // 3)


def clean_artist(artist):
    return re.sub(r"\s*\(\d+\)", "", artist or "")


def ai_evidence(ev, data):
    """Aggiunge ai dati letti localmente quelli letti dall'AI."""
    if data.get("barcode"):
        digits = re.sub(r"\D", "", data["barcode"])
        if len(digits) >= 8 and digits not in ev.barcodes:
            ev.barcodes.append(digits)
    # artista e titolo come scritte "grandi", il resto come testo normale
    lines = [(data[k], 1.0) for k in ("artist", "title", "recognized_artist", "recognized_title") if data.get(k)]
    lines += [(data[k], 0.0) for k in ("label", "catno", "year", "country") if data.get(k)]
    if data.get("catno") and data.get("label"):
        lines.append((f"{data['label']} {data['catno']}", 0.0))
    lines += [(t, 0.0) for t in (data.get("readable_text") or "").splitlines() if t.strip()]
    ev.add_lines(lines)
    shown = {k: v for k, v in data.items() if v and k != "readable_text"}
    ev.ai_note = "letto dall'AI: " + ", ".join(f"{k}={v}" for k, v in shown.items())


def ai_artist_titles(data):
    """Coppie (artista, titolo) lette o riconosciute dall'AI, per la ricerca su Discogs."""
    pairs = []
    for a, t in ((data.get("artist"), data.get("title")),
                 (data.get("recognized_artist"), data.get("recognized_title"))):
        if t and (a, t) not in pairs:
            pairs.append((a or "", t))
    return pairs


def coherent(release, ai_data, ocr_text):
    """Regola di sicurezza: artista e titolo della release devono combaciare con quelli
    letti o riconosciuti dall'AI, oppure con il testo letto dall'OCR.
    Per le release trovate con un codice letto nella foto (barcode o catno) basta che
    l'AI non indichi un artista o un titolo diversi."""
    ai_data = ai_data or {}
    names = "\n".join(ai_data.get(k, "") for k in ("artist", "title", "recognized_artist", "recognized_title"))
    ai_text = names + "\n" + ai_data.get("readable_text", "")
    if release.get("_code") and not names.strip():
        return True
    artist = clean_artist(release.get("artists"))
    various = dd.normalize_text(artist) in ("various", "")
    for text in (ai_text, ocr_text):
        if not text.strip():
            continue
        m = TextMatcher(text)
        if (various or m.coverage(artist) >= TEXT_MIN_COVERAGE) and m.coverage(release.get("title") or "") >= TEXT_MIN_COVERAGE:
            return True
    return False


# --------------------------------------------------------------------------
# Riconoscimento di una foto
# --------------------------------------------------------------------------

@dataclass
class Recognition:
    esito: str                 # trovato / multiplo / non_trovato / errore / sospeso (tetto di spesa)
    fonte: str = ""            # es. locale-barcode, ai+locale-testo, ai-scelta+api
    release: dict = None
    candidates: list = field(default_factory=list)   # [(punteggio, release, motivi)]
    details: str = ""
    ai_cost: float = 0.0
    ai_read: dict = None
    ai_choice: dict = None

    @property
    def release_id(self):
        return self.release["id"] if self.release else None


def recognize_local(con, ev, img, use_ocr):
    """Ricerca locale. Restituisce (fonte, release sicura o None, candidati ordinati)."""
    ranked = []
    # barcode
    if img is not None:
        for b in read_barcodes(img):
            if b not in ev.barcodes:
                ev.barcodes.append(b)
    found = search_barcode_local(con, ev)
    if len(found) == 1:
        return "locale-barcode", found[0], score_candidates(found, ev)
    if img is not None and use_ocr and not ev.ocr_done:
        ev.add_lines(ocr_lines(img))
    if found:  # stesso barcode per più stampe: scelgo con gli altri dati della foto
        ranked = score_candidates(found, ev)
        return "locale-barcode", clear_winner(ranked), ranked
    # numero di catalogo + etichetta
    found = search_catno_local(con, ev)
    if found:
        ranked = score_candidates(found, ev)
        return "locale-catno", clear_winner(ranked), ranked
    # artista e titolo, ricerca tollerante agli errori di lettura
    if ev.lines:
        ranked = [x for x in score_candidates(search_text_local(con, ev), ev)
                  if min(x[1]["_coverage"]) >= TEXT_MIN_COVERAGE]
        return "locale-testo", clear_winner(ranked, TEXT_MIN_SCORE), ranked
    return "", None, []


def merge_ranked(*lists):
    seen, out = set(), []
    for ranked in lists:
        for x in ranked:
            if x[1]["id"] not in seen:
                seen.add(x[1]["id"])
                out.append(x)
    return out


def recognize(path, con, api, use_ocr, ai=None, cache=None):
    """Riconosce il disco di una foto. cache: dati AI già pagati per questa foto
    ({"read": ..., "choice": ...}), che non vengono mai richiesti di nuovo."""
    cache = dict(cache or {})
    ev = Evidence()
    img = load_image(path)

    # 1. Parte locale: se il risultato è sicuro, niente AI
    fonte, release, ranked = recognize_local(con, ev, img, use_ocr)
    if release is not None:
        return Recognition("trovato", fonte, release, ranked, ev.describe())
    ocr_text = ev.text

    # Nulla in locale ma c'è un codice leggibile: prima la ricerca gratuita su Discogs
    if not ranked:
        api_fonte, found = search_api(api, ev)
        if len(found) == 1:
            return Recognition("trovato", api_fonte, found[0], [], ev.describe())
        if found:
            fonte, ranked = api_fonte, score_candidates(found, ev)

    if ai is None and not cache.get("read"):  # --senza-ai: solo metodi gratuiti
        if ranked:
            return Recognition("multiplo", fonte, None, ranked, ev.describe())
        return Recognition("non_trovato", "", None, [], ev.describe())

    # 2. L'AI guarda la foto e dice cosa vede
    cost = 0.0
    image = AIVision.prepare(img) if ai is not None else None
    read = cache.get("read")
    if read is None:
        read, c = ai.read(image)
        cost += c
    ai_evidence(ev, read)

    # 3. Di nuovo la parte locale, con i dati dell'AI; se non trova nulla, Discogs via API
    a_fonte, a_release, a_ranked = recognize_local(con, ev, None, use_ocr)
    ranked = merge_ranked(a_ranked, score_candidates([r for _s, r, _w in ranked], ev))
    ranked.sort(key=lambda x: -x[0])
    base = a_fonte or fonte
    if not ranked:
        base, found = search_api(api, ev, ai_artist_titles(read))
        local = {r["id"]: r for r in dd.get_releases(con, [r["id"] for r in found])}
        ranked = score_candidates([{**local[r["id"]], "_code": r.get("_code")} if r["id"] in local else r
                                   for r in found], ev)
    ranked = [x for x in ranked if coherent(x[1], read, ocr_text)]  # l'AI non può inventare
    if not ranked:
        return Recognition("non_trovato", "", None, [], ev.describe() + "; nessun candidato coerente con la foto",
                           cost, read)

    def source(r):
        return "api" if r.get("_fonte") == "api" else "locale"

    # Un solo candidato coerente, o un vincitore chiaro: niente seconda chiamata
    if a_release is not None and coherent(a_release, read, ocr_text):
        return Recognition("trovato", "ai+" + a_fonte, a_release, ranked, ev.describe(), cost, read)
    if len(ranked) == 1:
        r = ranked[0][1]
        return Recognition("trovato", f"ai+{source(r)}-{(base or 'testo').split('-')[-1]}", r, ranked,
                           ev.describe(), cost, read)

    # 4. L'AI sceglie tra i candidati reali
    shortlist = [r for _s, r, _w in ranked[:AI_MAX_CANDIDATES]]
    ids = [r["id"] for r in shortlist]
    choice = cache.get("choice")
    if choice is not None and choice.get("release_id") not in ids and choice.get("_ids") != ids:
        choice = None  # i candidati sono cambiati (es. database aggiornato): la scelta va rifatta
    if choice is None:
        if image is None:  # scelta non in cache e AI spenta: resta da controllare
            return Recognition("multiplo", base, None, ranked, ev.describe(), cost, read)
        try:
            choice, c = ai.choose(image, shortlist)
        except BudgetReached:  # la lettura è già pagata: la salvo e mi fermo
            return Recognition("sospeso", base, None, ranked, ev.describe(), cost, read)
        cost += c
        choice["_ids"] = ids
    chosen = next((r for r in shortlist if r["id"] == choice.get("release_id")), None)
    details = ev.describe()
    if choice.get("reason"):
        details += f"; scelta AI ({CONFIDENCE_IT.get(choice.get('confidence'), '?')}): {choice['reason']}"
    if chosen is None:
        return Recognition("non_trovato", base, None, ranked, details + "; l'AI non ha trovato il disco tra i candidati",
                           cost, read, choice)
    return Recognition("trovato", f"ai-scelta+{source(chosen)}", chosen, ranked, details, cost, read, choice)


def describe_release(r):
    if not r:
        return ""
    extra = " ".join(str(x) for x in (r.get("labels"), r.get("country"), r.get("year")) if x)
    return f"{clean_artist(r.get('artists'))} - {r.get('title')} ({extra})"


def format_candidates(ranked):
    out = []
    for score, c, why in ranked[:MAX_CANDIDATES_SHOWN]:
        points = f" [punteggio {score:.2f}: {', '.join(why)}]" if why else ""
        out.append(f"{c['id']} {describe_release(c)}{points} https://www.discogs.com/release/{c['id']}")
    if len(ranked) > MAX_CANDIDATES_SHOWN:
        out.append(f"... e altre {len(ranked) - MAX_CANDIDATES_SHOWN}")
    return " | ".join(out)


# --------------------------------------------------------------------------
# Valore collezionistico
# --------------------------------------------------------------------------

# Caratteristiche speciali della stampa (dai formati Discogs) e punti assegnati.
SPECIAL_FEATURES = [
    ("Test Pressing", r"\btest pressing\b", 3),
    ("Numbered", r"\bnumbered\b", 2),
    ("Limited Edition", r"\blimited edition\b", 1),
    ("Promo", r"\b(promo|white label)\b", 1),
    ("First Press", r"\b(first|1st) press(ing)?\b", 1),
    ("Vinile colorato", r"\b(colou?red|red|blue|green|yellow|white|clear|transparent|orange|purple|pink|gold|"
                        r"silver|grey|gray|brown|marbled?|splatter|swirl|translucent|smoke|violet)\b", 1),
]


def special_features(formats):
    """Caratteristiche speciali trovate nel testo dei formati (es. 'Vinyl, LP, Limited Edition, Red')."""
    text = (formats or "").lower()
    found = []
    for name, pattern, points in SPECIAL_FEATURES:
        # "White Label" indica una promo, non un vinile colorato
        target = text.replace("white label", "") if name == "Vinile colorato" else text
        if re.search(pattern, target):
            found.append((name, points))
    return found


def api_formats_text(release):
    """Formati di una release dell'API Discogs nello stesso testo del database locale."""
    parts = []
    for f in release.get("formats", []):
        bits = [f.get("name", "")] + list(f.get("descriptions", []))
        if f.get("text"):
            bits.append(f["text"])
        parts.append(", ".join(b for b in bits if b))
    return "; ".join(parts)


def get_collector_data(state, api, con, release_id, currency):
    """Dati per il valore collezionistico di una release, dalla cache o da Discogs (2 richieste).
    want/have dalla release, copie in vendita e prezzo più basso dalle statistiche del marketplace,
    caratteristiche della stampa dal database locale (o dall'API se la release non c'è)."""
    row = state.execute("SELECT dati FROM collezione WHERE release_id = ?", (release_id,)).fetchone()
    if row:
        return json.loads(row["dati"]), False
    release = api.release(release_id)
    community = release.get("community", {})
    stats = api.marketplace_stats(release_id, currency)
    lowest = stats.get("lowest_price") or {}
    local = dd.get_releases(con, [release_id])
    data = {
        "want": community.get("want") or 0,
        "have": community.get("have") or 0,
        "num_for_sale": stats.get("num_for_sale") or 0,
        "lowest_price": lowest.get("value"),
        "lowest_currency": lowest.get("currency") or currency,
        "formats": local[0]["formats"] if local else api_formats_text(release),
    }
    state.execute("INSERT OR REPLACE INTO collezione VALUES (?, ?, ?)", (release_id, json.dumps(data), now()))
    state.commit()
    return data, True


def collector_score(data, suggested, price_threshold):
    """(punteggio, motivi) del valore collezionistico."""
    score, reasons = 0, []
    want, have = data["want"], data["have"]
    if want >= 20 and have:  # sotto le 20 persone il rapporto non è significativo
        ratio = want / have
        points = 3 if ratio >= 3 else 2 if ratio >= 1.5 else 1 if ratio >= 0.8 else 0
        if points:
            score += points
            reasons.append(f"want/have {want}/{have} = {ratio:.1f} (+{points})")
    if want >= 20:
        n = data["num_for_sale"]
        points = 2 if n == 0 else 1 if n <= 3 else 0
        if points:
            score += points
            reasons.append(f"{'nessuna copia' if n == 0 else f'solo {n} copie'} in vendita (+{points})")
    lowest = data.get("lowest_price")
    if lowest and lowest >= price_threshold:
        score += 1
        reasons.append(f"prezzo più basso in vendita {lowest:.2f} (+1)")
    for name, points in special_features(data.get("formats")):
        score += points
        reasons.append(f"{name} (+{points})")
    if suggested >= price_threshold:
        score += 2
        reasons.append(f"prezzo suggerito {suggested:.2f} ≥ {price_threshold:.0f} (+2)")
    return score, reasons


# --------------------------------------------------------------------------
# Stato (ripresa dopo un'interruzione)
# --------------------------------------------------------------------------

STATE_SCHEMA = """
CREATE TABLE IF NOT EXISTS foto (
    external_id TEXT PRIMARY KEY,   -- nome della foto senza estensione
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
    riga_csv    TEXT,     -- external_id della riga CSV in cui è finita la foto
    ai_dati     TEXT,     -- cosa ha letto l'AI nella foto (mai richiesto due volte)
    ai_costo    REAL DEFAULT 0,  -- spesa AI per questa foto (euro, 1 $ = 1 €)
    ai_scelta   TEXT,     -- scelta dell'AI tra i candidati, con sicurezza e motivo
    disco       TEXT      -- artista - titolo (etichetta, paese, anno) della release trovata
);
CREATE TABLE IF NOT EXISTS collezione (  -- dati per il valore collezionistico, per release
    release_id INTEGER PRIMARY KEY,
    dati       TEXT,
    ottenuto   TEXT
);
CREATE TABLE IF NOT EXISTS collezionistici (  -- dischi risultati collezionistici e messi in vendita
    external_id TEXT PRIMARY KEY,   -- external_id della riga CSV o del primo annuncio
    release_id  INTEGER,
    media       TEXT,
    quantita    INTEGER,
    foto        TEXT,
    disco       TEXT,
    punteggio   INTEGER,
    motivi      TEXT,
    suggerito   REAL,
    piu_basso   REAL,
    prezzo      REAL,
    valuta      TEXT,
    destinazione TEXT
);
CREATE TABLE IF NOT EXISTS prezzi (      -- prezzi suggeriti per release, tutti i gradi
    release_id INTEGER PRIMARY KEY,
    suggeriti  TEXT,
    ottenuto   TEXT
);
CREATE TABLE IF NOT EXISTS righe_csv (   -- righe già assegnate a un file CSV
    external_id TEXT PRIMARY KEY,   -- nome della prima foto del gruppo
    parte       INTEGER,
    release_id  INTEGER,
    price       REAL,
    media       TEXT,
    sleeve      TEXT,
    quantita    INTEGER,
    foto        TEXT      -- tutte le foto del gruppo
);
CREATE TABLE IF NOT EXISTS annunci_api ( -- annunci creati via API, uno per foto
    external_id TEXT PRIMARY KEY,   -- nome della foto
    release_id  INTEGER,
    price       REAL,
    media       TEXT,
    sleeve      TEXT,
    stato       TEXT,     -- in_corso / pubblicato / rifiutato
    listing_id  INTEGER,
    messaggio   TEXT,
    inviato     TEXT
);
"""


def open_state(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(path)
    con.row_factory = sqlite3.Row
    con.executescript(STATE_SCHEMA)
    for column, decl in [("ai_dati", "TEXT"), ("ai_costo", "REAL DEFAULT 0"), ("ai_scelta", "TEXT"),
                         ("disco", "TEXT")]:  # stato di una versione precedente
        if column not in {r["name"] for r in con.execute("PRAGMA table_info(foto)")}:
            con.execute(f"ALTER TABLE foto ADD COLUMN {column} {decl}")
    old = con.execute("SELECT name FROM sqlite_master WHERE name IN ('annunci', 'csv_righe')").fetchall()
    if any(con.execute(f"SELECT COUNT(*) FROM {r['name']}").fetchone()[0] for r in old):
        print("Attenzione: lo stato contiene dati della versione precedente (foto numerate), che vengono ignorati.\n"
              "Se avevi già pubblicato annunci con quella versione, controllali su Discogs.")
    return con


def is_local_source(fonte):
    """True se la release è stata trovata nel database locale (anche dopo la lettura dell'AI)."""
    return (fonte or "").split("+")[-1].startswith("locale")


def money(eur):
    return f"{eur:.2f} €" if eur >= 1 else f"{eur:.3f} €"


def is_assigned(state, external_id):
    """True se la foto è già in una riga CSV o ha già un annuncio via API."""
    row = state.execute("SELECT riga_csv FROM foto WHERE external_id = ?", (external_id,)).fetchone()
    if row and row["riga_csv"]:
        return True
    return state.execute("SELECT 1 FROM annunci_api WHERE external_id = ?", (external_id,)).fetchone() is not None


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
    pending = state.execute("SELECT * FROM annunci_api WHERE stato = 'in_corso'").fetchall()
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
            state.execute("UPDATE annunci_api SET stato = 'pubblicato', listing_id = ? WHERE external_id = ?",
                          (found[eid], eid))
            print(f"  {eid}: l'annuncio esisteva già (listing {found[eid]})")
        elif saw_external_id or seen_items == 0:  # inventario vuoto: sicuramente non creato
            state.execute("DELETE FROM annunci_api WHERE external_id = ?", (eid,))
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
LISTING_HEADER = ["external_id", "release_id", "price", "media_condition", "sleeve_condition"]


def csv_row(release_id, price, media, sleeve, quantity, external_id):
    return [release_id, f"{price:.2f}", GRADES[media], GRADES[sleeve], quantity, external_id, CSV_STATUS]


def write_csv(path, header, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


def photo_name(path):
    """'VG+/IMG_1234.HEIC' invece del percorso completo."""
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
CHECK_HEADER = ["foto", "cartella", "motivo", "dettagli", "candidati"]


COLLECTOR_HEADER = ["external_id", "release_id", "grado", "quantita", "foto", "disco", "punteggio", "motivi",
                    "prezzo_suggerito", "prezzo_piu_basso_in_vendita", "prezzo_finale", "valuta", "destinazione", "link"]


def collector_csv_rows(rows):
    out = []
    for r in rows:
        r = list(r)
        r[8] = f"{r[8]:.2f}"
        r[9] = f"{r[9]:.2f}" if r[9] else ""
        r[10] = f"{r[10]:.2f}"
        out.append(r + [f"https://www.discogs.com/release/{r[1]}"])
    out.sort(key=lambda r: -int(r[6]))
    return out


def write_outputs(state, out_dir, simulated_csv, simulated_listings, simulated_collectors=()):
    out_dir.mkdir(parents=True, exist_ok=True)

    # CSV di inventario: ogni riga resta per sempre nella sua parte.
    parts = {}
    for r in state.execute("SELECT * FROM righe_csv"):
        parts.setdefault(r["parte"], []).append(r)
    for part, rows in parts.items():
        rows.sort(key=lambda r: natural_key(r["external_id"]))
        write_csv(out_dir / f"inventario_{part:03d}.csv", CSV_HEADER,
                  [csv_row(r["release_id"], r["price"], r["media"], r["sleeve"], r["quantita"], r["external_id"])
                   for r in rows])
    # Quali foto sono finite in ogni riga (per ritrovare le copie).
    all_rows = sorted(state.execute("SELECT * FROM righe_csv").fetchall(),
                      key=lambda r: (r["parte"], natural_key(r["external_id"])))
    write_csv(out_dir / "inventario_foto.csv", ["file", "external_id", "release_id", "quantity", "foto"],
              [[f"inventario_{r['parte']:03d}.csv", r["external_id"], r["release_id"], r["quantita"], r["foto"]]
               for r in all_rows])

    published = sorted(state.execute("SELECT * FROM annunci_api WHERE stato = 'pubblicato'").fetchall(),
                       key=lambda r: natural_key(r["external_id"]))
    write_csv(out_dir / "annunci_pubblicati_api.csv", LISTING_HEADER + ["listing_id", "link"],
              [[r["external_id"], r["release_id"], f"{r['price']:.2f}", GRADES[r["media"]], GRADES[r["sleeve"]],
                r["listing_id"], f"https://www.discogs.com/sell/item/{r['listing_id']}"] for r in published])

    # Da controllare a mano.
    rows = []
    for r in state.execute("SELECT * FROM foto WHERE esito IN ({})".format(",".join("?" * len(PROBLEMS))),
                           sorted(PROBLEMS)):
        rows.append([photo_name(r["foto"]), r["cartella"], REASONS[r["esito"]],
                     r["dettagli"] or "", r["candidati"] or ""])
    for r in state.execute("SELECT a.*, f.foto, f.cartella FROM annunci_api a "
                           "LEFT JOIN foto f USING (external_id) WHERE a.stato IN ('in_corso', 'rifiutato')"):
        if r["stato"] == "in_corso":
            motivo = "pubblicazione non confermata: controlla su Discogs se l'annuncio esiste già"
        else:
            motivo = "Discogs ha rifiutato l'annuncio"
        rows.append([photo_name(r["foto"]), r["cartella"], motivo,
                     f"release {r['release_id']}, prezzo {r['price']:.2f}; {r['messaggio'] or ''}",
                     f"https://www.discogs.com/release/{r['release_id']}"])
    rows.sort(key=lambda r: natural_key(r[0]))
    write_csv(out_dir / "da_controllare.csv", CHECK_HEADER, rows)

    # Come è stata riconosciuta ogni foto, con la spesa AI per disco.
    recog = []
    for r in state.execute("SELECT * FROM foto"):
        choice = json.loads(r["ai_scelta"]) if r["ai_scelta"] and r["esito"] == "trovato" else {}
        recog.append([photo_name(r["foto"]), r["cartella"], r["esito"], r["fonte"] or "", r["release_id"] or "",
                      r["disco"] or "", CONFIDENCE_IT.get(choice.get("confidence"), ""), choice.get("reason", ""),
                      f"{r['ai_costo'] or 0:.4f}"])
    recog.sort(key=lambda r: natural_key(Path(r[0]).name))
    write_csv(out_dir / "riconoscimento.csv",
              ["foto", "cartella", "esito", "metodo", "release_id", "disco", "sicurezza_ai", "motivo_ai", "costo_ai_eur"],
              recog)

    write_csv(out_dir / "collezionistici.csv", COLLECTOR_HEADER,
              collector_csv_rows(tuple(r) for r in state.execute("SELECT * FROM collezionistici")))

    if simulated_csv or simulated_listings or simulated_collectors:
        sim_dir = out_dir / "simulazione"
        write_csv(sim_dir / "collezionistici.csv", COLLECTOR_HEADER, collector_csv_rows(simulated_collectors))
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
    parser.add_argument("--ricarico-collezionistico", type=float, default=25.0,
                        help="ricarico in %% per i dischi collezionistici (default 25)")
    parser.add_argument("--soglia-prezzo", type=float, default=50.0,
                        help="prezzo (nella valuta del tuo account, di solito euro) oltre il quale un disco "
                             "conta come di valore (default 50)")
    parser.add_argument("--soglia-collezionistico", type=int, default=4,
                        help="punteggio minimo per considerare un disco collezionistico (default 4)")
    parser.add_argument("--limite", type=int, help="elabora solo le prime N foto (prova)")
    parser.add_argument("--simula", action="store_true",
                        help="non pubblica annunci via API e non modifica i CSV veri: scrive tutto in risultati/simulazione/")
    parser.add_argument("--riprova", action="store_true",
                        help="rianalizza anche le foto finite da controllare (non trovate, più release, senza prezzo)")
    parser.add_argument("--senza-ai", action="store_true",
                        help="non usa l'AI: solo riconoscimento locale gratuito (le foto incerte vanno da controllare)")
    parser.add_argument("--ai-tetto", type=float, default=50.0,
                        help="spesa AI massima in euro, sommando tutte le esecuzioni (default 50); raggiunta, lo script si ferma")
    parser.add_argument("--ai-modello", default="claude-haiku-4-5", choices=sorted(AI_MODELS),
                        help="modello AI (default claude-haiku-4-5, il più economico)")
    parser.add_argument("--db", default=str(dd.DEFAULT_DB), help="database creato da discogs_dump.py")
    parser.add_argument("--uscita", default=str(OUT_DIR), help="cartella dei risultati (default: risultati/)")
    args = parser.parse_args()

    photos, warnings = scan_photos(args.cartella)
    for w in warnings:
        print(f"Attenzione: {w}")
    if args.limite:
        photos = photos[:args.limite]
    print(f"Foto da elaborare: {len(photos)}" + (" (SIMULAZIONE: nessun annuncio verrà pubblicato)" if args.simula else ""))

    con = dd.open_db(args.db)
    use_ocr = ocr_available()
    if not use_ocr:
        print("Attenzione: OCR non disponibile (serve macOS con 'pip install ocrmac'): uso solo il barcode.")
    api = DiscogsAPI(load_token())
    identity = api.identity()  # controlla subito che il token funzioni
    print(f"Collegato a Discogs come {identity.get('username')}")

    state = open_state(STATE_DB)
    ai = None
    ai_spent_before = state.execute("SELECT COALESCE(SUM(ai_costo), 0) FROM foto").fetchone()[0]
    if not args.senza_ai:
        ai = AIVision(args.ai_modello, args.ai_tetto, ai_spent_before)
        print(f"AI ({args.ai_modello}) usata solo quando la parte locale non basta: "
              f"spesa finora {money(ai_spent_before)}, tetto {money(args.ai_tetto)}")
    if not args.simula:
        recover_pending_listings(state, api, identity["username"])

    max_part = state.execute("SELECT COALESCE(MAX(parte), 0) FROM righe_csv").fetchone()[0]
    parts = PartAllocator(max_part + 1)   # le righe nuove vanno sempre in file nuovi
    simulated_csv, simulated_listings, simulated_collectors = [], [], []
    stats = {"collezionistici": 0, "righe_csv": 0, "copie_csv": 0, "api": 0, "problemi": 0, "gia_fatte": 0}
    price_calls = 0
    total = len(photos)
    budget_stop = False

    try:
        # 1. Riconoscimento di ogni foto (i risultati restano salvati).
        todo = []
        for n, photo in enumerate(photos, 1):
            eid = photo.external_id
            prefix = f"[{n}/{total}] {photo.name}"
            if is_assigned(state, eid):
                stats["gia_fatte"] += 1
                continue
            row = state.execute("SELECT * FROM foto WHERE external_id = ?", (eid,)).fetchone()
            fingerprint = photo.fingerprint()
            same_photo = row is not None and row["impronta"] == fingerprint
            cache = {"read": json.loads(row["ai_dati"]) if same_photo and row["ai_dati"] else None,
                     "choice": json.loads(row["ai_scelta"]) if same_photo and row["ai_scelta"] else None}
            if (not same_photo or row["esito"] in ("errore", "sospeso")
                    or (args.riprova and row["esito"] in PROBLEMS)
                    or (ai and row["esito"] in ("non_trovato", "multiplo") and cache["read"] is None)):
                try:
                    rec = recognize(photo.path, con, api, use_ocr, ai, cache)
                except BudgetReached:
                    budget_stop = True
                    break
                except (ApiError, OSError, ValueError) as e:
                    rec = Recognition("errore", details=str(e), ai_read=cache["read"], ai_choice=cache["choice"])
                except Exception as e:  # errori dell'API di Anthropic
                    if type(e).__module__.split(".")[0] != "anthropic":
                        raise
                    rec = Recognition("errore", details=f"AI: {e}", ai_read=cache["read"], ai_choice=cache["choice"])
                old_cost = row["ai_costo"] if same_photo and row["ai_costo"] else 0.0
                state.execute(
                    "INSERT OR REPLACE INTO foto (external_id, cartella, foto, impronta, media, sleeve, esito, fonte,"
                    " release_id, candidati, dettagli, aggiornato, ai_dati, ai_costo, ai_scelta, disco)"
                    " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (eid, photo.folder, str(photo.path), fingerprint, photo.media, photo.sleeve, rec.esito, rec.fonte,
                     rec.release_id, format_candidates(rec.candidates), rec.details, now(),
                     json.dumps(rec.ai_read) if rec.ai_read is not None else None, old_cost + rec.ai_cost,
                     json.dumps(rec.ai_choice) if rec.ai_choice is not None else None, describe_release(rec.release)),
                )
                state.commit()
                row = state.execute("SELECT * FROM foto WHERE external_id = ?", (eid,)).fetchone()
                if rec.esito == "trovato":
                    how = row["fonte"]
                    if rec.ai_choice and rec.ai_choice.get("confidence"):
                        how += f", sicurezza {CONFIDENCE_IT.get(rec.ai_choice['confidence'], '?')}"
                    print(f"{prefix}: {row['disco']} [release {row['release_id']}, {how}]")
                else:
                    print(f"{prefix}: {row['esito']}")
                if rec.esito == "sospeso":
                    budget_stop = True
                    break
            if row["esito"] in ("trovato", "senza_prezzo"):
                todo.append((photo, row))
            elif row["esito"] != "sospeso":
                stats["problemi"] += 1

        # 2. Stessa release e stesso grado = copie dello stesso disco: un unico annuncio.
        groups = {}
        for photo, row in todo:
            groups.setdefault((row["release_id"], photo.media, photo.sleeve), []).append((photo, row))

        for (release_id, media, sleeve), members in groups.items():
            names = ", ".join(p.external_id for p, _ in members)
            label = f"release {release_id} {media}" + (f" x{len(members)}" if len(members) > 1 else "")
            refresh = args.riprova and any(r["esito"] == "senza_prezzo" for _, r in members)
            try:
                sugg, fetched = get_price_suggestions(state, api, release_id, refresh=refresh)
            except ApiError as e:
                for p, _ in members:
                    state.execute("UPDATE foto SET esito = 'errore', dettagli = ? WHERE external_id = ?",
                                  (f"prezzo: {e}", p.external_id))
                state.commit()
                stats["problemi"] += len(members)
                print(f"{label} ({names}): errore nel prezzo ({e})")
                continue
            price_calls += fetched
            suggestion = sugg.get(GRADES[media])
            new_esito = "trovato" if suggestion and suggestion.get("value") else "senza_prezzo"
            for p, _ in members:
                state.execute("UPDATE foto SET esito = ? WHERE external_id = ?", (new_esito, p.external_id))
            state.commit()
            if new_esito == "senza_prezzo":
                stats["problemi"] += len(members)
                print(f"{label} ({names}): nessun prezzo suggerito per {media}")
                continue
            suggested = float(suggestion["value"])
            currency = suggestion.get("currency", "")

            # Valore collezionistico (2 richieste per release, poi in cache)
            collector = None
            try:
                cdata, fetched = get_collector_data(state, api, con, release_id, currency)
                price_calls += fetched * 2
                score, reasons = collector_score(cdata, suggested, args.soglia_prezzo)
                if score >= args.soglia_collezionistico:
                    lowest = cdata.get("lowest_price") if cdata.get("lowest_currency") == currency else None
                    collector = (score, reasons, lowest)
            except ApiError as e:
                print(f"{label} ({names}): dati collezionistici non disponibili ({e}), prezzo normale")

            if collector:
                base = max(suggested, collector[2] or 0)
                price = round(base * (1 + args.ricarico_collezionistico / 100), 2)
            else:
                price = round(suggested * (1 + args.ricarico / 100), 2)
            info = f"{label} ({names}): {price:.2f} {currency}" + (f" [COLLEZIONISTICO, punteggio {collector[0]}]"
                                                                    if collector else "")
            is_csv = any(is_local_source(r["fonte"]) for _, r in members)
            if collector:
                stats["collezionistici"] += 1
                c_row = [members[0][0].external_id, release_id, media, len(members),
                         ", ".join(p.name for p, _ in members), members[0][1]["disco"] or "", collector[0],
                         "; ".join(collector[1]), suggested, collector[2], price, currency,
                         "CSV" if is_csv else "API"]
                if args.simula:
                    simulated_collectors.append(c_row)
                else:
                    state.execute("INSERT OR REPLACE INTO collezionistici VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", c_row)

            if is_csv:
                # Trovato in locale: una riga nel CSV con quantity = numero di foto.
                row_id = members[0][0].external_id
                quantity = len(members)
                if args.simula:
                    simulated_csv.append(csv_row(release_id, price, media, sleeve, quantity, row_id))
                else:
                    state.execute(
                        "INSERT INTO righe_csv VALUES (?,?,?,?,?,?,?,?)",
                        (row_id, parts.assign(quantity), release_id, price, media, sleeve, quantity,
                         ", ".join(p.name for p, _ in members)))
                    for p, _ in members:
                        state.execute("UPDATE foto SET riga_csv = ? WHERE external_id = ?", (row_id, p.external_id))
                state.commit()
                stats["righe_csv"] += 1
                stats["copie_csv"] += quantity
                print(f"{info} -> CSV")
                continue

            # Trovato solo via API: un annuncio per foto (l'API non ha un campo quantità).
            for p, _ in members:
                eid = p.external_id
                if args.simula:
                    simulated_listings.append([eid, release_id, f"{price:.2f}", GRADES[media], GRADES[sleeve]])
                    stats["api"] += 1
                    print(f"{info} -> annuncio API {eid} (simulato)")
                    continue
                state.execute(
                    "INSERT INTO annunci_api (external_id, release_id, price, media, sleeve, stato, inviato)"
                    " VALUES (?,?,?,?,?,'in_corso',?)", (eid, release_id, price, media, sleeve, now()))
                state.commit()  # segnato PRIMA di inviare: niente doppioni se si interrompe
                try:
                    resp = api.create_listing(release_id, GRADES[media], GRADES[sleeve], price, eid)
                except ApiUncertain as e:
                    print(f"{info}: esito della pubblicazione di {eid} incerto ({e}), verrà controllato al prossimo avvio")
                    continue
                except ApiError as e:
                    state.execute("UPDATE annunci_api SET stato = 'rifiutato', messaggio = ? WHERE external_id = ?",
                                  (str(e), eid))
                    state.commit()
                    stats["problemi"] += 1
                    print(f"{info}: annuncio {eid} rifiutato da Discogs ({e})")
                    continue
                state.execute("UPDATE annunci_api SET stato = 'pubblicato', listing_id = ? WHERE external_id = ?",
                              (resp.get("listing_id"), eid))
                state.commit()
                stats["api"] += 1
                print(f"{info} -> annuncio {eid} pubblicato via API (listing {resp.get('listing_id')})")
    except KeyboardInterrupt:
        print("\nInterrotto. Rilancia lo stesso comando per riprendere da qui.")
    finally:
        out_dir = Path(args.uscita).expanduser()
        to_check = write_outputs(state, out_dir, simulated_csv, simulated_listings, simulated_collectors)
        print()
        print("Riepilogo di questa esecuzione")
        print(f"  righe nel CSV di inventario: {stats['righe_csv']} ({stats['copie_csv']} copie)")
        print(f"  annunci via API{' (simulati)' if args.simula else ''}: {stats['api']}")
        print(f"  foto da controllare:         {stats['problemi']}")
        print(f"  foto già in vendita:         {stats['gia_fatte']}")
        print(f"  dischi collezionistici:      {stats['collezionistici']} (vedi collezionistici.csv)")
        print(f"  richieste API: {api.calls} (di cui prezzi e dati collezionistici: {price_calls})")
        if ai:
            print(f"  spesa AI: {money(ai.spent - ai_spent_before)} in questa esecuzione, {money(ai.spent)} in totale"
                  f" (tetto {money(args.ai_tetto)})")
        if budget_stop:
            print(f"\nTETTO DI SPESA AI RAGGIUNTO ({money(args.ai_tetto)}): lo script si è fermato qui.\n"
                  "Le foto già riconosciute sono state messe in vendita normalmente. Per continuare con le altre,\n"
                  "rilancia lo stesso comando con un tetto più alto, es. --ai-tetto 80.")
        print(f"Risultati in {out_dir}/  (righe in da_controllare.csv: {to_check})")
        if args.simula:
            print(f"Simulazione in {out_dir / 'simulazione'}/")
        state.close()
        con.close()


if __name__ == "__main__":
    main()
