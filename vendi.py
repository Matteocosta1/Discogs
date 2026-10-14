#!/usr/bin/env python3
"""
Mette in vendita su Discogs i dischi fotografati.

Struttura: Dischi/<grado>/<foto>, con i gradi M, NM, VG+, VG, G+, G (oppure
DISCO_COPERTINA, es. M_NM: disco M, copertina NM; il prezzo segue il grado del disco) e le foto
con i nomi originali dell'iPhone (JPG o HEIC). Ogni foto è una copia; il nome
del file senza estensione è l'external_id. Più foto dello stesso disco vanno in
una sottocartella del grado (Dischi/VG+/disco-001/{fronte,retro,etichetta}.jpg):
la sottocartella è UN disco (indizi di tutte le foto uniti, una sola chiamata AI),
external_id = <sottocartella>-<impronta breve>, un file vuoto "copie-N" = N copie.

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
     e. il disco si riconosce dalle scritte principali, mai dalle righe di una
        scaletta ("C2. Artista - Brano, From the album ..."); un riconoscimento
        senza codice (AI o artista e titolo) deve superare una verifica finale
        (artista tra le scritte principali, Various solo per una compilation,
        non una sola parola), altrimenti va in da_controllare.csv;
  2. raggruppa le foto della stessa release con lo stesso grado: sono copie
     dello stesso disco;
  3. controlla che la release si possa vendere (GET /releases/{id}, campo
     blocked_from_sale): se è bloccata dal marketplace va in non_vendibili.csv,
     senza prezzo né annuncio; se non si riesce a verificarlo, in da_controllare.csv;
     poi calcola il prezzo: base = prezzo più basso in vendita (statistiche del
     marketplace), mai sotto il prezzo suggerito per il grado; premio scarsità
     secondo le copie in vendita (0 -> suggerito +100%, 1-2 -> +50%, 3-5 -> +25%)
     e premio richiesta se want/have > 1 (+10%), sommati, tutto configurabile;
     ultimo passaggio: arrotondamento per eccesso alla griglia di 2,50 (minimo 2,50);
     valute nella valuta dell'account venditore; i dischi con punteggio
     collezionistico alto sono elencati anche in collezionistici.csv;
     un disco riconosciuto senza codice che è collezionistico o costa più di
     --soglia-controllo (default 100) va in da_controllare.csv, non in vendita;
  4. trovato in locale -> una riga nel CSV di caricamento inventario con
     quantity = numero di foto (max 1.000 dischi per file);
     trovato solo via API -> un annuncio via API per foto (l'API non ha un
     campo quantità), con external_id = nome della foto;
     con --bozza TUTTI gli annunci si creano via API in bozza (Draft), uno per
     foto: Discogs ignora DRAFT nei CSV e li metterebbe subito in vendita.
     Il CSV contiene sempre e solo righe FOR_SALE.

Tutto lo stato è salvato in data/vendita_stato.sqlite: se lo script si
interrompe, rilanciando lo stesso comando riparte da dove era, senza annunci doppi.
Con --rielabora --bozza le foto della cartella vengono rielaborate da capo
(le foto online su Discogs, o che lo sono state, sono saltate).

Esempi:
    python3 vendi.py ~/Pictures/Dischi --limite 20 --simula
    python3 vendi.py ~/Pictures/Dischi
"""

import argparse
import csv
import datetime as dt
import decimal
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
PROBLEMS = {"non_trovato", "multiplo", "senza_prezzo", "errore", "da_verificare", "non_verificato", "stesso_disco"}


def now():
    return dt.datetime.now().isoformat(timespec="seconds")


def natural_key(s):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", s)]


# --------------------------------------------------------------------------
# Foto e gradi
# --------------------------------------------------------------------------

def read_grades(folder_name):
    """(grado disco, grado copertina) dal nome della cartella, o None se non è un grado valido.

    'VG+' -> VG+ e VG+ (un grado solo vale per entrambi); 'M_NM' -> disco M, copertina NM
    (DISCO_COPERTINA). Maiuscole e minuscole indifferenti; ogni parte deve essere in GRADES.
    """
    parts = [p.strip().upper() for p in folder_name.strip().split("_")]
    if len(parts) == 1:
        parts = parts * 2
    if len(parts) != 2 or not all(p in GRADES for p in parts):
        return None
    return parts[0], parts[1]


GRADE_FORMATS = (f"un grado ({', '.join(GRADES)}), uguale per disco e copertina, oppure DISCO_COPERTINA "
                 "(es. M_NM, VG+_VG, NM_VG+)")


def grade_text(media, sleeve):
    """'VG+' se disco e copertina hanno lo stesso grado, altrimenti 'M_NM' (disco_copertina)."""
    return media if media == sleeve else f"{media}_{sleeve}"


@dataclass
class Photo:
    """Un disco da vendere: una foto sola nella cartella del grado, oppure una sottocartella con più
    foto dello stesso disco (fronte, retro, etichetta...)."""
    path: Path                # la foto, o la sottocartella del disco
    folder: str
    media: str                # grado del disco (chiave di GRADES)
    sleeve: str               # grado della copertina (chiave di GRADES)
    sha256: str = None        # impronta del contenuto (riempita da check_photo_identity)
    files: list = None        # disco in una sottocartella: le sue foto; None = una foto sola
    copies: int = 1           # copie dello stesso disco (file "copie-N" nella sottocartella)
    hashes: list = None       # impronte delle singole foto del disco in sottocartella

    @property
    def is_disc(self):
        return self.files is not None

    @property
    def images(self):
        return list(self.files) if self.is_disc else [self.path]

    @property
    def external_id(self):
        if self.is_disc:  # es. "disco-001-3f2a9c1e": nome della sottocartella + impronta breve delle foto
            return f"{self.path.name}-{self.sha256[:8]}"
        return self.path.stem  # es. "IMG_1234"

    @property
    def name(self):
        if self.is_disc:
            return f"{self.folder}/{self.path.name} ({len(self.files)} foto)"
        return f"{self.folder}/{self.path.name}"

    def fingerprint(self):
        if self.is_disc:
            stats = [f.stat() for f in self.files]
            return (f"{self.folder}|{self.path.name}/{len(stats)}|{sum(st.st_size for st in stats)}|"
                    f"{max(st.st_mtime_ns for st in stats)}")
        st = self.path.stat()
        return f"{self.folder}|{self.path.name}|{st.st_size}|{st.st_mtime_ns}"

    def content_hash(self):
        if self.is_disc:
            return disc_hash(self.hashes)
        return file_sha256(self.path)


def disc_hash(hashes):
    """Impronta di un disco in sottocartella: dalle impronte delle sue foto, in qualsiasi ordine."""
    import hashlib
    return hashlib.sha256("\n".join(sorted(hashes)).encode()).hexdigest()


def file_sha256(path):
    """Impronta SHA-256 dei byte del file: non cambia spostando o rinominando la foto."""
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def photo_taken_at(path):
    """Data e ora di scatto: SOLO il tag EXIF DateTimeOriginal (36867), o None se manca. Funziona anche
    con le HEIC dell'iPhone tramite pillow-heif. Mai altre date: il tag DateTime (306) è la data di
    modifica, che le app di messaggistica riscrivono uguale per tutte le foto ("scatti a 0 secondi"),
    e la data del file con AirDrop è uguale per tutte."""
    try:
        from PIL import Image
        try:
            import pillow_heif
            pillow_heif.register_heif_opener()
        except ImportError:
            pass
        with Image.open(path) as img:
            exif = img.getexif()
            value = exif.get_ifd(0x8769).get(36867)  # DateTimeOriginal
        return dt.datetime.strptime(str(value).strip()[:19], "%Y:%m:%d %H:%M:%S") if value else None
    except Exception:  # foto senza EXIF, formato non leggibile, Pillow non installato
        return None


def check_photo_identity(state, photos):
    """Prima di elaborare: calcola l'impronta del contenuto di ogni foto e la confronta con lo stato.

    - stesso nome, stesso contenuto (anche spostata di cartella) -> è la stessa foto: niente da rifare;
    - stesso nome, contenuto diverso -> conflitto: due foto diverse avrebbero lo stesso external_id;
    - stesso contenuto, nomi diversi -> conflitto: la stessa foto verrebbe messa in vendita due volte.
    Stato di una versione precedente senza impronta: la si calcola ora; se la dimensione del file
    coincide con quella salvata è la stessa foto (niente riconoscimento né AI da rifare).
    Restituisce l'elenco dei conflitti (vuoto se va tutto bene) e aggiorna lo stato."""
    rows = {r["external_id"]: r for r in state.execute("SELECT external_id, foto, impronta, hash, hash_foto, n_foto"
                                                       " FROM foto")}
    by_hash = {h: eid for eid, r in rows.items() for h in photo_hashes(r)}
    conflicts, seen = [], {}
    for p in photos:
        row = rows.get(p.external_id)
        fp = p.fingerprint()
        if row is not None and row["hash"] and row["impronta"] == fp:
            p.sha256 = row["hash"]  # file non toccato: inutile rileggerlo
        else:
            p.sha256 = p.content_hash()
        # Disco in sottocartella: ogni sua foto conta come una foto (stesse regole delle foto sciolte).
        parts = p.hashes if p.is_disc else [p.sha256]
        if len(set(parts)) < len(parts):
            conflicts.append(f"{p.name} contiene due volte la stessa foto: tienine una sola")
            continue
        twin = next((seen[h] for h in parts if h in seen), None)
        if twin is not None:
            if p.is_disc or twin.is_disc:
                conflicts.append(f"{p.name} e {twin.name} contengono la stessa foto (lo stesso disco verrebbe "
                                 "messo in vendita due volte): tienine una sola")
            else:
                conflicts.append(f"{p.name} e {twin.name} sono la stessa foto con due nomi diversi "
                                 "(verrebbe messa in vendita due volte): tienine una sola")
            continue
        for h in parts:
            seen[h] = p
        other = next((by_hash[h] for h in parts if by_hash.get(h) not in (None, p.external_id)), None)
        if other:
            where = display_name(rows[other])
            if p.is_disc:
                conflicts.append(f"{p.name} contiene una foto già elaborata come {other} ({where}): tienine una "
                                 "sola (se hai aggiunto o tolto foto a un disco già elaborato, rimettilo com'era)")
            else:
                conflicts.append(f"{p.name} è la stessa foto già elaborata come {other} ({where}): tienine una sola")
            continue
        if row is None:
            continue
        if row["hash"]:
            same = row["hash"] == p.sha256
        else:  # versione precedente: impronta = cartella|nome|dimensione|data
            parts = (row["impronta"] or "").split("|")
            same = len(parts) == 4 and parts[2] == str(p.path.stat().st_size)
        if not same:
            conflicts.append(f"{p.name}: nello stato c'è già una foto DIVERSA con lo stesso nome {p.external_id} "
                             f"({display_name(row)}): rinomina la nuova (es. con rinomina_foto.py)")
            continue
        if row["hash"] != p.sha256 or row["impronta"] != fp:
            # stessa foto (forse spostata): aggiorna impronta e cartella, il riconoscimento resta valido
            state.execute("UPDATE foto SET hash = ?, impronta = ?, cartella = ?, foto = ?, media = ?, sleeve = ?,"
                          " n_foto = ?, hash_foto = ? WHERE external_id = ?",
                          (p.sha256, fp, p.folder, str(p.path), p.media, p.sleeve, *disc_columns(p), p.external_id))
    state.commit()
    return conflicts


def photo_hashes(row):
    """Impronte delle singole foto di una riga della tabella foto (più di una per un disco in sottocartella)."""
    if row["hash_foto"]:
        return json.loads(row["hash_foto"])
    return [row["hash"]] if row["hash"] else []


def disc_columns(p):
    """(n_foto, hash_foto) da salvare nello stato: vuoti per una foto sola."""
    return (len(p.files), json.dumps(p.hashes)) if p.is_disc else (None, None)


COPIES_RE = re.compile(r"^copie-(\d+)(\.txt)?$", re.IGNORECASE)


def scan_disc(folder, grade_folder, grades, errors, warnings):
    """Sottocartella di un grado = UN disco: tutte le sue foto sono lo stesso disco. Un file vuoto
    "copie-N" dice che ci sono N copie identiche. None se la sottocartella non ha foto."""
    files, copies = [], []
    for f in sorted(folder.iterdir(), key=lambda f: natural_key(f.name)):
        if f.name.startswith("."):
            continue
        if f.is_file() and f.suffix.lower() in IMAGE_EXTS:
            files.append(f)
        elif f.is_file() and COPIES_RE.match(f.name):
            copies.append(int(COPIES_RE.match(f.name).group(1)))
        elif f.is_dir():
            warnings.append(f"cartella dentro un disco, ignorata: {grade_folder}/{folder.name}/{f.name}")
    where = f"{grade_folder}/{folder.name}"
    if not files:
        warnings.append(f"sottocartella senza foto, ignorata: {where}")
        return None
    if len(copies) > 1:
        errors.append(f"{where}: più di un file copie-N, lasciane uno solo")
        return None
    if copies and copies[0] < 1:
        errors.append(f"{where}: copie-{copies[0]} non valido (almeno copie-1)")
        return None
    hashes = [file_sha256(f) for f in files]
    return Photo(folder, grade_folder, grades[0], grades[1], sha256=disc_hash(hashes), files=files,
                 copies=copies[0] if copies else 1, hashes=hashes)


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
            errors.append(f"la cartella '{sub.name}' non è un grado valido: usa {GRADE_FORMATS}")
            continue
        for f in sorted(sub.iterdir()):
            if f.name.startswith("."):
                continue
            if f.is_dir():  # sottocartella = un disco con più foto
                disc = scan_disc(f, sub.name, grades, errors, warnings)
                if disc is not None:
                    photos.append(disc)
            elif f.is_file() and f.suffix.lower() in IMAGE_EXTS:
                photos.append(Photo(f, sub.name, grades[0], grades[1]))
    # Il nome della foto (o della sottocartella + impronta) è l'external_id: deve essere unico.
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


# Righe di una scaletta (tracklist): "A1 ...", "C2. ...", "B3) ...", "1. ...", "12 - ...",
# e i riferimenti come "From the album 'Mirage' BJQD/15 [1973]". Non sono il disco.
TRACK_LINE_RE = re.compile(r"^\s*(?:[A-Ha-h]\s?\d{1,2}|\d{1,2})\s*[.):\-–]?\s+(?!rpm\b|giri\b)\S", re.I)
FROM_ALBUM_RE = re.compile(r"\bfrom (?:the )?(?:album|lp|ep|12\"?)\b[\s:,]*[\"'“‘«]?([^\"'”’»\[\(]+)", re.I)


def is_track_line(text):
    return bool(TRACK_LINE_RE.match(text or "") or FROM_ALBUM_RE.search(text or ""))


MAIN_MIN_HEIGHT = 0.5   # scritte principali: alte almeno metà della scritta più grande...
MAIN_TOP_LINES = 8      # ...oppure tra le 8 più grandi


def big_lines(lines):
    """Le scritte più grandi lette dall'OCR (di solito artista e titolo), senza le righe della scaletta."""
    lines = [(t, h) for t, h in lines if t.strip() and not is_track_line(t)]
    if not lines:
        return []
    tallest = max(h for _t, h in lines)
    top = sorted(lines, key=lambda x: -x[1])[:MAIN_TOP_LINES]
    return [t for t, h in lines if (tallest and h >= tallest * MAIN_MIN_HEIGHT) or (t, h) in top]


def from_album_titles(text):
    """Titoli citati come "From the album '...'" (album da cui viene un brano, non il disco)."""
    return [m.group(1).strip(" .,-") for m in FROM_ALBUM_RE.finditer(text or "") if m.group(1).strip(" .,-")]


@dataclass
class Evidence:
    barcodes: list = field(default_factory=list)
    catnos: dict = field(default_factory=dict)   # normalizzato -> originale
    lines: list = field(default_factory=list)    # (testo, altezza) letti dall'OCR (o dall'AI)
    ocr_done: bool = False
    ai_note: str = ""
    main: list = field(default_factory=list)     # scritte principali: artista e titolo in grande
    per_photo: list = field(default_factory=list)  # disco con più foto: [(nome foto, Evidence della sola foto)]

    @property
    def text(self):
        return "\n".join(t for t, _h in self.lines)

    def add_lines(self, lines, main=None):
        """Aggiunge righe lette nella foto. main: le scritte principali tra queste
        (se None, le righe più grandi, senza quelle della scaletta)."""
        self.lines.extend(lines)
        self.main.extend(big_lines(lines) if main is None else main)
        # I numeri di catalogo di una scaletta ("From the album 'Mirage' BJQD/15")
        # sono di altri dischi: non valgono mai come catno di questo.
        texts = [t for t, _h in self.lines]
        in_tracks = catno_candidates([t for t in texts if is_track_line(t)])
        strong = [t for t in in_tracks if is_strong_catno(t)]

        def from_tracks(norm):
            return norm in in_tracks or any(t in norm for t in strong)

        for norm, raw in catno_candidates([t for t in texts if not is_track_line(t)]).items():
            if not from_tracks(norm):
                self.catnos.setdefault(norm, raw)
        for norm in [n for n in self.catnos if from_tracks(n)]:
            del self.catnos[norm]
        self.ocr_done = True

    def tracks(self):
        return [t for t, _h in self.lines if is_track_line(t)]

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


# Formati ammessi (--formati-ammessi): il disco fotografato è sempre un vinile. Una release va bene
# solo se tra i suoi formati c'è uno di questi (Vinyl + CD sì, solo CD / Cassette / File / DVD no).
ALLOWED_FORMATS = ["Vinyl"]


def format_allowed(release, allowed=None):
    """True se tra i formati della release (dump locale: "Vinyl, LP, Album; CD"; API: ["Vinyl", "LP"])
    c'è uno dei formati ammessi. Formati sconosciuti: no."""
    allowed = {a.strip().lower() for a in (allowed or ALLOWED_FORMATS)}
    formats = release.get("formats") or ""
    if isinstance(formats, (list, tuple)):
        formats = ", ".join(formats)
    return any(part.strip().lower() in allowed for part in re.split(r"[,;]", formats))


def keep_allowed(releases):
    """Solo le release nei formati ammessi: le altre vengono scartate prima di qualsiasi scelta."""
    return [r for r in releases if format_allowed(r)]


def search_barcode_local(con, ev):
    ids = []
    for b in ev.barcodes:
        ids += [r["id"] for r in dd.search_by_barcode(con, b)]
    return keep_allowed([{**r, "_code": "barcode"} for r in dd.get_releases(con, ids)])


def search_catno_local(con, ev):
    confirmed, _ = local_catno_matches(con, ev)
    return keep_allowed([{**r, "_code": "catno"} for r in dd.get_releases(con, list(confirmed))])


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
    return keep_allowed(dd.get_releases(con, ids[:3000]))


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

    def download(self, url):
        """Scarica un file (es. un'immagine di Discogs) con le stesse credenziali e lo stesso ritmo."""
        headers = {"User-Agent": USER_AGENT, "Authorization": f"Discogs token={self._token}"}
        for attempt in range(3):
            self._wait_turn()
            req = urllib.request.Request(url, headers=headers)
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    self.calls += 1
                    self._respect_remaining(resp.headers)
                    return resp.read()
            except urllib.error.HTTPError as e:
                self.calls += 1
                if e.code == 429:
                    time.sleep(60)
                    continue
                return b""
            except (urllib.error.URLError, TimeoutError, OSError):
                time.sleep(3 * (attempt + 1))
        return b""

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

    def create_listing(self, release_id, condition, sleeve_condition, price, external_id, status="For Sale"):
        return self.request("POST", "/marketplace/listings", body={
            "release_id": release_id,
            "condition": condition,
            "sleeve_condition": sleeve_condition,
            "price": price,
            "status": status,
            "external_id": external_id,
        })

    def user(self, username):
        return self.request("GET", f"/users/{urllib.parse.quote(username)}")

    def release(self, release_id):
        return self.request("GET", f"/releases/{release_id}")

    def marketplace_stats(self, release_id, currency):
        params = {"curr_abbr": currency} if currency else None
        return self.request("GET", f"/marketplace/stats/{release_id}", params)

    def inventory_page(self, username, page, status=None):
        params = {"sort": "listed", "sort_order": "desc", "per_page": 100, "page": page}
        if status:
            params["status"] = status
        return self.request("GET", f"/users/{urllib.parse.quote(username)}/inventory", params)

    def edit_listing(self, listing_id, release_id, condition, sleeve_condition, price, status):
        """Modifica "minima": solo i campi obbligatori (usata da verifica_modifica_annuncio.py per il test)."""
        body = {"release_id": release_id, "condition": condition, "price": price, "status": status}
        if sleeve_condition:
            body["sleeve_condition"] = sleeve_condition
        return self.request("POST", f"/marketplace/listings/{listing_id}", body=body)

    def orders_page(self, page):
        """Una pagina dei miei ordini (tutti gli stati, anche annullati)."""
        return self.request("GET", "/marketplace/orders",
                            {"page": page, "per_page": 100, "sort": "id", "sort_order": "desc"})

    def get_listing(self, listing_id):
        return self.request("GET", f"/marketplace/listings/{listing_id}")

    def edit_listing_fields(self, listing_id, body):
        """Modifica di un annuncio inviando tutti i campi in body (vedi listing_edit_body)."""
        return self.request("POST", f"/marketplace/listings/{listing_id}", body=body)


# Campi modificabili di un annuncio (POST /marketplace/listings/{id}). Per non azzerarne nessuno,
# una modifica li reinvia tutti con il loro valore attuale, cambiando solo quelli voluti.
LISTING_FIELDS = ["release_id", "condition", "sleeve_condition", "price", "comments", "allow_offers", "status",
                  "external_id", "location", "weight", "format_quantity"]


def listing_fields(listing):
    """I campi modificabili di un annuncio letto da Discogs (GET dell'annuncio o riga dell'inventario)."""
    out = {}
    for key in LISTING_FIELDS:
        if key == "release_id":
            value = (listing.get("release") or {}).get("id", listing.get("release_id"))
        elif key == "price":
            value = listing.get("price")
            value = value.get("value") if isinstance(value, dict) else value
        else:
            value = listing.get(key)
        if value is not None:
            out[key] = value
    return out


def listing_edit_body(listing, **changes):
    """Corpo per modificare un annuncio: tutti i campi attuali, più le modifiche (es. price=12.5)."""
    return {**listing_fields(listing), **changes}


def changed_fields(before, after, ignore=()):
    """Campi modificabili diversi tra due letture dello stesso annuncio: {campo: (prima, dopo)}."""
    a, b = listing_fields(before), listing_fields(after)
    return {k: (a.get(k), b.get(k)) for k in LISTING_FIELDS
            if k not in ignore and a.get(k) != b.get(k)}


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
    """(fonte, candidati) cercando su Discogs per barcode, poi per catno, poi per artista e titolo.
    Solo release nei formati ammessi (con un solo formato ammesso lo si chiede già a Discogs)."""
    fmt_param = {"format": ALLOWED_FORMATS[0]} if len(ALLOWED_FORMATS) == 1 else {}

    def allowed(res):
        return [r for r in res.get("results", []) if format_allowed({"formats": r.get("format", [])})]

    for b in ev.barcodes:
        res = api.search(barcode=b, **fmt_param)
        results = {r["id"]: {**api_result_as_release(r), "_code": "barcode"} for r in allowed(res)}
        if results:
            return "api-barcode", list(results.values())
    strong = [(norm, raw) for norm, raw in ev.catnos.items() if is_strong_catno(norm)]
    strong.sort(key=lambda x: -len(x[0]))
    for _norm, raw in strong[:3]:  # al massimo 3 tentativi per non sprecare richieste
        res = api.search(catno=raw, **fmt_param)
        confirmed = {
            r["id"]: {**api_result_as_release(r), "_code": "catno"}
            for r in allowed(res)
            if any(label_in_text(l, ev.text) for l in r.get("label", []))
        }
        if confirmed:
            return "api-catno", list(confirmed.values())
    for artist, title in artist_titles:
        params = {"release_title": title}
        if artist:
            params["artist"] = artist
        res = api.search(**params, **fmt_param)
        results = {r["id"]: api_result_as_release(r) for r in allowed(res)}
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
    "claude-sonnet-5-5": (2.00, 10.00),
    "claude-opus-5": (5.00, 25.00),
    "claude-opus-5-5": (4.00, 20.00),
}
AI_SECOND_MODEL = "claude-opus-5-5"   # secondo tentativo sulle foto non riconosciute dal primo modello (lotto-07: recupera dove Sonnet si arrende)
# Questi modelli ragionano prima di rispondere (non si può spegnere su tutti): il ragionamento usa
# token di risposta, quindi servono più token e uno sforzo dichiarato. Haiku 4.5 non ragiona.
AI_NO_THINKING = {"claude-haiku-4-5"}
AI_THINKING_EXTRA_TOKENS = 6000
AI_THINKING_EFFORT = "medium"
AI_MAX_EDGE = 1568          # lato lungo massimo della foto inviata (pixel)
AI_MAX_CANDIDATES = 40      # candidati mostrati all'AI per la scelta finale
AI_MAX_PHOTOS = 4           # foto di un disco in sottocartella inviate all'AI in una sola chiamata

# Disco con più foto: una sola chiamata con tutte le immagini, e il modello deve sapere che sono
# lati diversi dello stesso disco (non dischi diversi).
AI_MULTI_PHOTO_NOTE = """These {n} photos all show the SAME single vinyl record from different sides (for example front cover, back cover, centre label, details): they are ONE record, not {n} records.
Combine the clues from all the photos (e.g. artist and title from the front, barcode and catalogue number from the back or the label) and answer about this one record.
"""

AI_READ_PROMPT = """This photo shows ONE vinyl record: its front cover, back cover or centre label.
The record is ALWAYS a vinyl record (LP, 12", 10" or 7"), never a CD, cassette or digital release.
Report what you can see. Transcribe printed details exactly; use an empty string when something is not clearly readable. Never guess printed details.
Identify THIS record only from its MAIN printed details: the artist and title printed large on the cover or label (the header), the record's own catalogue number and its barcode.
A tracklist is NOT the record: never take artist, title or catalogue number from tracklist lines (e.g. "A1 ...", "C2. Artist - Track") or from references such as "From the album 'X' ABC/12 [1973]", which name OTHER records the tracks come from.
If the tracklist shows several different artists, this record is probably a compilation: report the artist/title of the header (e.g. the compiler's name and the compilation title, or "Various") and set compilation to true.
- photo_type: front, back, label or other.
- artist, title, label, catno (the catalogue number of THIS record, e.g. "SHVL 804"), year (e.g. after ℗ or ©), country (where made/printed), barcode (digits).
- compilation: true if this record collects tracks by different artists.
- readable_text: the most useful readable text, one item per line (titles, credits, codes, label, company names), at most 40 lines; copy tracklist lines as they are printed, including their position (A1, B2...).
- recognized_artist / recognized_title: if you recognise the record from its artwork or overall look, the artist and album you believe it is, even if not printed; otherwise empty."""

AI_READ_SCHEMA = {
    "type": "object",
    "properties": {
        "photo_type": {"type": "string", "enum": ["front", "back", "label", "other"]},
        "compilation": {"type": "boolean"},
        **{k: {"type": "string"} for k in ("artist", "title", "label", "catno", "year", "country", "barcode",
                                          "readable_text", "recognized_artist", "recognized_title")},
    },
    "required": ["photo_type", "compilation", "artist", "title", "label", "catno", "year", "country", "barcode",
                 "readable_text", "recognized_artist", "recognized_title"],
    "additionalProperties": False,
}

AI_CHOOSE_PROMPT = """This photo shows ONE vinyl record (front cover, back cover or centre label).
The record is ALWAYS a vinyl record: never choose a CD, cassette or file release (check the format column).
Below is a list of candidate Discogs releases. Choose the one this record is.
Compare every visible clue: artist, title, label, catalogue number, barcode, country, year, format, artwork.
Identify the record from its MAIN printed details (artist and title printed large on the cover or label, its own catalogue number, its barcode).
Tracklist lines and references such as "From the album 'X' ABC/12 [1973]" name OTHER records the tracks come from: a candidate that matches only a tracklist line is NOT this record.
If the tracklist shows several different artists, the record is probably a compilation: choose the candidate matching the header (compiler/title or "Various").
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


# --------------------------------------------------------------------------
# Secondo servizio di riconoscimento: Google Cloud Vision (ricerca web dell'immagine), facoltativo
# --------------------------------------------------------------------------

GOOGLE_VISION_URL = "https://vision.googleapis.com/v1/images:annotate"
GOOGLE_VISION_COST = 0.0035   # € per immagine (3,50 $ ogni 1000, oltre le 1000 gratuite al mese)


class GoogleVision:
    """Riconoscimento della copertina con la ricerca web di Google (WEB_DETECTION): restituisce le
    "migliori ipotesi" di cosa mostra la foto (es. "theo parrish dance of the medusa"). Entra solo
    quando né la parte locale né l'AI hanno trovato candidati; quello che propone viene poi
    verificato come sempre (coerenza con la foto, copertina, scelta dell'AI). Chiave in .env:
    GOOGLE_VISION_KEY (console.cloud.google.com, API Cloud Vision)."""

    def __init__(self, key, wallet=None):
        self.key = key
        self.wallet = wallet
        self.calls = 0

    def guesses(self, image_b64):
        """Ipotesi di Google, dalla più probabile: etichette "best guess", entità web, titoli delle
        pagine con la stessa immagine. Lista di stringhe (vuota se niente)."""
        body = {"requests": [{"image": {"content": image_b64},
                              "features": [{"type": "WEB_DETECTION", "maxResults": 10}]}]}
        req = urllib.request.Request(f"{GOOGLE_VISION_URL}?key={urllib.parse.quote(self.key)}",
                                     data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json", "User-Agent": USER_AGENT})
        if self.wallet is not None:
            if self.wallet.spent + GOOGLE_VISION_COST > self.wallet.budget + 1e-9:
                raise BudgetReached()
            self.wallet.spent += GOOGLE_VISION_COST
        self.calls += 1
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read() or b"{}")
        web = (data.get("responses") or [{}])[0].get("webDetection") or {}
        out = []
        for g in web.get("bestGuessLabels") or []:
            if g.get("label"):
                out.append(g["label"])
        for e in web.get("webEntities") or []:
            if e.get("description") and (e.get("score") or 0) >= 0.5:
                out.append(e["description"])
        for pg in (web.get("pagesWithMatchingImages") or [])[:5]:
            title = (pg.get("pageTitle") or "")
            title = re.sub(r"<[^>]+>", "", title)
            if title:
                out.append(title)
        seen, uniq = set(), []
        for g in out:
            k = dd.normalize_text(g)
            if k and k not in seen:
                seen.add(k)
                uniq.append(g.strip())
        return uniq[:8]


def google_candidates(api, google, image_b64, ev):
    """Candidati Discogs dalle ipotesi di Google: ricerca libera su Discogs per ogni ipotesi; le
    ipotesi entrano tra le scritte principali della foto (così i controlli di coerenza possono
    passare). (candidati, testo delle ipotesi)."""
    guesses = google.guesses(image_b64)
    if not guesses:
        return [], ""
    fmt_param = {"format": ALLOWED_FORMATS[0]} if len(ALLOWED_FORMATS) == 1 else {}
    found = {}
    for g in guesses[:4]:
        res = api.search(q=g, type="release", **fmt_param)
        for r in res.get("results", [])[:10]:
            if format_allowed({"formats": r.get("format", [])}) and r["id"] not in found:
                found[r["id"]] = api_result_as_release(r)
    ev.add_lines([(g, 1.0) for g in guesses], main=guesses[:3])
    return list(found.values()), "ipotesi di Google: " + "; ".join(guesses[:4])


# --------------------------------------------------------------------------
# Seconda opinione indipendente: Google Gemini (facoltativa, con GEMINI_API_KEY in .env)
# --------------------------------------------------------------------------

GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
# Prezzi in dollari per milione di token (input, output), verificati a ottobre 2026; il tetto conta 1 $ = 1 €
GEMINI_MODELS = {
    "gemini-3-flash": (0.50, 3.00),
    "gemini-3.1-flash-lite": (0.25, 1.50),
    "gemini-2.5-flash": (0.30, 2.50),
    "gemini-3.1-pro": (2.00, 12.00),
}
GEMINI_DEFAULT = "gemini-3-flash"


def gemini_schema(schema):
    """Lo schema JSON di Claude nel formato di Gemini (tipi in maiuscolo, niente additionalProperties)."""
    out = {"type": schema["type"].upper()}
    if "properties" in schema:
        out["properties"] = {k: gemini_schema(v) for k, v in schema["properties"].items()}
        out["required"] = list(schema.get("required", []))
    if "enum" in schema:
        out["enum"] = list(schema["enum"])
    return out


class GeminiVision:
    """Gemini sceglie, da solo e senza sapere cosa ha scelto Claude, tra gli stessi candidati reali.
    Stessa foto, stesso elenco: se i due concordano il riconoscimento è più affidabile, se discordano
    il disco va controllato a mano. Spesa nello stesso tetto dell'AI."""

    def __init__(self, key, model=GEMINI_DEFAULT, wallet=None):
        self.key, self.model, self.wallet = key, model, wallet
        self.price_in, self.price_out = GEMINI_MODELS[model]
        self.calls = 0
        self.cost = 0.0

    def choose(self, image, candidates):
        images = image if isinstance(image, list) else [image]
        text = "\n".join(" | ".join(str(x) for x in (
            r["id"], clean_artist(r.get("artists")), r.get("title"),
            r.get("labels") or ", ".join(r.get("label_names", [])), r.get("country") or "", r.get("year") or "",
            r.get("formats") or "", ", ".join(r.get("barcodes", [])[:3]))) for r in candidates)
        prompt = AI_CHOOSE_PROMPT.format(candidates=text)
        if len(images) > 1:
            prompt = multi_photo_prompt(prompt, len(images))
        tokens = sum(t for _d, t in images) + len(text) // 3 + 600
        max_cost = (tokens * self.price_in + 1500 * self.price_out) / 1e6
        if self.wallet is not None and self.wallet.spent + max_cost > self.wallet.budget:
            raise BudgetReached()
        body = {
            "contents": [{"role": "user", "parts": [
                *({"inline_data": {"mime_type": "image/jpeg", "data": data}} for data, _t in images),
                {"text": prompt}]}],
            "generationConfig": {"responseMimeType": "application/json",
                                 "responseSchema": gemini_schema(AI_CHOOSE_SCHEMA), "temperature": 0},
        }
        req = urllib.request.Request(GEMINI_URL.format(model=self.model), data=json.dumps(body).encode(),
                                     method="POST", headers={"Content-Type": "application/json",
                                                             "x-goog-api-key": self.key, "User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = json.loads(resp.read() or b"{}")
        usage = data.get("usageMetadata") or {}
        cost = ((usage.get("promptTokenCount") or tokens) * self.price_in
                + ((usage.get("candidatesTokenCount") or 0) + (usage.get("thoughtsTokenCount") or 0)) * self.price_out) / 1e6
        self.calls += 1
        self.cost += cost
        if self.wallet is not None:
            self.wallet.spent += cost
        try:
            parts = data["candidates"][0]["content"]["parts"]
            return json.loads("".join(p.get("text", "") for p in parts)), cost
        except (KeyError, IndexError, ValueError):
            return {}, cost


def env_value_or_none(key):
    try:
        return load_env_value(key, key, "")
    except SystemExit:
        return None


def gemini_agrees(row):
    """True se la seconda opinione salvata di Gemini è la stessa release della foto."""
    try:
        g = json.loads(row["gemini_scelta"]) if row["gemini_scelta"] else None
    except (IndexError, KeyError, ValueError):
        return False
    return bool(g) and g.get("release_id") == row["release_id"]


def second_opinion(rec, path, gemini, cache):
    """Gemini sceglie tra i candidati dello stesso riconoscimento (solo se senza codice). Concorda: il
    dubbio sul testo cade. Discorda: il disco va controllato a mano, con le due proposte."""
    if gemini is None or rec.release is None or rec.metodo not in UNVERIFIED_METHODS:
        return
    if rec.esito not in ("trovato", "da_verificare") or (rec.motivo or "").startswith(CONTRAST_REASON):
        return
    shortlist = [r for _s, r, _w in rec.candidates[:AI_MAX_CANDIDATES]]
    if rec.release["id"] not in [r["id"] for r in shortlist]:
        shortlist = [rec.release] + shortlist[:AI_MAX_CANDIDATES - 1]
    ids = sorted(r["id"] for r in shortlist)
    choice = (cache or {}).get("gemini")
    if not choice or choice.get("_ids") != ids:
        paths = list(path) if isinstance(path, (list, tuple)) else [path]
        images = [AIVision.prepare(load_image(p)) for p in paths[:AI_MAX_PHOTOS]]
        try:
            choice, cost = gemini.choose(images if len(images) > 1 else images[0], shortlist)
        except (urllib.error.URLError, OSError, ValueError) as e:   # Gemini giù: resta il riconoscimento di Claude
            rec.details += f"; Gemini non ha risposto ({e})"
            return
        rec.ai_cost += cost
        choice = {**choice, "_ids": ids, "_modello": gemini.model}
    rec.gemini = choice
    gid = choice.get("release_id")
    conf = CONFIDENCE_IT.get(choice.get("confidence"), "?")
    if gid == rec.release["id"]:
        rec.details += f"; Gemini concorda (sicurezza {conf})"
        # Due modelli d'accordo con sicurezza alta superano solo i dubbi "di lettura" (artista non tra le
        # scritte principali, una sola parola). Mai le trappole note: scaletta, "From the album",
        # compilation, alfabeti diversi (white label): lì due modelli possono sbagliare allo stesso modo.
        if (rec.esito == "da_verificare" and choice.get("confidence") == "high"
                and not is_trap(rec.motivo) and COVER_REASON not in (rec.motivo or "")):
            rec.details += f" (supera il dubbio: {rec.motivo})"
            rec.esito, rec.motivo = "trovato", ""
    elif gid:
        other = next((r for r in shortlist if r["id"] == gid), None)
        rec.motivo = (f"Claude e Gemini scelgono release diverse: {rec.release['id']} "
                      f"({describe_release(rec.release)}) e {gid} ({describe_release(other) if other else '?'})")
        rec.esito = "da_verificare"
        rec.details += f"; DA VERIFICARE: {rec.motivo}"
    else:
        rec.details += "; Gemini: nessuno dei candidati gli sembra il disco"


class BudgetReached(Exception):
    """Il tetto di spesa AI non permette un'altra chiamata."""


class Wallet:
    """Spesa AI comune a tutti i modelli usati: un solo tetto per primo e secondo tentativo."""

    def __init__(self, budget_eur, spent_eur):
        self.budget = budget_eur
        self.spent = spent_eur


class AIVision:
    """Chiamate al modello con visione, con tetto di spesa totale (in euro, 1 $ = 1 €)."""

    def __init__(self, model, budget_eur, spent_eur, wallet=None):
        import anthropic  # libreria ufficiale di Anthropic
        self.client = anthropic.Anthropic(api_key=load_env_value(
            "ANTHROPIC_API_KEY", "la chiave API di Anthropic (serve per l'AI; per farne a meno usa --senza-ai)",
            "https://console.anthropic.com/settings/keys"))
        self.model = model
        self.price_in, self.price_out = AI_MODELS[model]
        self.wallet = wallet or Wallet(budget_eur, spent_eur)

    @property
    def spent(self):
        return self.wallet.spent

    @spent.setter
    def spent(self, value):
        self.wallet.spent = value

    @property
    def budget(self):
        return self.wallet.budget

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
        """image: una foto preparata (base64, token stimati) o, per un disco con più foto, una lista:
        una sola chiamata con tutte le immagini; il costo stimato le somma tutte."""
        images = image if isinstance(image, list) else [image]
        if len(images) > 1:
            prompt = multi_photo_prompt(prompt, len(images))
        image_tokens = sum(tokens for _data, tokens in images)
        output_config = {"format": {"type": "json_schema", "schema": schema}}
        if self.model not in AI_NO_THINKING:
            max_tokens += AI_THINKING_EXTRA_TOKENS
            output_config["effort"] = AI_THINKING_EFFORT
        max_cost = ((image_tokens + extra_input_tokens + 600) * self.price_in + max_tokens * self.price_out) / 1e6
        if self.spent + max_cost > self.budget:
            raise BudgetReached()
        response = self.client.messages.create(
            model=self.model,
            max_tokens=max_tokens,
            messages=[{"role": "user", "content": [
                *({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": data}}
                  for data, _tokens in images),
                {"type": "text", "text": prompt},
            ]}],
            output_config=output_config,
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
        with_cover = any("_cover" in r for r in candidates)
        for r in candidates:
            label = f"{r.get('labels') or ', '.join(r.get('label_names', []))}"
            cols = [r["id"], clean_artist(r.get("artists")), r.get("title"), label, r.get("country") or "",
                    r.get("year") or "", r.get("formats") or "", ", ".join(r.get("barcodes", [])[:3])]
            if with_cover:
                cols.append(f"cover distance {r['_cover']:.2f}" if "_cover" in r else "cover not compared")
            lines.append(" | ".join(str(x) for x in cols))
        text = "\n".join(lines)
        prompt = AI_CHOOSE_PROMPT.format(candidates=text)
        if with_cover:
            prompt += ("\n\nThe last column is the visual distance between the photo and that release's Discogs "
                       "cover images (0 = identical; lower is more similar). Use it as one clue among the others.")
        return self._call(image, prompt, AI_CHOOSE_SCHEMA, 400,
                          extra_input_tokens=len(text) // 3)


def multi_photo_prompt(prompt, n):
    """Il prompt per una foto, adattato a n foto dello stesso disco."""
    prompt = prompt.replace("This photo shows ONE vinyl record", "Together, these photos show ONE vinyl record")
    return AI_MULTI_PHOTO_NOTE.format(n=n) + prompt


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
    ev.add_lines(lines, main=[data[k] for k in ("artist", "title", "recognized_artist", "recognized_title")
                              if data.get(k) and not is_track_line(data[k])])
    shown = {k: v for k, v in data.items() if v and k != "readable_text"}
    note = "letto dall'AI: " + ", ".join(f"{k}={v}" for k, v in shown.items())
    ev.ai_note = f"{note}{ev.ai_note}" if (ev.ai_note or "").startswith("; prima delle AI") else note


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
# Verifica finale dei riconoscimenti senza codice (AI o artista e titolo)
# --------------------------------------------------------------------------

# Metodi di riconoscimento: con barcode o catno esatti la release è certa; con
# l'AI o con artista e titolo (locale-testo) va verificata.
UNVERIFIED_METHODS = ("ai", "locale-testo", "copertina")
COVER_DIR = dd.DATA_DIR / "copertine"
COMPILATION_WORDS_RE = re.compile(r"\b(various artists|compilation|compiled by|v\s*/\s*a)\b", re.I)
TRACK_ARTIST_RE = re.compile(r"^\s*(?:[A-Ha-h]\s?\d{1,2}|\d{1,2})\s*[.):\-–]?\s+(.+?)\s+[-–—]\s+\S")


def method_of(fonte, release):
    """barcode / catno se la release viene da un codice letto nella foto, altrimenti ai / locale-testo."""
    code = (release or {}).get("_code")
    if code in ("barcode", "catno"):
        return code
    last = (fonte or "").split("+")[-1]
    for code in ("barcode", "catno"):
        if last.endswith(code):
            return code
    if not fonte:
        return ""
    if fonte.startswith("copertina"):
        return "copertina"
    return "ai" if fonte.startswith("ai") else "locale-testo"


def is_compilation(ev, ai_data=None):
    """True se la foto mostra una compilation: lo dice l'AI, c'è scritto, o la scaletta
    ha almeno 3 artisti diversi ("A1 Artista - Brano")."""
    if (ai_data or {}).get("compilation") is True:
        return True
    if COMPILATION_WORDS_RE.search(ev.text):
        return True
    artists = set()
    for line in ev.tracks():
        m = TRACK_ARTIST_RE.match(line)
        if m and dd.normalize_text(m.group(1)):
            artists.add(dd.normalize_text(m.group(1)))
    return len(artists) >= 3


def significant_words(value):
    return [w for w in dd.normalize_text(value).split() if w not in STOPWORDS]


def check_match(release, ev, ai_data=None):
    """Motivo per cui un riconoscimento senza codice (AI o artista e titolo) NON è affidabile,
    o "" se supera i controlli:
    - artista e titolo della release non devono essere una riga della scaletta, né il titolo
      un "From the album ..." citato nella foto;
    - l'artista deve comparire tra le scritte principali (tollerante a maiuscole, accenti e
      trattini); "Various" solo se la foto mostra una compilation;
    - il riconoscimento non può basarsi su una sola parola."""
    artist = clean_artist(release.get("artists"))
    title = release.get("title") or ""
    norm_artist = dd.normalize_text(artist)
    various = norm_artist in ("various", "various artists")
    who = f"{artist or '?'} - {title}"

    # 1. La release è un brano della scaletta, o l'album da cui viene un brano
    for line in ev.tracks():
        tm = TextMatcher(line)
        if (norm_artist and not various and tm.coverage(artist) >= TEXT_MIN_COVERAGE
                and tm.coverage(title) >= TEXT_MIN_COVERAGE):
            return f"'{who}' è una riga della scaletta, non il disco (riga: \"{line.strip()[:80]}\"): forse una compilation"
    for album in from_album_titles(ev.text):
        if dd.normalize_text(album) == dd.normalize_text(title):
            return f"'{title}' è citato come \"From the album\" nella scaletta: è l'album di un brano, non il disco"

    # 2. L'artista deve comparire tra le scritte principali
    main = TextMatcher("\n".join(ev.main))
    if various or not artist.strip():
        if not is_compilation(ev, ai_data):
            return f"release '{who}' (Various) ma la foto non mostra una compilation"
        artist_words = []
    elif not norm_artist:  # nome in un altro alfabeto (es. cirillico): non confrontabile
        return f"l'artista '{artist}' non si può confrontare con le scritte lette nella foto"
    elif main.coverage(artist) < TEXT_MIN_COVERAGE:
        return f"l'artista '{artist}' non compare tra le scritte principali della foto"
    else:
        artist_words = significant_words(artist) or norm_artist.split()

    # 3. Non basta una sola parola
    full = TextMatcher(ev.text + "\n" + "\n".join(ev.main))
    matched = list(artist_words)  # l'artista è già stato ritrovato tra le scritte principali
    matched += [w for w in (significant_words(title) or dd.normalize_text(title).split()) if full.word_found(w) >= 0.8]
    if len(matched) < 2:
        return f"'{who}' combacia solo per una parola ({', '.join(matched) or 'nessuna'})"
    return ""


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
    metodo: str = ""           # barcode / catno / locale-testo / ai
    motivo: str = ""           # perché va controllato a mano (esito da_verificare)
    gemini: dict = None        # seconda opinione di Gemini (scelta tra gli stessi candidati)

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


class CoverCheck:
    """Confronto visivo con le copertine di Discogs (copertine.py), usato dal riconoscimento:
    - tra più candidati, sceglie quello con la copertina riconosciuta (se stacca gli altri);
    - conferma un riconoscimento senza codice se la copertina della release proposta è la stessa.
    trusted: release già confermate a mano in passato (tabella conferme): per loro niente verifica."""

    def __init__(self, store, matcher, trusted=()):
        self.store, self.matcher, self.trusted = store, matcher, set(trusted)
        self.compared = 0

    def distances(self, photos, candidates, release_data=None):
        covers = {}
        for r in candidates[:copertine_module().MAX_CANDIDATES]:
            try:
                covers[r["id"]] = self.store.paths(r["id"], (release_data or {}).get(r["id"]))
            except (ApiError, ApiUncertain, OSError):
                continue
        self.compared += 1
        return self.matcher.compare([str(p) for p in photos], {k: v for k, v in covers.items() if v})

    def pick(self, photos, candidates):
        """(release scelta o None, testo del confronto). Mai un errore: in caso di problemi, nessuna scelta."""
        try:
            return self._pick(photos, candidates)
        except Exception as e:  # il confronto è un aiuto: non deve mai fermare il lotto
            return None, f"copertine: confronto non riuscito ({type(e).__name__}: {e})"

    def _pick(self, photos, candidates):
        distances = self.distances(photos, candidates)
        chosen_id, text = self.matcher.verdict(distances)
        for r in candidates:
            if r["id"] in distances:
                r["_cover"] = distances[r["id"]]
        chosen = next((r for r in candidates if r["id"] == chosen_id), None)
        return chosen, text

    def distance(self, photos, release):
        """(distanza tra le foto e le immagini della release, o None; testo). Mai un errore."""
        try:
            d = self.distances(photos, [release]).get(release["id"])
        except Exception as e:
            return None, f"copertina: confronto non riuscito ({type(e).__name__}: {e})"
        if d is None:
            return None, "copertina: nessun confronto possibile"
        return d, f"copertina ({self.matcher.backend}): distanza {d:.2f}"

    def clearly_different(self, d):
        """Distanza oltre la zona di dubbio: copertina sicuramente diversa."""
        cm = copertine_module()
        return d is not None and d > cm.STRONG[self.matcher.backend] + cm.DOUBT[self.matcher.backend]

    def confirms(self, photos, release):
        """(True se la copertina della release è quella delle foto, testo). Mai un errore."""
        try:
            return self._confirms(photos, release)
        except Exception as e:
            return False, f"copertina: confronto non riuscito ({type(e).__name__}: {e})"

    def _confirms(self, photos, release):
        distances = self.distances(photos, [release])
        d = distances.get(release["id"])
        if d is None:
            return False, "copertina: nessun confronto possibile"
        return self.matcher.strong(d), f"copertina ({self.matcher.backend}): distanza {d:.2f}" + (
            ", riconosciuta" if self.matcher.strong(d) else ", diversa o non riconoscibile")


def copertine_module():
    import copertine
    return copertine


def recognize(path, con, api, use_ocr, ai=None, cache=None, max_photos=AI_MAX_PHOTOS, covers=None, google=None,
              gemini=None):
    """Riconosce il disco di una foto, o di più foto dello stesso disco (path = lista: sottocartella).
    cache: dati AI già pagati per questo disco ({"read": ..., "choice": ...}), che non vengono mai
    richiesti di nuovo. Un riconoscimento senza codice (AI o artista e titolo) che non supera
    check_match ha esito da_verificare: la release proposta resta salvata ma il disco non va in vendita.
    Con più foto: se i codici letti in foto diverse portano a release diverse, da_verificare."""
    ev = Evidence()
    rec = identify(path, con, api, use_ocr, ai, cache, ev, max_photos, covers, google)
    rec.metodo = method_of(rec.fonte, rec.release)
    if rec.esito == "trovato" and ev.per_photo:
        rec.motivo = photos_in_contrast(con, ev.per_photo, rec.release_id, ev.text)
        if rec.motivo:
            rec.esito = "da_verificare"
            rec.details += f"; DA VERIFICARE: {rec.motivo}"
    paths = list(path) if isinstance(path, (list, tuple)) else [path]
    if rec.esito == "trovato" and rec.metodo in UNVERIFIED_METHODS:
        if covers and rec.release_id in covers.trusted:
            rec.details += "; release già confermata a mano in passato: nessuna verifica"
        elif rec.metodo == "copertina":
            pass  # scelta sulla copertina: il testo non può smentirla
        else:
            rec.motivo = check_match(rec.release, ev, rec.ai_read)
            if covers:
                # PORTA D'USCITA: un disco riconosciuto senza codice va in vendita SOLO se le sue foto
                # combaciano con un'immagine della release su Discogs. Nessuna eccezione (nemmeno se il
                # testo torna o se Gemini concorda): copertina diversa o non confrontabile = a mano.
                ok, text = covers.confirms(paths, rec.release)
                rec.details += f"; {text}"
                if ok and rec.motivo and not is_trap(rec.motivo):
                    rec.details += f" (supera il dubbio: {rec.motivo})"
                    rec.motivo = ""
                elif not ok:
                    rec.motivo = f"{COVER_REASON} ({text})" + (f"; {rec.motivo}" if rec.motivo else "")
            if rec.motivo:
                rec.esito = "da_verificare"
                rec.details += f"; DA VERIFICARE: {rec.motivo}"
    elif rec.esito == "trovato" and covers and rec.release_id not in covers.trusted:
        # Riconosciuto da barcode o catalogo: il codice è affidabile, ma se la copertina è CHIARAMENTE
        # un'altra (non solo poco simile: riflessi e foto storte capitano) il disco si ferma lo stesso.
        d, text = covers.distance(paths, rec.release)
        rec.details += f"; {text}"
        if d is not None and covers.clearly_different(d):
            rec.motivo = f"{COVER_REASON}, anche se trovato con il {rec.metodo or 'codice'} ({text})"
            rec.esito = "da_verificare"
            rec.details += f"; DA VERIFICARE: {rec.motivo}"
    second_opinion(rec, path, gemini, cache)
    if is_unofficial(rec.release):
        rec.details += "; formato 'Unofficial Release': probabilmente bloccata dal marketplace (decide l'API)"
    return rec


def read_all_photos(ev, paths, imgs, use_ocr):
    """Disco con più foto: barcode e OCR di TUTTE le foto, uniti in ev (le scritte principali si
    scelgono foto per foto). Gli indizi di ogni foto restano anche separati in ev.per_photo."""
    for path, img in zip(paths, imgs):
        one = Evidence(barcodes=list(read_barcodes(img)))
        if use_ocr:
            one.add_lines(ocr_lines(img))
            ev.add_lines(one.lines)
        ev.barcodes += [b for b in one.barcodes if b not in ev.barcodes]
        ev.per_photo.append((Path(path).name, one))


WEAK_CATNO_RE = re.compile(r"^[A-Z]{3,}\d$")   # parola + una cifra (es. "Fusion 3", "Chapter 2"): spesso non è un catalogo


def text_supports(release, text):
    """True se il TITOLO della release compare nel testo letto (tollerante agli errori). Solo il titolo:
    in un elenco dell'etichetta l'artista è spesso lo stesso per tutti i dischi."""
    if not text.strip() or not (release.get("title") or "").strip():
        return False
    return TextMatcher(text).coverage(release["title"]) >= TEXT_MIN_COVERAGE


def photo_code_hits(con, one, support_text=""):
    """Release a cui portano i codici letti in una sola foto: (id, descrizione) o (set(), "").
    Un retro che elenca la discografia dell'etichetta (più cataloghi diversi, es. SS26, SS27, SS28) o un
    "catalogo" debole (parola + una cifra, es. "at Fusion 3") vale solo per le release il cui artista o
    titolo compare davvero nelle scritte del disco (support_text): gli altri non sono questo disco."""
    found = search_barcode_local(con, one)
    if found:
        return {r["id"] for r in found}, "barcode " + ", ".join(one.barcodes)
    found = search_catno_local(con, one)
    if found:
        matched = [n for n in one.catnos if any(n in r.get("catno_norms", []) for r in found)]
        listing = len(set(matched)) >= 2 and len({r["id"] for r in found}) >= 2

        def needs_support(r):
            norms = [n for n in r.get("catno_norms", []) if n in one.catnos]
            return listing or (norms and all(WEAK_CATNO_RE.match(n) for n in norms))

        kept = [r for r in found if not needs_support(r) or text_supports(r, support_text)]
        strong = [raw for norm, raw in one.catnos.items() if is_strong_catno(norm)] or list(one.catnos.values())
        if not kept:
            return set(), ""
        note = " (elenco dell'etichetta: solo le release che compaiono nelle scritte)" if len(kept) < len(found) else ""
        return {r["id"] for r in kept}, "catalogo " + ", ".join(strong[:3]) + note
    return set(), ""


def photos_in_contrast(con, per_photo, release_id=None, extra_text=""):
    """Foto dello stesso disco con codici (barcode, catalogo + etichetta) che portano a release
    diverse e incompatibili, o a una release diversa da quella scelta: motivo, o "" se tutto torna.
    extra_text: altro testo letto del disco (es. dall'AI), che può confermare un catalogo debole."""
    support = "\n".join(one.text for _n, one in per_photo) + "\n" + (extra_text or "")
    hits = []
    for name, one in per_photo:
        ids, what = photo_code_hits(con, one, support)
        if ids:
            hits.append((name, ids, what))
    clash = any(not (a[1] & b[1]) for i, a in enumerate(hits) for b in hits[i + 1:])
    if release_id is not None:
        clash = clash or any(release_id not in ids for _n, ids, _w in hits)
    if not clash:
        return ""
    return CONTRAST_REASON + ": " + "; ".join(
        f"{name}: {what} -> release {', '.join(map(str, sorted(ids)[:5]))}" for name, ids, what in hits) + (
        f"; release scelta {release_id}" if release_id is not None else "")


CONTRAST_REASON = "foto della cartella in contrasto"
COVER_REASON = "copertina diversa da quella su Discogs"
# Trappole note: dubbi che né la copertina (una busta bianca somiglia a tutte le buste bianche) né un
# secondo modello possono sciogliere, perché lì si sbaglia allo stesso modo. Restano sempre a mano.
TRAPS = ("scaletta", "From the album", "compilation", "non si può confrontare")


def is_trap(motivo):
    return any(t in (motivo or "") for t in TRAPS)


def identify(path, con, api, use_ocr, ai, cache, ev, max_photos=AI_MAX_PHOTOS, covers=None, google=None):
    """Cascata barcode -> catno -> artista/titolo -> AI. Restituisce un Recognition.
    path: una foto, o la lista delle foto di un disco in sottocartella (indizi uniti, una sola
    chiamata AI con al massimo max_photos foto)."""
    cache = dict(cache or {})
    paths = list(path) if isinstance(path, (list, tuple)) else [path]
    imgs = [load_image(p) for p in paths]
    img = imgs[0] if len(imgs) == 1 else None

    # 1. Parte locale: se il risultato è sicuro, niente AI
    if img is None:  # più foto: tutti gli indizi insieme; codici in contrasto = da controllare, niente AI
        read_all_photos(ev, paths, imgs, use_ocr)
        conflict = photos_in_contrast(con, ev.per_photo)
        if conflict:
            return Recognition("da_verificare", "", None, [], ev.describe() + f"; DA VERIFICARE: {conflict}",
                               motivo=conflict)
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

    # 1b. REGOLA PRINCIPALE: prima le copertine, poi l'AI. La parte locale ha trovato più candidati
    # ma nessuno sicuro: si confrontano le foto con le copertine Discogs dei candidati (e delle altre
    # stampe dello stesso disco). Se UNA combacia nettamente è quella: niente AI, costo zero.
    # Solo se nessuna copertina combacia si passa all'AI (e la scelta dell'AI resta in cache).
    if ranked and covers is not None and not cache.get("choice"):
        local_ranked = expand_by_master(con, ranked, ev, None, ocr_text)
        local_ranked = [x for x in local_ranked if coherent(x[1], None, ocr_text) or x[1].get("_code")]
        shortlist = [r for _s, r, _w in local_ranked[:AI_MAX_CANDIDATES]]
        if shortlist:
            by_cover, text = covers.pick(paths, shortlist)
            if by_cover is not None:
                where = "api" if by_cover.get("_fonte") == "api" else "locale"
                return Recognition("trovato", f"copertina+{where}", by_cover, local_ranked,
                                   ev.describe() + "; prima delle AI: " + text)
            ev.ai_note = (ev.ai_note or "") + f"; prima delle AI: {text}"

    if ai is None and not cache.get("read"):  # --senza-ai: solo metodi gratuiti
        if ranked:
            return Recognition("multiplo", fonte, None, ranked, ev.describe())
        return Recognition("non_trovato", "", None, [], ev.describe())

    # 2. L'AI guarda la foto e dice cosa vede
    cost = 0.0
    image = None
    if ai is not None:
        image = AIVision.prepare(img) if img is not None else [AIVision.prepare(i) for i in imgs[:max_photos]]
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
    google_note = ""
    if not ranked and google is not None and image is not None:
        # Terzo servizio: la ricerca web di Google propone, poi la coerenza e l'AI verificano
        try:
            first = image[0] if isinstance(image, list) else image
            b64 = first[0] if isinstance(first, tuple) else first
            found, google_note = google_candidates(api, google, b64, ev)
        except BudgetReached:
            raise
        except (urllib.error.URLError, OSError, ValueError) as e:
            google_note = f"Google Vision non ha risposto ({e})"
            found = []
        if found:
            local = {r["id"]: r for r in dd.get_releases(con, [r["id"] for r in found])}
            ranked = score_candidates([{**local[r["id"]], "_fonte": "api"} if r["id"] in local else r
                                       for r in found], ev)
            ranked = [x for x in ranked if coherent(x[1], read, ev.text)]
            base = base or "api-google"
    if google_note:
        ev.ai_note = (ev.ai_note or "") + "; " + google_note
    if not ranked:
        return Recognition("non_trovato", "", None, [], ev.describe() + "; nessun candidato coerente con la foto",
                           cost, read)
    ranked = expand_by_master(con, ranked, ev, read, ocr_text)

    def source(r):
        return "api" if r.get("_fonte") == "api" else "locale"

    # Un solo candidato coerente, o un vincitore chiaro: niente seconda chiamata. A meno che
    # un'altra stampa dello stesso master non combaci meglio (catalogo, anno, paese in foto).
    if a_release is not None and coherent(a_release, read, ocr_text):
        own = next((sc for sc, r, _w in ranked if r["id"] == a_release["id"]), 0.0)
        better = [r for sc, r, _w in ranked if r.get("_master_sibling") and sc > own]
        if not better:
            return Recognition("trovato", "ai+" + a_fonte, a_release, ranked, ev.describe(), cost, read)
        ev.ai_note = (ev.ai_note or "") + (f"; altre stampe dello stesso master combaciano meglio: "
                                           f"{', '.join(str(r['id']) for r in better[:5])}")
    if len(ranked) == 1:
        r = ranked[0][1]
        return Recognition("trovato", f"ai+{source(r)}-{(base or 'testo').split('-')[-1]}", r, ranked,
                           ev.describe(), cost, read)

    # 4a. Le copertine: se una sola combacia con le foto, è quella (niente seconda chiamata AI)
    shortlist = [r for _s, r, _w in ranked[:AI_MAX_CANDIDATES]]
    ids = [r["id"] for r in shortlist]
    choice = cache.get("choice")
    if choice is not None and choice.get("release_id") not in ids and choice.get("_ids") != ids:
        choice = None  # i candidati sono cambiati (es. database aggiornato): la scelta va rifatta
    if choice is None and covers is not None:
        by_cover, text = covers.pick(paths, shortlist)
        if by_cover is not None:
            choice = {"release_id": by_cover["id"], "confidence": "high", "reason": text, "_ids": ids}
            return Recognition("trovato", f"copertina+{source(by_cover)}", by_cover, ranked,
                               ev.describe() + "; " + text, cost, read, choice)
        ev_note = text
    else:
        ev_note = ""

    # 4b. L'AI sceglie tra i candidati reali (con le distanze delle copertine, se ci sono)
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
    details = ev.describe() + (f"; {ev_note}" if ev_note else "")
    if choice.get("reason"):
        details += f"; scelta AI ({CONFIDENCE_IT.get(choice.get('confidence'), '?')}): {choice['reason']}"
    if chosen is None:
        return Recognition("non_trovato", base, None, ranked, details + "; l'AI non ha trovato il disco tra i candidati",
                           cost, read, choice)
    return Recognition("trovato", f"ai-scelta+{source(chosen)}", chosen, ranked, details, cost, read, choice)


MASTER_SIBLINGS = 80   # versioni dello stesso master aggiunte ai candidati (al massimo)


def expand_by_master(con, ranked, ev, read, ocr_text):
    """Aggiunge ai candidati le altre stampe degli stessi master (stesso album, altra edizione): il
    testo trova spesso una sola versione, ma catalogo, paese e anno in foto possono indicare un'altra.
    Le versioni aggiunte entrano con lo stesso punteggio del testo (è lo stesso album) più i bonus
    di catalogo/etichetta/anno/paese, e devono essere coerenti con la foto come le altre."""
    masters = [r.get("master_id") for _s, r, _w in ranked[:5] if r.get("master_id")]
    if not masters:
        return ranked
    known = {r["id"] for _s, r, _w in ranked}
    ids = dd.releases_by_master(con, masters, exclude=known, limit=MASTER_SIBLINGS)
    if not ids:
        return ranked
    siblings = [r for r in dd.get_releases(con, ids) if format_allowed(r)]
    extra = [x for x in score_candidates(siblings, ev) if coherent(x[1], read, ocr_text)]
    if not extra:
        return ranked
    for _s, r, why in extra:
        r["_master_sibling"] = True
        why.append("altra versione dello stesso master")
    merged = ranked + extra
    merged.sort(key=lambda x: -x[0])
    return merged


def recognize_safely(path, con, api, use_ocr, ai, cache, max_photos=AI_MAX_PHOTOS, covers=None, google=None,
                     gemini=None):
    """recognize() con gli errori trasformati in esito "errore"; None se il tetto di spesa AI è raggiunto."""
    try:
        return recognize(path, con, api, use_ocr, ai, cache, max_photos, covers, google, gemini)
    except BudgetReached:
        return None
    except urllib.error.HTTPError as e:   # Gemini (o un altro servizio web) ha risposto con un errore
        return Recognition("errore", details=f"servizio esterno: {e}", ai_read=cache["read"], ai_choice=cache["choice"])
    except (ApiError, OSError, ValueError) as e:
        return Recognition("errore", details=str(e), ai_read=cache["read"], ai_choice=cache["choice"])
    except Exception as e:  # errori dell'API di Anthropic
        if type(e).__module__.split(".")[0] != "anthropic":
            raise
        return Recognition("errore", details=f"AI: {e}", ai_read=cache["read"], ai_choice=cache["choice"])


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


def get_collector_data(state, api, con, release_id, currency, release=None, max_age_days=None):
    """Dati per il valore collezionistico di una release, dalla cache o da Discogs.
    want/have dalla release, copie in vendita e prezzo più basso dalle statistiche del marketplace,
    caratteristiche della stampa dal database locale (o dall'API se la release non c'è).
    release: la risposta di GET /releases/{id} se già ottenuta (es. dal controllo di vendibilità).
    Restituisce (dati, richieste fatte a Discogs)."""
    row = state.execute("SELECT dati, ottenuto FROM collezione WHERE release_id = ?", (release_id,)).fetchone()
    if row and not is_stale(row["ottenuto"], max_age_days):
        cached = json.loads(row["dati"])
        if not cached.get("lowest_price") or cached.get("lowest_currency") == currency:
            return cached, 0  # (se la valuta dell'account è cambiata, li richiedo)
    calls = 1
    if release is None:
        release = api.release(release_id)
        calls += 1
    community = release.get("community", {})
    stats = api.marketplace_stats(release_id, currency)
    lowest = stats.get("lowest_price") or {}
    local = dd.get_releases(con, [release_id]) if con is not None else []
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
    return data, calls


# --------------------------------------------------------------------------
# Release bloccate dal marketplace (white label, bootleg, release non ufficiali)
# --------------------------------------------------------------------------

# Campo della risposta di GET /releases/{id} che dice se la release non si può vendere.
BLOCKED_FIELD = "blocked_from_sale"
NOT_SELLABLE_REASON = "bloccata dal marketplace Discogs"


class SaleCheckFailed(Exception):
    """Impossibile sapere se la release si può vendere (rete, errore di Discogs, campo assente)."""


def check_sellable(state, api, release_id, refresh=False, max_age_days=None):
    """(vendibile, risposta di GET /releases/{id} o None se dalla cache, richieste fatte).
    L'esito resta in cache nello stato per max_age_days giorni: nel frattempo nessuna richiesta
    (refresh=True la rifà). Solleva SaleCheckFailed se Discogs non risponde o la risposta non
    contiene BLOCKED_FIELD."""
    row = state.execute("SELECT bloccata, ottenuto FROM vendibilita WHERE release_id = ?", (release_id,)).fetchone()
    if row and not refresh and not is_stale(row["ottenuto"], max_age_days):
        return not row["bloccata"], None, 0
    try:
        release = api.release(release_id)
    except (ApiError, ApiUncertain) as e:
        raise SaleCheckFailed(str(e))
    if not isinstance(release.get(BLOCKED_FIELD), bool):
        raise SaleCheckFailed(f"la risposta di Discogs non contiene il campo {BLOCKED_FIELD}")
    blocked = release[BLOCKED_FIELD]
    state.execute("INSERT OR REPLACE INTO vendibilita VALUES (?, ?, ?)", (release_id, int(blocked), now()))
    state.commit()
    return not blocked, release, 1


def is_unofficial(release):
    """True se nei formati del database locale c'è "Unofficial Release" (di solito bloccata da Discogs)."""
    return "unofficial release" in ((release or {}).get("formats") or "").lower()


def artist_title(disco):
    """'Artista - Titolo' da 'Artista - Titolo (etichetta paese anno)'."""
    disco = disco or ""
    if not disco.endswith(")"):
        return disco
    depth = 0
    for i in range(len(disco) - 1, -1, -1):  # la parentesi che apre l'ultima, anche se ne contiene altre
        depth += {")": 1, "(": -1}.get(disco[i], 0)
        if depth == 0:
            return disco[:i].rstrip()
    return disco


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
# Regola del prezzo
# --------------------------------------------------------------------------

def fmt(x):
    return f"{float(x):.2f}".replace(".", ",")


CENT = decimal.Decimal("0.01")
DEMAND_STEPS = "1:10,2:25,4:50"   # want/have oltre 1 -> +10%, oltre 2 -> +25%, oltre 4 -> +50%


def parse_steps(text):
    """'1:10,2:25,4:50' -> [(1.0, 10.0), (2.0, 25.0), (4.0, 50.0)] (soglia want/have, premio %)."""
    try:
        steps = sorted((float(a), float(b)) for a, b in (part.split(":") for part in text.split(",") if part.strip()))
    except ValueError:
        raise argparse.ArgumentTypeError(f"scalini non validi: {text!r} (esempio: 1:10,2:25,4:50)")
    if not steps:
        raise argparse.ArgumentTypeError("serve almeno uno scalino (esempio: 1:10,2:25,4:50)")
    return steps


def want_have_ratio(data):
    want, have = data.get("want") or 0, data.get("have") or 0
    return want / have if have else (float("inf") if want else 0.0)


def demand_step(ratio, steps):
    """Lo scalino più alto superato dal rapporto want/have (strettamente maggiore): (soglia, premio) o None."""
    passed = [s for s in steps if ratio > s[0]]
    return passed[-1] if passed else None


def to_grid(price, step, minimum):
    """Prezzo arrotondato PER ECCESSO al gradino della griglia (multipli di step) uguale o
    immediatamente superiore, mai sotto minimum. In Decimal, sui centesimi: prima il prezzo
    viene portato al centesimo (10,000000001 -> 10,00), poi al gradino (10,00 resta 10,00)."""
    step = decimal.Decimal(str(step)).quantize(CENT)
    minimum = decimal.Decimal(str(minimum)).quantize(CENT)
    cents = max(decimal.Decimal(str(price)).quantize(CENT, rounding=decimal.ROUND_HALF_UP), minimum)
    steps = (cents / step).to_integral_value(rounding=decimal.ROUND_CEILING)
    return (steps * step).quantize(CENT)


LANE_SLOW_BELOW = 1.0     # want/have sotto questo valore: corsia LENTA
LANE_HOT_ABOVE = 2.0      # want/have sopra questo valore: corsia CALDA
SLOW_DISCOUNT = 5.0       # corsia LENTA: % sotto il prezzo più basso della concorrenza


def grid_floor(price, step):
    """Prezzo arrotondato PER DIFETTO al gradino della griglia (solo per la corsia lenta)."""
    step = decimal.Decimal(str(step)).quantize(CENT)
    cents = decimal.Decimal(str(price)).quantize(CENT, rounding=decimal.ROUND_HALF_UP)
    return ((cents / step).to_integral_value(rounding=decimal.ROUND_FLOOR) * step).quantize(CENT)


def competition(data, my_prices, currency):
    """(copie della concorrenza, prezzo più basso della concorrenza o None, il più basso potrei essere io).
    Le statistiche di Discogs contano anche i miei annunci: le mie copie si tolgono, e se il prezzo più
    basso è uguale o maggiore di un mio prezzo per la release potrei essere io, quindi non vale."""
    copies = data.get("num_for_sale") or 0
    lowest = data.get("lowest_price") if data.get("lowest_currency") == currency else None
    others = max(copies - len(my_prices), 0)
    maybe_me = bool(lowest is not None and my_prices and lowest >= min(my_prices) - 0.005)
    return others, None if maybe_me else lowest, maybe_me


def compute_price(suggested, data, grade, currency, args, competitors=None):
    """(prezzo, testo del calcolo) con le TRE CORSIE in base al rapporto want/have.

    - LENTA (want/have < args.corsia_lenta_sotto): si punta a vendere: args.sconto_corsia_lenta % sotto il
      prezzo più basso della CONCORRENZA, arrotondato alla griglia PER DIFETTO (altrimenti lo sconto
      sparirebbe), mai sotto il suggerito per il grado (sulla griglia per eccesso) né sotto il prezzo
      minimo. Senza concorrenti da sottoquotare non è un disco da svendere: regola normale.
    - NORMALE (tra le due soglie) e CALDA (want/have > args.corsia_calda_sopra): regola standard
      (standard_price), che nella corsia calda applica gli scalini alti del premio richiesta.
    competitors: (copie, prezzo più basso) della concorrenza, senza i miei annunci (competition);
    se None si usano le statistiche così come sono. Con args.corsie_off: solo la regola standard."""
    if data is None or args.corsie_off:
        return standard_price(suggested, data, grade, currency, args)
    ratio = want_have_ratio(data)
    lane_slow, lane_hot = args.corsia_lenta_sotto, args.corsia_calda_sopra
    if competitors is None:
        competitors = competition(data, [], currency)[:2]
    others, others_lowest = competitors
    if ratio < lane_slow:
        lane = f"corsia LENTA (want/have {fmt(ratio)} < {lane_slow:g})"
        if others > 0 and others_lowest:
            low = decimal.Decimal(str(others_lowest))
            target = (low * (1 - decimal.Decimal(str(args.sconto_corsia_lenta)) / 100)).quantize(
                CENT, rounding=decimal.ROUND_HALF_UP)
            down = grid_floor(target, args.passo_prezzo)
            floor = to_grid(suggested, args.passo_prezzo, args.prezzo_minimo)
            text = (f"{lane}: {args.sconto_corsia_lenta:g}% sotto concorrenza {fmt(low)} = {fmt(target)} "
                    f"→ griglia per difetto {fmt(down)}")
            if down < floor:
                return float(floor), (f"{text}; sotto il suggerito {grade} {fmt(suggested)}: prezzo = suggerito "
                                      f"sulla griglia {fmt(floor)} {currency}")
            return float(down), f"{text} {currency}"
        prefix = f"{lane}: nessun concorrente da sottoquotare, regola NORMALE"
    elif ratio > lane_hot:
        prefix = f"corsia CALDA (want/have {fmt(ratio)} > {lane_hot:g}): premi a scalini"
    else:
        prefix = f"corsia NORMALE (want/have {fmt(ratio)} tra {lane_slow:g} e {lane_hot:g})"
    price, calc = standard_price(suggested, data, grade, currency, args)
    return price, f"{prefix}; {calc}"


def standard_price(suggested, data, grade, currency, args):
    """(prezzo, testo del calcolo): la regola unica (corsie normale e calda, o --corsie-off).

    Base = prezzo più basso in vendita, mai sotto il suggerito per il grado.
    Premio scarsità (copie in vendita): 0 -> suggerito + 100%; 1-2 -> base + 50%;
    3-5 -> base + 25%; oltre -> nulla. Premio richiesta: want/have sopra 1 -> +10%.
    I premi si sommano; nessun tetto. Ultimo passaggio: arrotondamento per eccesso alla griglia
    (passo args.passo_prezzo, minimo args.prezzo_minimo). Tutti i numeri vengono da args."""

    def finish(raw, steps):
        price = to_grid(raw, args.passo_prezzo, args.prezzo_minimo)
        steps[-1] += f" → arrotondato a griglia {fmt(args.passo_prezzo)} = {fmt(price)} {currency}"
        return float(price), "; ".join(steps)

    steps = [f"suggerito {grade} {fmt(suggested)}"]
    if data is None:
        return finish(suggested, [f"dati del marketplace non disponibili: prezzo = suggerito {fmt(suggested)} {currency}"])
    copies = data.get("num_for_sale") or 0
    lowest = data.get("lowest_price") if data.get("lowest_currency") == currency else None
    if copies == 0 or not lowest:
        base = suggested
        steps.append("nessun prezzo in vendita" if copies == 0 else "prezzo più basso non disponibile")
        steps.append(f"base = suggerito {fmt(base)}")
    else:
        steps.append(f"più basso in vendita {fmt(lowest)}")
        base = max(lowest, suggested)
        steps.append(f"base = {'più basso in vendita' if lowest >= suggested else 'suggerito (soglia minima)'} {fmt(base)}")

    premiums = []

    def premium(percent, text):
        premiums.append(percent)
        steps.append(f"{text} +{percent:g}%")

    if copies == 0:
        premium(args.premio_zero_copie, "0 copie in vendita")
    elif copies <= args.copie_poche:
        premium(args.premio_poche_copie, f"{copies} copie in vendita (1-{args.copie_poche})")
    elif copies <= args.copie_alcune:
        premium(args.premio_alcune_copie, f"{copies} copie in vendita ({args.copie_poche + 1}-{args.copie_alcune})")
    else:
        steps.append(f"{copies} copie in vendita: nessun premio scarsità")

    want, have = data.get("want") or 0, data.get("have") or 0
    ratio = want_have_ratio(data)
    ratio_text = f"want/have {want}/{have}" + (f" = {fmt(ratio)}" if have else "")
    step = demand_step(ratio, args.scalini_richiesta)
    if step:
        premium(step[1], f"{ratio_text} > {step[0]:g}")
    else:
        steps.append(f"{ratio_text}: nessun premio richiesta")

    total = sum(premiums)
    raw = (decimal.Decimal(str(base)) * (1 + decimal.Decimal(str(total)) / 100)).quantize(
        CENT, rounding=decimal.ROUND_HALF_UP)
    steps.append(f"prezzo = {fmt(base)} × (1 + {total:g}%) = {fmt(raw)} {currency}")
    return finish(raw, steps)


# --------------------------------------------------------------------------
# Stato (ripresa dopo un'interruzione)
# --------------------------------------------------------------------------

STATE_SCHEMA = """
CREATE TABLE IF NOT EXISTS foto (
    external_id TEXT PRIMARY KEY,   -- nome della foto senza estensione, o <sottocartella>-<impronta breve>
    cartella    TEXT,
    foto        TEXT,
    impronta    TEXT,
    media       TEXT,
    sleeve      TEXT,
    esito       TEXT,     -- trovato / multiplo / non_trovato / senza_prezzo / errore / da_verificare /
                          -- non_vendibile (bloccata dal marketplace) / non_verificato (vendibilità sconosciuta)
    fonte       TEXT,     -- locale-barcode / locale-catno / api-barcode / api-catno
    release_id  INTEGER,
    candidati   TEXT,
    dettagli    TEXT,
    aggiornato  TEXT,
    riga_csv    TEXT,     -- external_id della riga CSV in cui è finita la foto
    ai_dati     TEXT,     -- cosa ha letto l'AI nella foto (mai richiesto due volte)
    ai_costo    REAL DEFAULT 0,  -- spesa AI per questa foto (euro, 1 $ = 1 €)
    ai_scelta   TEXT,     -- scelta dell'AI tra i candidati, con sicurezza e motivo
    hash        TEXT,     -- SHA-256 del contenuto della foto (riconosce la stessa foto anche spostata)
    ai2_dati    TEXT,     -- secondo tentativo con un modello più forte: cosa ha letto
    ai2_scelta  TEXT,     -- secondo tentativo: scelta tra i candidati
    ai2_modello TEXT,     -- secondo tentativo: modello che ha letto e scelto (vuoto = claude-sonnet-5-5)
    gemini_scelta TEXT,   -- seconda opinione di Gemini tra gli stessi candidati (mai richiesta due volte)
    secondo     TEXT,     -- modello del secondo tentativo, se è lui ad aver riconosciuto il disco
    disco       TEXT,     -- artista - titolo (etichetta, paese, anno) della release trovata
    metodo      TEXT,     -- barcode / catno / locale-testo / ai
    motivo      TEXT,     -- perché è da verificare a mano (esito da_verificare)
    prezzo      REAL,     -- prezzo calcolato per una foto da verificare (non messa in vendita)
    n_foto      INTEGER,  -- disco in sottocartella: quante foto (vuoto = una foto sola)
    hash_foto   TEXT      -- disco in sottocartella: impronte delle singole foto (JSON)
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
    destinazione TEXT,
    calcolo     TEXT,
    sleeve      TEXT      -- grado della copertina (vuoto nelle versioni precedenti = come il disco)
);
CREATE TABLE IF NOT EXISTS vendibilita (   -- release bloccate o no dal marketplace (GET /releases/{id})
    release_id INTEGER PRIMARY KEY,
    bloccata   INTEGER,   -- 1 = non si può vendere
    ottenuto   TEXT
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
    foto        TEXT,     -- tutte le foto del gruppo
    calcolo     TEXT,     -- come è stato calcolato il prezzo
    status      TEXT,     -- FOR_SALE / DRAFT (vuoto = FOR_SALE, versioni precedenti)
    online      TEXT,     -- da verifica_inventario.py: in_vendita / bozza / venduto / scaduto / assente / sparito
    online_verificato TEXT,  -- data dell'ultima verifica
    online_visto TEXT,    -- prima volta che è stata vista online su Discogs
    online_ultimo TEXT,   -- ultimo stato visto online (in_vendita / bozza / ...)
    online_annunci TEXT   -- id degli annunci Discogs visti per questa riga (JSON), per collegarli agli ordini
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
    inviato     TEXT,
    calcolo     TEXT,     -- come è stato calcolato il prezzo
    status      TEXT,     -- FOR_SALE / DRAFT (vuoto = FOR_SALE, versioni precedenti)
    online      TEXT,     -- come in righe_csv
    online_verificato TEXT,
    online_visto TEXT,
    online_ultimo TEXT,
    online_annunci TEXT
);
CREATE TABLE IF NOT EXISTS conferme (     -- release scelte a mano (--abbina, pannello): memoria delle conferme
    external_id TEXT PRIMARY KEY,
    release_id  INTEGER,
    artista     TEXT,
    titolo      TEXT,
    etichette   TEXT,
    quando      TEXT
);
CREATE TABLE IF NOT EXISTS rielaborati (  -- stato archiviato da --rielabora (per sicurezza, mai cancellato)
    tabella     TEXT,
    external_id TEXT,
    dati        TEXT,     -- la riga com'era, in JSON
    archiviato  TEXT
);
CREATE TABLE IF NOT EXISTS bozze_pubblicate ( -- bozze messe in vendita da pubblica_bozze.py
    listing_id  INTEGER PRIMARY KEY,
    external_id TEXT,
    release_id  INTEGER,
    price       REAL,
    origine     TEXT,     -- CSV / API
    pubblicato  TEXT
);
"""


BACKUPS_TO_KEEP = 20


def backup_state(path=None, keep=BACKUPS_TO_KEEP):
    """Copia dello stato in data/backup/vendita_stato_AAAAMMGG_HHMMSS.sqlite (API di backup di
    sqlite3: copia coerente anche se il file è in uso). Tiene solo le ultime `keep` copie.
    Restituisce il percorso della copia, o None se lo stato non esiste ancora."""
    path = Path(path or STATE_DB)
    if not path.exists():
        return None
    folder = path.parent / "backup"
    folder.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    dest, n = folder / f"vendita_stato_{stamp}.sqlite", 1
    while dest.exists():  # più lanci nello stesso secondo
        n += 1
        dest = folder / f"vendita_stato_{stamp}_{n:02d}.sqlite"
    src, dst = sqlite3.connect(path), sqlite3.connect(dest)
    try:
        src.backup(dst)
    finally:
        dst.close()
        src.close()
    copies = sorted(folder.glob("vendita_stato_*.sqlite"), key=lambda p: (p.stat().st_mtime, p.name))
    for old in copies[:max(len(copies) - max(keep, 1), 0)]:
        old.unlink()
    return dest


def open_state(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(path)
    con.row_factory = sqlite3.Row
    con.executescript(STATE_SCHEMA)
    for table, column, decl in [("foto", "ai_dati", "TEXT"), ("foto", "ai_costo", "REAL DEFAULT 0"),
                                ("foto", "ai_scelta", "TEXT"), ("foto", "disco", "TEXT"),
                                ("righe_csv", "calcolo", "TEXT"), ("annunci_api", "calcolo", "TEXT"),
                                ("collezionistici", "calcolo", "TEXT"), ("righe_csv", "status", "TEXT"),
                                ("annunci_api", "status", "TEXT"), ("foto", "metodo", "TEXT"),
                                ("foto", "motivo", "TEXT"), ("foto", "prezzo", "REAL"),
                                ("righe_csv", "online", "TEXT"), ("righe_csv", "online_verificato", "TEXT"),
                                ("righe_csv", "online_visto", "TEXT"), ("annunci_api", "online", "TEXT"),
                                ("annunci_api", "online_verificato", "TEXT"), ("annunci_api", "online_visto", "TEXT"),
                                ("righe_csv", "online_ultimo", "TEXT"), ("annunci_api", "online_ultimo", "TEXT"),
                                ("foto", "hash", "TEXT"), ("foto", "ai2_dati", "TEXT"),
                                ("foto", "ai2_scelta", "TEXT"), ("foto", "secondo", "TEXT"),
                                ("righe_csv", "online_annunci", "TEXT"), ("annunci_api", "online_annunci", "TEXT"),
                                ("foto", "n_foto", "INTEGER"), ("foto", "hash_foto", "TEXT"), ("foto", "ai2_modello", "TEXT"), ("foto", "gemini_scelta", "TEXT"),
                                ("collezionistici", "sleeve", "TEXT")]:  # stato di una versione precedente
        if column not in {r["name"] for r in con.execute(f"PRAGMA table_info({table})")}:
            con.execute(f"ALTER TABLE {table} ADD COLUMN {column} {decl}")
    old = con.execute("SELECT name FROM sqlite_master WHERE name IN ('annunci', 'csv_righe')").fetchall()
    if any(con.execute(f"SELECT COUNT(*) FROM {r['name']}").fetchone()[0] for r in old):
        print("Attenzione: lo stato contiene dati della versione precedente (foto numerate), che vengono ignorati.\n"
              "Se avevi già pubblicato annunci con quella versione, controllali su Discogs.")
    return con


def is_local_source(fonte):
    """True se la release è stata trovata nel database locale (anche dopo la lettura dell'AI)."""
    return (fonte or "").split("+")[-1].startswith("locale") or fonte == "manuale"


# --------------------------------------------------------------------------
# Cosa è davvero online: inventario Discogs confrontato con lo stato
# --------------------------------------------------------------------------

# Stati dell'inventario Discogs da leggere. "For Sale" e "Draft" sono indispensabili; gli altri
# servono a riconoscere i venduti e, se Discogs non li restituisce, vengono segnalati e saltati.
INVENTORY_STATUSES = ["For Sale", "Draft", "Sold", "Expired"]
ONLINE_OF = {"For Sale": "in_vendita", "Draft": "bozza", "Sold": "venduto", "Expired": "scaduto"}
ONLINE_ORDER = ["in_vendita", "bozza", "venduto", "scaduto"]
ONLINE_IT = {"in_vendita": "in vendita", "bozza": "in bozza", "venduto": "venduto", "scaduto": "scaduto",
             "assente": "non online", "bozza_cancellata": "bozza cancellata",
             "bloccata": "bloccata da Discogs",
             "rimosso": "rimosso a mano (era in vendita, non è in nessun ordine)",
             "forse_venduto": "forse venduto (la release è in un ordine)",
             "sparito": "sparito (era online: venduto o cancellato? ordini non letti)"}
FREEABLE = ("assente", "bozza_cancellata", "rimosso")   # mai il venduto, mai il bloccato


class OrdersUnreadable(Exception):
    """I miei ordini Discogs non si possono leggere, o non dicono quale annuncio è stato venduto."""


@dataclass
class Sales:
    listing_ids: set    # annunci venduti (articoli di ordini non annullati)
    external_ids: set   # external_id degli articoli, se Discogs li restituisce
    release_ids: set    # release vendute


def fetch_sales(api):
    """Annunci venduti, dai miei ordini Discogs (tutte le pagine, tutti gli stati). Gli ordini annullati
    non contano. Ogni articolo di un ordine deve avere l'id dell'annuncio ("id"): è l'unico collegamento
    affidabile con i miei annunci; se manca, gli ordini non valgono come prova e si solleva
    OrdersUnreadable."""
    sales, page = Sales(set(), set(), set()), 1
    while True:
        try:
            data = api.orders_page(page)
        except (ApiError, ApiUncertain) as e:
            raise OrdersUnreadable(str(e))
        orders = data.get("orders", [])
        for order in orders:
            if "cancel" in str(order.get("status", "")).lower():
                continue
            for item in order.get("items", []):
                if item.get("id") is None:
                    raise OrdersUnreadable(f"l'articolo di un ordine ({order.get('id')}) non contiene l'id "
                                           "dell'annuncio: impossibile collegare l'ordine ai miei annunci")
                sales.listing_ids.add(item["id"])
                if (item.get("release") or {}).get("id"):
                    sales.release_ids.add(item["release"]["id"])
                if item.get("external_id"):
                    sales.external_ids.add(item["external_id"])
        if not orders or page >= data.get("pagination", {}).get("pages", 1):
            return sales
        page += 1


class InventoryUnreadable(Exception):
    """L'inventario Discogs non si può leggere (rete, errore di Discogs, campo external_id assente)."""


@dataclass
class Inventory:
    by_eid: dict        # external_id -> [annunci]
    by_listing: dict    # listing_id -> annuncio
    unavailable: list   # stati che Discogs non ha restituito (es. "Sold")


def fetch_inventory(api, username, statuses=INVENTORY_STATUSES):
    """Tutto l'inventario Discogs del venditore (tutte le pagine, uno stato alla volta)."""
    items, unavailable = {}, []
    for status in statuses:
        page = 1
        while True:
            try:
                data = api.inventory_page(username, page, status=status)
            except (ApiError, ApiUncertain) as e:
                if status in ("For Sale", "Draft"):
                    raise InventoryUnreadable(f"annunci '{status}': {e}")
                unavailable.append(status)
                break
            listings = data.get("listings", [])
            for item in listings:
                items[item["id"]] = item
            if not listings or page >= data.get("pagination", {}).get("pages", 1):
                break
            page += 1
    if items and not any("external_id" in item for item in items.values()):
        raise InventoryUnreadable("gli annunci restituiti da Discogs non contengono il campo external_id: "
                                  "impossibile collegarli alle foto")
    by_eid = {}
    for item in items.values():
        if item.get("external_id"):
            by_eid.setdefault(item["external_id"], []).append(item)
    return Inventory(by_eid, items, unavailable)


def online_of(items):
    """Lo stato online più "vivo" tra gli annunci di uno stesso external_id."""
    found = {ONLINE_OF.get(i.get("status"), "scaduto") for i in items}
    return next((o for o in ONLINE_ORDER if o in found), "scaduto")


def verify_listings(state, inventory, sales=None):
    """Confronta righe CSV e annunci API dello stato con l'inventario Discogs (e con i miei ordini, se
    `sales` non è None) e salva per ognuno lo stato online, la data della verifica, la prima volta
    che è stato visto online, l'ultimo stato visto e gli id degli annunci visti.

    Online: in_vendita / bozza / venduto / scaduto. Non più online (l'inventario non mostra i venduti):
    - "venduto": un suo annuncio (o external_id) è in un ordine non annullato; resta per sempre;
    - "forse_venduto": nessun annuncio mai visto, ma la release è in un ordine;
    - "bloccata": la release è bloccata dal marketplace (tabella vendibilita);
    - "assente": mai visto online (CSV mai caricato o riga scartata);
    - "bozza_cancellata": l'ultima volta era una bozza (una bozza non si vende);
    - "rimosso": era in vendita e non è in nessun ordine (tolto a mano);
    - "sparito": era in vendita, ordini non letti: venduto o tolto a mano, non si sa.
    Corregge lo status (FOR_SALE / DRAFT) in base a Discogs: le righe CSV caricate come DRAFT sono
    in vendita, perché Discogs ignora DRAFT nei CSV. Restituisce [(tabella, riga aggiornata)]."""
    when = now()
    blocked = {r[0] for r in state.execute("SELECT release_id FROM vendibilita WHERE bloccata = 1")}
    for table in ("righe_csv", "annunci_api"):
        for row in state.execute(f"SELECT * FROM {table}").fetchall():
            if table == "annunci_api" and row["stato"] == "pronto":
                continue  # non ancora inviato a Discogs: niente da verificare
            items = list(inventory.by_eid.get(row["external_id"], []))
            if table == "annunci_api" and row["listing_id"] in inventory.by_listing:
                item = inventory.by_listing[row["listing_id"]]
                if item not in items:
                    items.append(item)
            seen_ids = set(json.loads(row["online_annunci"] or "[]"))
            if table == "annunci_api" and row["listing_id"]:
                seen_ids.add(row["listing_id"])
            if items:
                online = online_of(items)
                seen_ids |= {i["id"] for i in items}
                status = {"in_vendita": "FOR_SALE", "bozza": "DRAFT"}.get(online, row["status"])
                state.execute(f"UPDATE {table} SET online = ?, online_ultimo = ?, online_verificato = ?,"
                              " online_visto = COALESCE(online_visto, ?), status = ?, online_annunci = ?"
                              " WHERE external_id = ?",
                              (online, online, when, when, status, json.dumps(sorted(seen_ids)), row["external_id"]))
                continue
            if row["online"] == "venduto":
                online = "venduto"  # venduto una volta, venduto per sempre
            elif sales is not None and (seen_ids & sales.listing_ids or row["external_id"] in sales.external_ids):
                online = "venduto"
            elif sales is not None and not seen_ids and row["release_id"] in sales.release_ids:
                online = "forse_venduto"
            elif sales is None and row["online"] == "forse_venduto":
                online = "forse_venduto"
            elif row["release_id"] in blocked:
                online = "bloccata"
            elif not row["online_visto"]:
                online = "assente"
            elif row["online_ultimo"] == "bozza":
                online = "bozza_cancellata"
            else:
                online = "rimosso" if sales is not None else "sparito"
            state.execute(f"UPDATE {table} SET online = ?, online_verificato = ? WHERE external_id = ?",
                          (online, when, row["external_id"]))
    state.commit()
    return [(t, r) for t in ("righe_csv", "annunci_api")
            for r in state.execute(f"SELECT * FROM {t}").fetchall()]


def can_free(table, row):
    """True se la riga si può togliere dallo stato senza rischiare di vendere un disco che non c'è più:
    mai online, bozza cancellata, o rimossa a mano (era in vendita e non è in nessun ordine). Mai
    una riga venduta, forse venduta, sparita (ordini non letti) o bloccata da Discogs."""
    if table == "annunci_api" and row["stato"] in ("pronto", "rifiutato"):
        return True   # mai andato online
    if row["online"] not in FREEABLE:
        return False
    return table == "righe_csv" or row["stato"] != "in_corso"


def csv_members(state, row_id):
    """Foto (external_id) di una riga CSV: tutte le copie del gruppo."""
    members = {r[0] for r in state.execute("SELECT external_id FROM foto WHERE riga_csv = ?", (row_id,))}
    members.add(row_id)
    return members


def archive_part_files(out_dir, parts, state):
    """Mai cancellare un inventario_NNN.csv: una parte rimasta senza righe va in
    risultati/archivio/inventario_NNN_ANNULLATO.csv; una parte che perde solo alcune righe viene
    prima copiata in archivio (inventario_NNN_PRIMA_<data>.csv) e poi riscritta da write_outputs."""
    import shutil
    archive = out_dir / "archivio"
    stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    for part in sorted(parts):
        path = out_dir / f"inventario_{part:03d}.csv"
        if not path.exists():
            continue
        archive.mkdir(parents=True, exist_ok=True)
        if state.execute("SELECT 1 FROM righe_csv WHERE parte = ?", (part,)).fetchone():
            shutil.copy2(path, archive / f"inventario_{part:03d}_PRIMA_{stamp}.csv")
        else:
            dest = archive / f"inventario_{part:03d}_ANNULLATO.csv"
            if dest.exists():
                dest = archive / f"inventario_{part:03d}_ANNULLATO_{stamp}.csv"
            shutil.move(str(path), dest)


def free_rows(state, out_dir, rows):
    """Toglie dallo stato righe CSV e annunci API (copiandoli nella tabella rielaborati): le loro foto
    tornano elaborabili, con il riconoscimento già fatto. Restituisce le foto liberate."""
    freed, parts, archive = set(), set(), []
    for table, row in rows:
        archive.append((table, row["external_id"], json.dumps(dict(row)), now()))
        state.execute(f"DELETE FROM {table} WHERE external_id = ?", (row["external_id"],))
        if table == "righe_csv":
            members = csv_members(state, row["external_id"])
            parts.add(row["parte"])
            state.executemany("UPDATE foto SET riga_csv = NULL WHERE external_id = ?", [(m,) for m in members])
            freed |= members
        else:
            freed.add(listing_owner(row["external_id"]))
    state.executemany("DELETE FROM collezionistici WHERE external_id = ?", [(r["external_id"],) for _, r in rows])
    state.executemany("INSERT INTO rielaborati VALUES (?, ?, ?, ?)", archive)
    state.commit()
    archive_part_files(out_dir, parts, state)
    return freed


def group_loose_photos(args):
    """--grado: le foto sciolte nella cartella del lotto vanno in <grado>/disco-NNN prima dell'elaborazione
    (raggruppa_foto.py, con anteprima e conferma). Senza foto sciolte non fa niente."""
    import raggruppa_foto
    source = Path(args.cartella).expanduser()
    if not raggruppa_foto.loose_photos(source):
        return
    grades = read_grades(args.grado)
    if not grades:
        raise SystemExit(f"--grado non valido: {args.grado} (usa {GRADE_FORMATS})")
    grade_dir = source / grade_text(*grades)
    groups = raggruppa_foto.plan(source, grade_dir, raggruppa_foto.PAUSE_SECONDS, args.per_disco)
    raggruppa_foto.show_plan(groups, grade_dir, raggruppa_foto.PAUSE_SECONDS, args.per_disco)
    if args.simula:
        print("Simulazione: le foto restano dove sono.")
        return
    if not args.si and not raggruppa_foto.ask_confirmation(f"Spostare le foto in {len(groups)} sottocartelle?"):
        raise SystemExit("Annullato: nessuna foto è stata spostata.")
    raggruppa_foto.move_groups(groups, grade_dir)


def open_panel(out_dir):
    """Apre il pannello nel browser (solo su macOS, fuori dai test): quello collegato (python pannello.py)
    se è acceso, altrimenti il file risultati/pannello.html."""
    import socket
    import subprocess
    path = Path(out_dir) / "pannello.html"
    # Solo se lanciato a mano da un Terminale: mai dai test o da un altro programma (pannello.py)
    if sys.platform != "darwin" or not path.exists() or not sys.stdout.isatty():
        return
    target = str(path)
    try:
        with socket.create_connection(("127.0.0.1", 8765), timeout=0.3):
            target = "http://127.0.0.1:8765/"
    except OSError:
        pass
    try:
        subprocess.run(["open", target], check=False, timeout=10)
    except (OSError, subprocess.SubprocessError):
        pass


def assign_releases(state, con, api, text):
    """--abbina disco-001=24344624,...: la release scelta a mano per un disco fermo. La foto passa a
    esito trovato (fonte/metodo 'manuale', niente controlli automatici: ha deciso una persona) e la
    conferma resta nella tabella conferme. Restituisce [(external_id, release)]."""
    done = []
    for item in [t.strip() for t in text.split(",") if t.strip()]:
        name, _, rid = item.partition("=")
        if not rid.strip().isdigit():
            raise SystemExit(f"--abbina: scrivi disco=numero della release Discogs, es. disco-001=24344624 (non '{item}')")
        rid = int(rid)
        eid = find_disc(state, name.strip())
        foto = state.execute("SELECT * FROM foto WHERE external_id = ?", (eid,)).fetchone()
        if foto["riga_csv"] or state.execute("SELECT 1 FROM annunci_api WHERE external_id = ? AND stato <> 'pronto'",
                                             (eid,)).fetchone():
            raise SystemExit(f"--abbina: {eid} è già in vendita (o in un CSV): prima --togli, poi --abbina.")
        releases = dd.get_releases(con, [rid])
        if releases:
            release = releases[0]
        else:
            data = api.release(rid)
            release = api_release_as_release(data)
        if not format_allowed(release):
            raise SystemExit(f"--abbina: la release {rid} ({describe_release(release)}) non è nei formati ammessi "
                             f"({', '.join(ALLOWED_FORMATS)}).")
        state.execute("DELETE FROM annunci_api WHERE external_id = ? AND stato = 'pronto'", (eid,))
        state.execute("UPDATE foto SET esito = 'trovato', fonte = 'manuale', metodo = 'manuale', release_id = ?,"
                      " disco = ?, motivo = NULL, prezzo = NULL, dettagli = COALESCE(dettagli, '') || ?,"
                      " aggiornato = ? WHERE external_id = ?",
                      (rid, describe_release(release), f"; abbinato a mano alla release {rid}", now(), eid))
        state.execute("INSERT OR REPLACE INTO conferme VALUES (?,?,?,?,?,?)",
                      (eid, rid, release.get("artists") or "", release.get("title") or "",
                       release.get("labels") or "", now()))
        done.append((eid, release))
    state.commit()
    return done


def api_release_as_release(data):
    """GET /releases/{id} nello stesso formato delle release del database locale."""
    labels = data.get("labels") or []
    return {
        "id": data["id"], "artists": ", ".join(a.get("name", "") for a in data.get("artists", [])),
        "title": data.get("title", ""),
        "labels": "; ".join(f"{l.get('name', '')} ({l.get('catno', '')})" for l in labels),
        "label_names": [l.get("name", "") for l in labels],
        "catno_norms": [dd.normalize_catno(l.get("catno", "")) for l in labels if l.get("catno")],
        "country": data.get("country", ""), "year": data.get("year") or None,
        "formats": ", ".join(", ".join([f.get("name", "")] + f.get("descriptions", [])) for f in data.get("formats", [])),
        "barcodes": [i.get("value", "") for i in data.get("identifiers", []) if i.get("type") == "Barcode"][:3],
        "_fonte": "api",
    }


def disc_matches(photo, names):
    """True se il disco è tra quelli indicati: per external_id, per nome (M/disco-013) o per sottocartella."""
    return bool({photo.external_id, photo.path.name, f"{photo.folder}/{photo.path.name}"} & names)


def find_disc(state, name):
    """external_id della foto/disco indicato con --togli: nome esatto, oppure inizio univoco (disco-019)."""
    row = state.execute("SELECT external_id FROM foto WHERE external_id = ?", (name,)).fetchone()
    if row:
        return row[0]
    found = [r[0] for r in state.execute("SELECT external_id FROM foto WHERE external_id LIKE ? ESCAPE '\\'",
                                          (name.replace("_", "\\_").replace("%", "\\%") + "-%",))]
    if len(found) == 1:
        return found[0]
    if not found:
        raise SystemExit(f"--togli: nessun disco '{name}' nello stato. Usa il nome che compare nell'output "
                         "(es. disco-019-847f678b).")
    raise SystemExit(f"--togli: '{name}' corrisponde a più dischi ({', '.join(sorted(found, key=natural_key))}): "
                     "scrivi il nome completo.")


def remove_discs(state, out_dir, names):
    """--togli: toglie dei dischi dall'inventario. La riga CSV che li contiene viene tolta (copiata nella
    tabella rielaborati, il file CSV di prima resta in risultati/archivio/); le altre copie della riga
    tornano da elaborare al prossimo lancio, con il riconoscimento già fatto, in un file CSV nuovo.
    Mai su righe o annunci che sono stati online: lì si corregge su Discogs.
    Restituisce (dischi tolti, righe tolte, copie che tornano da elaborare)."""
    targets = [find_disc(state, n) for n in names]
    rows, listings = {}, []
    for eid in targets:
        for a in state.execute("SELECT * FROM annunci_api WHERE external_id = ? OR external_id LIKE ?",
                               (eid, eid + "-copia%")).fetchall():
            if a["stato"] not in ("pronto", "rifiutato"):
                raise SystemExit(f"--togli: {eid} è già stato messo in vendita via API (annuncio {a['external_id']}"
                                 f", {a['stato']}): toglilo da Discogs.")
            listings.append(("annunci_api", a))
        foto = state.execute("SELECT riga_csv FROM foto WHERE external_id = ?", (eid,)).fetchone()
        row = foto["riga_csv"] and state.execute("SELECT * FROM righe_csv WHERE external_id = ?",
                                                 (foto["riga_csv"],)).fetchone()
        if row:
            if row["online_visto"] or (row["online"] and row["online"] not in FREEABLE):
                raise SystemExit(f"--togli: la riga {row['external_id']} di inventario_{row['parte']:03d}.csv "
                                 "risulta già online su Discogs: correggila su Discogs, non qui.")
            rows[row["external_id"]] = row
    freed = free_rows(state, out_dir, [("righe_csv", r) for r in rows.values()] + listings)
    state.executemany("UPDATE foto SET esito = 'tolto', motivo = 'tolto a mano con --togli', riga_csv = NULL"
                      " WHERE external_id = ?", [(e,) for e in targets])
    state.commit()
    return targets, list(rows.values()), sorted(freed - set(targets), key=natural_key)


def prepare_rework(state, photos, out_dir, inventory, sales=None):
    """--rielabora: le foto indicate tornano da elaborare da capo (riconoscimento, AI compresa,
    prezzo e annuncio). inventory: l'inventario Discogs letto all'inizio (None se non leggibile).

    Una riga CSV o un annuncio API si rielabora SOLO se il suo external_id non è online su
    Discogs e non lo è mai stato (can_free dopo verify_listings): un CSV caricato è in vendita
    anche se le righe dicevano DRAFT. Se l'inventario non si legge, nessuna riga CSV né annuncio
    viene toccato. Le righe tolte finiscono nella tabella rielaborati; i file CSV non vengono mai
    cancellati ma archiviati in risultati/archivio/. La spesa AI già fatta resta contata nel tetto.
    Restituisce (rielaborate, saltate)."""
    ids = {p.external_id for p in photos}
    if sales is None:
        inventory = None  # senza ordini non si distingue un venduto: nessuna riga si tocca
    if inventory is not None:
        verify_listings(state, inventory, sales)
    skipped, to_free = set(), []
    for row in state.execute("SELECT * FROM righe_csv").fetchall():
        members = csv_members(state, row["external_id"])
        if not members & ids:
            continue
        if inventory is not None and can_free("righe_csv", row):
            to_free.append(("righe_csv", row))
            ids |= members  # tutte le copie della riga tornano da elaborare
        else:
            skipped |= members
    by_owner = {}   # un disco con copie-N ha un annuncio per copia: si rielabora solo se tutte sono libere
    for row in state.execute("SELECT * FROM annunci_api").fetchall():
        if listing_owner(row["external_id"]) in ids:
            by_owner.setdefault(listing_owner(row["external_id"]), []).append(row)
    for owner, rows in by_owner.items():
        if inventory is not None and all(can_free("annunci_api", row) for row in rows):
            to_free += [("annunci_api", row) for row in rows]
        else:
            skipped.add(owner)
    free_rows(state, out_dir, to_free)
    removed = {r[0] for r in state.execute("SELECT external_id FROM foto WHERE esito = 'tolto'")}
    redo = ids - skipped - removed
    archive = [("foto", r["external_id"], json.dumps(dict(r)), now())
               for r in state.execute("SELECT * FROM foto").fetchall() if r["external_id"] in redo]
    state.executemany("DELETE FROM collezionistici WHERE external_id = ?", [(e,) for e in redo])
    state.executemany("UPDATE foto SET esito = 'rielabora', riga_csv = NULL, ai_dati = NULL, ai_scelta = NULL,"
                      " prezzo = NULL, motivo = NULL WHERE external_id = ?", [(e,) for e in redo])
    state.executemany("INSERT INTO rielaborati VALUES (?, ?, ?, ?)", archive)
    state.commit()
    return sorted(redo, key=natural_key), sorted(skipped, key=natural_key)


def money(eur):
    return f"{eur:.2f} €" if eur >= 1 else f"{eur:.3f} €"


def is_assigned(state, external_id, copies=1):
    """True se la foto (o il disco) è già in una riga CSV o ha già gli annunci via API di tutte le copie."""
    row = state.execute("SELECT riga_csv FROM foto WHERE external_id = ?", (external_id,)).fetchone()
    if row and row["riga_csv"]:
        return True
    return all(state.execute("SELECT 1 FROM annunci_api WHERE external_id = ?", (eid,)).fetchone() is not None
               for eid in copy_ids(external_id, copies))


CACHE_PRICES_DAYS = 30        # prezzi suggeriti e dati del marketplace
CACHE_SELLABLE_DAYS = 90      # vendibilità (blocked_from_sale)


SAME_RECORD_SECONDS = 90


def same_record_gap(photos, seconds):
    """Foto della stessa release e dello stesso grado: (secondi tra i due scatti più vicini se sotto
    `seconds`, altrimenti None; foto senza DateTimeOriginal; testo con la data usata per ogni foto).
    Due scatti a pochi secondi sono quasi sempre lo stesso disco (fronte e retro), non due copie.
    Solo le foto con DateTimeOriginal si confrontano: senza, non si decide e le copie si sommano."""
    taken = [(photo_taken_at(p.path), p) for p in photos]
    missing = [p for t, p in taken if t is None]
    times = sorted(t for t, _p in taken if t is not None)
    gaps = [(b - a).total_seconds() for a, b in zip(times, times[1:])]
    close = min((g for g in gaps if g < seconds), default=None)
    used = ", ".join(f"{p.external_id}: " + (f"DateTimeOriginal {t:%Y-%m-%d %H:%M:%S}" if t else
                                               "data di scatto mancante") for t, p in taken)
    return close, missing, used


def same_title_other_release(items):
    """Gruppi di foto [(foto, riga)] con lo stesso artista e titolo (confronto tollerante: maiuscole,
    accenti, punteggiatura, "(2)" negli artisti) ma release diverse."""
    by_title = {}
    for photo, row in items:
        key = dd.normalize_text(clean_artist(artist_title(row["disco"])))
        if row["release_id"] and key:
            by_title.setdefault(key, []).append((photo, row))
    return [members for members in by_title.values() if len({r["release_id"] for _, r in members}) > 1]


def is_stale(when, max_age_days):
    """True se un dato salvato il `when` (ISO) è più vecchio di max_age_days giorni (None = mai)."""
    if max_age_days is None:
        return False
    try:
        return dt.datetime.now() - dt.datetime.fromisoformat(when) > dt.timedelta(days=max_age_days)
    except (TypeError, ValueError):
        return True


def get_price_suggestions(state, api, release_id, refresh=False, max_age_days=None):
    """Prezzi suggeriti per tutti i gradi, dalla cache se più recenti di max_age_days giorni."""
    row = state.execute("SELECT suggeriti, ottenuto FROM prezzi WHERE release_id = ?", (release_id,)).fetchone()
    if row and not refresh and not is_stale(row["ottenuto"], max_age_days):
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
# Stato degli annunci: nel CSV (FOR_SALE / DRAFT) e via API ("For Sale" / "Draft").
API_STATUS = {"FOR_SALE": "For Sale", "DRAFT": "Draft"}
LISTING_HEADER = ["external_id", "release_id", "price", "media_condition", "sleeve_condition", "status",
                  "calcolo_prezzo"]


def csv_row(release_id, price, media, sleeve, quantity, external_id):
    """Riga del CSV di inventario. Lo status è sempre FOR_SALE: Discogs ignora DRAFT nei CSV e mette
    comunque in vendita, quindi un DRAFT nel file darebbe solo una falsa sicurezza (le bozze vere
    si creano via API con --bozza)."""
    return [release_id, f"{price:.2f}", GRADES[media], GRADES[sleeve], quantity, external_id, "FOR_SALE"]


def write_csv(path, header, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


def photo_name(path):
    """'VG+/IMG_1234.HEIC' invece del percorso completo."""
    return f"{Path(path).parent.name}/{Path(path).name}" if path else ""


def display_name(row):
    """Come mostrare una riga della tabella foto: 'VG+/IMG_1234.HEIC' o 'VG+/disco-001 (3 foto)'."""
    name = photo_name(row["foto"])
    return f"{name} ({row['n_foto']} foto)" if name and row["n_foto"] else name


COPY_RE = re.compile(r"^(.*)-copia\d+$")


def listing_owner(external_id):
    """Disco a cui appartiene un annuncio API: le copie oltre la prima di un disco con "copie-N"
    hanno external_id '<disco>-copia2', '<disco>-copia3'..."""
    m = COPY_RE.match(external_id or "")
    return m.group(1) if m else external_id


def send_listing(state, api, row, stats, info=""):
    """Invia a Discogs l'annuncio della riga di annunci_api (stato pronto o in_corso): prima lo segna
    in_corso (niente doppioni se si interrompe), poi POST. Restituisce pubblicato / rifiutato / incerto."""
    eid = row["external_id"]
    state.execute("UPDATE annunci_api SET stato = 'in_corso', inviato = ? WHERE external_id = ?", (now(), eid))
    state.commit()
    status = API_STATUS[row["status"] or "FOR_SALE"]
    try:
        resp = api.create_listing(row["release_id"], GRADES[row["media"]], GRADES[row["sleeve"]], row["price"],
                                  eid, status)
    except ApiUncertain as e:
        print(f"{info}: esito della pubblicazione di {eid} incerto ({e}), verrà controllato al prossimo avvio")
        return "incerto"
    except ApiError as e:
        state.execute("UPDATE annunci_api SET stato = 'rifiutato', messaggio = ? WHERE external_id = ?",
                      (str(e), eid))
        state.commit()
        stats["problemi"] += 1
        print(f"{info}: annuncio {eid} rifiutato da Discogs ({e})")
        return "rifiutato"
    state.execute("UPDATE annunci_api SET stato = 'pubblicato', listing_id = ?, messaggio = NULL"
                  " WHERE external_id = ?", (resp.get("listing_id"), eid))
    state.commit()
    stats["api"] += 1
    print(f"{info} -> annuncio {eid} " + ("creato in bozza" if status == "Draft" else "pubblicato")
          + f" via API (listing {resp.get('listing_id')})")
    return "pubblicato"


def publish_pending(state, api, stats):
    """--pubblica: invia a Discogs tutti gli annunci in stato pronto (ordine naturale)."""
    rows = sorted(state.execute("SELECT * FROM annunci_api WHERE stato = 'pronto'").fetchall(),
                  key=lambda r: natural_key(r["external_id"]))
    if not rows:
        print("Niente da pubblicare: nessun annuncio in attesa.")
        return 0
    print(f"Pubblico su Discogs {len(rows)} annunci in attesa...")
    done = 0
    for r in rows:
        foto = state.execute("SELECT disco FROM foto WHERE external_id = ?", (listing_owner(r["external_id"]),)).fetchone()
        info = f"{(foto['disco'] if foto else '') or 'release ' + str(r['release_id'])}: {r['price']:.2f}"
        if send_listing(state, api, r, stats, info) == "pubblicato":
            done += 1
    return done


def copy_ids(external_id, copies):
    """external_id degli annunci API di un disco con `copies` copie (l'API non ha un campo quantità)."""
    return [external_id] + [f"{external_id}-copia{k}" for k in range(2, copies + 1)]


def last_part(state):
    """Numero più alto mai usato per un inventario_NNN.csv, comprese le parti archiviate: un file
    nuovo non riprende mai il nome di uno vecchio (che potrebbe essere già stato caricato)."""
    current = state.execute("SELECT COALESCE(MAX(parte), 0) FROM righe_csv").fetchone()[0]
    archived = state.execute("SELECT COALESCE(MAX(json_extract(dati, '$.parte')), 0) FROM rielaborati"
                             " WHERE tabella = 'righe_csv'").fetchone()[0]
    return max(current, archived or 0)


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
    "da_verificare": "riconoscimento da verificare a mano",
    "non_verificato": "impossibile verificare se è vendibile",
    "stesso_disco": "probabilmente lo stesso disco fotografato più volte",
}
CHECK_HEADER = ["foto", "cartella", "grado", "grado_copertina", "motivo", "release_id_proposto", "disco_proposto", "metodo", "prezzo_calcolato",
                "link_proposto", "dettagli", "candidati"]


COLLECTOR_HEADER = ["external_id", "release_id", "grado", "grado_copertina", "quantita", "foto", "disco", "punteggio", "motivi",
                    "prezzo_suggerito", "prezzo_piu_basso_in_vendita", "prezzo_finale", "valuta", "destinazione",
                    "calcolo_prezzo", "link"]


def collector_csv_rows(rows):
    out = []
    for r in rows:
        r = list(r)
        sleeve = (r.pop(14) if len(r) > 14 else None) or r[2]   # versioni precedenti: come il disco
        r[8] = f"{r[8]:.2f}"
        r[9] = f"{r[9]:.2f}" if r[9] else ""
        r[10] = f"{r[10]:.2f}"
        out.append(r[:3] + [sleeve] + r[3:] + [f"https://www.discogs.com/release/{r[1]}"])
    out.sort(key=lambda r: -int(r[7]))
    return out


REGISTRY_HEADER = ["lotto", "file", "disco", "release_id", "grado_disco", "grado_copertina", "copie", "prezzo",
                   "foto", "percorso_foto", "external_id", "online", "link"]


def write_registry(state, out_dir, csv_rows, api_rows):
    """registro.csv: tutto quello che è stato messo in vendita, in un posto solo. Una riga per riga CSV
    (o annuncio API): lotto, file da cui proviene, disco, gradi, copie, prezzo, foto. Si riscrive a
    ogni lancio dallo stato, quindi è sempre aggiornato (anche dopo --togli)."""
    def info(eid):
        r = state.execute("SELECT foto, disco, n_foto FROM foto WHERE external_id = ?", (eid,)).fetchone()
        if r is None or not r["foto"]:
            return "", "", "", ""
        path = Path(r["foto"])
        return path.parent.parent.name, display_name(r), str(path), r["disco"] or ""

    rows = []
    for r in csv_rows:
        lot, photos, path, disco = info(r["external_id"])
        rows.append([lot, f"inventario_{r['parte']:03d}.csv", disco, r["release_id"], r["media"],
                     r["sleeve"] or r["media"], r["quantita"], f"{r['price']:.2f}", photos, path, r["external_id"],
                     r["online"] or "", f"https://www.discogs.com/release/{r['release_id']}"])
    for r in api_rows:
        lot, photos, path, disco = info(listing_owner(r["external_id"]))
        ready = r["stato"] == "pronto"
        rows.append([lot, "API (da pubblicare)" if ready else "API", disco, r["release_id"], r["media"],
                     r["sleeve"] or r["media"], 1, f"{r['price']:.2f}", photos, path, r["external_id"],
                     "da_pubblicare" if ready else (r["online"] or ""),
                     f"https://www.discogs.com/release/{r['release_id']}" if ready
                     else f"https://www.discogs.com/sell/item/{r['listing_id']}"])
    write_csv(out_dir / "registro.csv", REGISTRY_HEADER, rows)


def write_panel_from_state(state, out_dir):
    """risultati/pannello.html: inventario visivo (in vendita e da controllare) con le foto."""
    import pannello
    data = pannello.collect(state, REASONS, PROBLEMS, display_name, listing_owner, NOT_SELLABLE_REASON,
                            out_dir)
    return pannello.write_panel(out_dir, data, dt.datetime.now().strftime("%d/%m/%Y %H:%M"))


def write_outputs(state, out_dir, simulated_csv, simulated_listings, simulated_collectors=(), simulated_rows_info=()):
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
    write_csv(out_dir / "inventario_foto.csv",
              ["file", "external_id", "release_id", "quantity", "prezzo", "status", "foto", "calcolo_prezzo"],
              [[f"inventario_{r['parte']:03d}.csv", r["external_id"], r["release_id"], r["quantita"],
                f"{r['price']:.2f}", "FOR_SALE", r["foto"], r["calcolo"] or ""] for r in all_rows])

    published = sorted(state.execute("SELECT * FROM annunci_api WHERE stato = 'pubblicato'").fetchall(),
                       key=lambda r: natural_key(r["external_id"]))
    pending = sorted(state.execute("SELECT * FROM annunci_api WHERE stato = 'pronto'").fetchall(),
                     key=lambda r: natural_key(r["external_id"]))
    write_registry(state, out_dir, all_rows, published + pending)
    write_panel_from_state(state, out_dir)
    write_csv(out_dir / "annunci_pubblicati_api.csv", LISTING_HEADER + ["listing_id", "link"],
              [[r["external_id"], r["release_id"], f"{r['price']:.2f}", GRADES[r["media"]], GRADES[r["sleeve"]],
                API_STATUS[r["status"] or "FOR_SALE"], r["calcolo"] or "", r["listing_id"], f"https://www.discogs.com/sell/item/{r['listing_id']}"]
               for r in published])

    # Da controllare a mano.
    rows = []
    for r in state.execute("SELECT * FROM foto WHERE esito IN ({})".format(",".join("?" * len(PROBLEMS))),
                           sorted(PROBLEMS)):
        motivo = REASONS[r["esito"]] + (f": {r['motivo']}" if r["motivo"] else "")
        rows.append([display_name(r), r["cartella"], r["media"] or "", r["sleeve"] or "", motivo,
                     r["release_id"] or "", r["disco"] or "",
                     r["metodo"] or method_of(r["fonte"], None), f"{r['prezzo']:.2f}" if r["prezzo"] else "",
                     f"https://www.discogs.com/release/{r['release_id']}" if r["release_id"] else "",
                     r["dettagli"] or "", r["candidati"] or ""])
    for r in state.execute("SELECT a.*, f.foto, f.n_foto, f.cartella, f.disco, f.metodo, f.fonte FROM annunci_api a "
                           "LEFT JOIN foto f ON f.external_id = a.external_id OR a.external_id LIKE "
                           "f.external_id || '-copia%' WHERE a.stato IN ('in_corso', 'rifiutato')"):
        if r["stato"] == "in_corso":
            motivo = "pubblicazione non confermata: controlla su Discogs se l'annuncio esiste già"
        else:
            motivo = "Discogs ha rifiutato l'annuncio"
        rows.append([display_name(r), r["cartella"], r["media"] or "", r["sleeve"] or "", motivo,
                     r["release_id"], r["disco"] or "",
                     r["metodo"] or method_of(r["fonte"], None), f"{r['price']:.2f}",
                     f"https://www.discogs.com/release/{r['release_id']}", r["messaggio"] or "", ""])
    rows.sort(key=lambda r: natural_key(r[0]))
    write_csv(out_dir / "da_controllare.csv", CHECK_HEADER, rows)

    # Come è stata riconosciuta ogni foto, con la spesa AI per disco.
    recog = []
    for r in state.execute("SELECT * FROM foto"):
        chosen = r["ai2_scelta"] if r["secondo"] else r["ai_scelta"]
        choice = json.loads(chosen) if chosen and r["esito"] == "trovato" else {}
        recog.append([display_name(r), r["cartella"], r["esito"], r["fonte"] or "", r["release_id"] or "",
                      r["disco"] or "", CONFIDENCE_IT.get(choice.get("confidence"), ""), choice.get("reason", ""),
                      f"{r['ai_costo'] or 0:.4f}"])
    recog.sort(key=lambda r: natural_key(Path(r[0]).name))
    write_csv(out_dir / "riconoscimento.csv",
              ["foto", "cartella", "esito", "metodo", "release_id", "disco", "sicurezza_ai", "motivo_ai", "costo_ai_eur"],
              recog)

    # Release bloccate dal marketplace: non si possono vendere su Discogs.
    blocked = []
    for r in state.execute("SELECT * FROM foto WHERE esito = 'non_vendibile'"):
        blocked.append([display_name(r), r["media"], r["sleeve"], r["release_id"], artist_title(r["disco"]),
                        r["metodo"] or method_of(r["fonte"], None), f"https://www.discogs.com/release/{r['release_id']}",
                        r["motivo"] or NOT_SELLABLE_REASON])
    blocked.sort(key=lambda r: natural_key(Path(r[0]).name))
    write_csv(out_dir / "non_vendibili.csv",
              ["foto", "grado", "grado_copertina", "release_id", "artista_titolo", "metodo", "link", "motivo"],
              blocked)

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
        write_csv(sim_dir / "inventario_foto.csv",
                  ["external_id", "release_id", "quantity", "prezzo", "status", "foto", "calcolo_prezzo"],
                  simulated_rows_info)
    return len(rows)


# --------------------------------------------------------------------------
# Programma principale
# --------------------------------------------------------------------------

def add_price_args(parser):
    """Opzioni della regola del prezzo, comuni a vendi.py e riprezza.py (stessa regola e stessi default)."""
    g = parser.add_argument_group("regola del prezzo (base = più basso in vendita, mai sotto il suggerito per il grado)")
    g.add_argument("--premio-zero-copie", type=float, default=100.0,
                   help="nessuna copia in vendita: suggerito + questa %% (default 100)")
    g.add_argument("--copie-poche", type=int, default=2, help="fino a quante copie in vendita sono 'poche' (default 2)")
    g.add_argument("--premio-poche-copie", type=float, default=50.0, help="premio %% con poche copie (default 50)")
    g.add_argument("--copie-alcune", type=int, default=5, help="fino a quante copie in vendita sono 'alcune' (default 5)")
    g.add_argument("--premio-alcune-copie", type=float, default=25.0, help="premio %% con alcune copie (default 25)")
    g.add_argument("--scalini-richiesta", type=parse_steps, default=parse_steps(DEMAND_STEPS),
                   help="premio richiesta a scalini, 'soglia:premio%%' separati da virgole: si applica lo scalino più "
                        f"alto superato dal rapporto want/have (default {DEMAND_STEPS}: oltre 1 +10%%, oltre 2 +25%%, "
                        "oltre 4 +50%%)")
    g.add_argument("--corsia-lenta-sotto", type=float, default=LANE_SLOW_BELOW,
                   help=f"want/have sotto questo valore: corsia LENTA, si sottoquota la concorrenza "
                        f"(default {LANE_SLOW_BELOW:g})")
    g.add_argument("--corsia-calda-sopra", type=float, default=LANE_HOT_ABOVE,
                   help=f"want/have sopra questo valore: corsia CALDA, premi a scalini alti (default {LANE_HOT_ABOVE:g})")
    g.add_argument("--sconto-corsia-lenta", type=float, default=SLOW_DISCOUNT,
                   help=f"corsia LENTA: %% sotto il prezzo più basso della concorrenza (default {SLOW_DISCOUNT:g})")
    g.add_argument("--corsie-off", action="store_true",
                   help="niente corsie: regola unica per tutti i dischi (come prima delle corsie)")
    g.add_argument("--passo-prezzo", type=decimal.Decimal, default=decimal.Decimal("2.50"),
                   help="ultimo passaggio: il prezzo finale si arrotonda per eccesso a multipli di questa cifra "
                        "(default 2.50: 2.50, 5.00, 7.50...)")
    g.add_argument("--prezzo-minimo", type=decimal.Decimal, default=decimal.Decimal("2.50"),
                   help="nessun annuncio sotto questa cifra (default 2.50)")
    parser.add_argument("--soglia-controllo", type=float, default=100.0,
                        help="i dischi riconosciuti senza barcode o catalogo esatto (AI o artista e titolo) con prezzo "
                             "finale sopra questa soglia (valuta del tuo account), o collezionistici, non vanno in "
                             "vendita ma in da_controllare.csv (default 100); in riprezza.py: un prezzo nuovo sopra "
                             "questa soglia va controllato a mano")
    return g


def check_price_args(args):
    if args.passo_prezzo < decimal.Decimal("0.01") or args.prezzo_minimo < 0:
        raise SystemExit("--passo-prezzo deve essere almeno 0.01 e --prezzo-minimo non negativo.")
    if args.corsia_lenta_sotto > args.corsia_calda_sopra:
        raise SystemExit("--corsia-lenta-sotto non può essere più alta di --corsia-calda-sopra.")
    if not 0 <= args.sconto_corsia_lenta < 100:
        raise SystemExit("--sconto-corsia-lenta deve essere tra 0 e 100.")


def my_listed_prices(state, release_id):
    """Prezzi dei miei annunci in vendita per una release, secondo lo stato (una voce per copia):
    righe CSV e annunci API in vendita, esclusi quelli venduti, spariti o mai caricati (verifica_inventario)."""
    prices = []
    for r in state.execute("SELECT price, quantita FROM righe_csv WHERE release_id = ? AND "
                           "(online IS NULL OR online = 'in_vendita')", (release_id,)):
        prices += [r["price"]] * (r["quantita"] or 1)
    for r in state.execute("SELECT price FROM annunci_api WHERE release_id = ? AND stato = 'pubblicato' AND "
                           "COALESCE(status, 'FOR_SALE') = 'FOR_SALE' AND (online IS NULL OR online = 'in_vendita')",
                           (release_id,)):
        prices.append(r["price"])
    return prices


def main():
    """Esegue vendi.py e chiude sempre database e stato, anche se lo script si ferma a metà
    (chiave mancante, errore di rete, Ctrl+C...)."""
    opened = []
    try:
        run(opened)
    finally:
        for resource in opened:
            resource.close()


def run(opened):
    parser = argparse.ArgumentParser(description="Metti in vendita su Discogs i dischi fotografati")
    parser.add_argument("cartella", nargs="?",
                        help="cartella che contiene le sottocartelle dei gradi: M, NM, VG+, VG, G+, G "
                             "(stesso grado per disco e copertina) oppure DISCO_COPERTINA, es. M_NM, VG+_VG. "
                             "Si può omettere con --pubblica, --togli o --abbina")
    parser.add_argument("--pubblica", action="store_true",
                        help="pubblica su Discogs (via API, in vendita) tutti gli annunci pronti: quelli di questa "
                             "esecuzione e quelli rimasti in attesa dalle precedenti. Senza, i dischi riconosciuti "
                             "restano 'pronti' da guardare nel pannello")
    parser.add_argument("--csv", action="store_true",
                        help="come prima: i dischi trovati nel database locale finiscono nei file inventario_NNN.csv "
                             "da caricare a mano, quelli trovati solo via API vanno online subito")
    parser.add_argument("--grado", metavar="GRADO",
                        help="foto sciolte nella cartella del lotto (es. appena arrivate con AirDrop): prima le "
                             "raggruppa in <cartella>/<GRADO>/disco-NNN (anteprima e conferma), poi le elabora. "
                             f"GRADO: {', '.join(GRADES)} oppure DISCO_COPERTINA, es. M_NM")
    parser.add_argument("--per-disco", type=int, default=2, metavar="N",
                        help="con --grado: foto per disco, nell'ordine di scatto (default 2: fronte e retro); "
                             "0 = un disco nuovo dopo una pausa tra gli scatti")
    parser.add_argument("--si", action="store_true", help="con --grado: sposta le foto senza chiedere conferma")
    parser.add_argument("--senza-pannello", action="store_true",
                        help="non aprire il pannello (risultati/pannello.html) alla fine")
    parser.add_argument("--abbina", metavar="DISCO=RELEASE",
                        help="riconoscimento a mano: assegna a un disco fermo la release Discogs giusta, es. "
                             "disco-001=24344624 (più dischi separati da virgola); al prossimo lancio viene prezzato "
                             "e messo tra i pronti. Resta in memoria tra le conferme")
    add_price_args(parser)
    parser.add_argument("--soglia-prezzo", type=float, default=50.0,
                        help="per collezionistici.csv: prezzo (valuta del tuo account) oltre il quale un disco "
                             "conta come di valore (default 50)")
    parser.add_argument("--soglia-collezionistico", type=int, default=4,
                        help="per collezionistici.csv: punteggio minimo per considerare un disco collezionistico (default 4)")
    parser.add_argument("--limite", type=int, help="elabora solo i primi N dischi (foto sciolte o sottocartelle; prova)")
    parser.add_argument("--bozza", action="store_true",
                        help="crea tutti gli annunci come bozza (Draft) via API, anche quelli che andrebbero nel CSV "
                             "(Discogs ignora DRAFT nei CSV e li metterebbe subito in vendita); un annuncio per foto")
    parser.add_argument("--simula", action="store_true",
                        help="non pubblica annunci via API e non modifica i CSV veri: scrive tutto in risultati/simulazione/")
    parser.add_argument("--riprova", action="store_true",
                        help="rianalizza anche le foto finite da controllare (non trovate, più release, senza prezzo)")
    parser.add_argument("--togli", metavar="DISCHI",
                        help="toglie dall'inventario uno o più dischi (es. disco-019-847f678b, separati da virgola) "
                             "fotografati per errore o da non vendere: la loro riga CSV viene tolta e le altre copie "
                             "della riga tornano da elaborare al prossimo lancio; non si usa su righe già online")
    parser.add_argument("--copie-diverse", metavar="DISCHI",
                        help="sottocartelle con la stessa release e grado che sono davvero copie diverse "
                             "(es. disco-013,disco-019): senza questa conferma si fermano da controllare")
    parser.add_argument("--rielabora", action="store_true",
                        help="ignora lo stato salvato per le foto di questa cartella e le rielabora da capo (anche l'AI, "
                             "che viene pagata di nuovo); solo insieme a --bozza; prima legge l'inventario Discogs e "
                             "salta tutte le foto online (o state online)")
    parser.add_argument("--senza-gemini", action="store_true",
                        help="non chiedere la seconda opinione a Gemini (attiva da sola se in .env c'è GEMINI_API_KEY)")
    parser.add_argument("--gemini-modello", default=GEMINI_DEFAULT, choices=sorted(GEMINI_MODELS),
                        help=f"modello Gemini per la seconda opinione (default {GEMINI_DEFAULT})")
    parser.add_argument("--senza-google", action="store_true",
                        help="non usare Google Vision (si attiva da solo se in .env c'è GOOGLE_VISION_KEY)")
    parser.add_argument("--google-vision", action="store_true",
                        help="terzo servizio sui dischi non trovati: ricerca web dell'immagine con Google Cloud "
                             "Vision (chiave GOOGLE_VISION_KEY in .env; circa 0,35 cent a foto, conta nel tetto AI)")
    parser.add_argument("--senza-copertine", action="store_true",
                        help="non confrontare le foto con le copertine di Discogs (copertine.py)")
    parser.add_argument("--senza-ai", action="store_true",
                        help="non usa l'AI: solo riconoscimento locale gratuito (le foto incerte vanno da controllare)")
    parser.add_argument("--ai-tetto", type=float, default=50.0,
                        help="spesa AI massima in euro, sommando tutte le esecuzioni (default 50); raggiunta, lo script si ferma")
    parser.add_argument("--ai-modello", default="claude-haiku-4-5", choices=sorted(AI_MODELS),
                        help="modello AI (default claude-haiku-4-5, il più economico)")
    parser.add_argument("--formati-ammessi", default="Vinyl",
                        help="formati Discogs ammessi, separati da virgole (default Vinyl): le release senza nessuno "
                             "di questi formati vengono scartate (Vinyl + CD va bene, solo CD no)")
    parser.add_argument("--ai-modello-secondo", default=AI_SECOND_MODEL, choices=sorted(AI_MODELS),
                        help="modello più forte per un secondo tentativo sulle foto non trovate o con più release "
                             f"possibili dopo il primo (default {AI_SECOND_MODEL}); stesso tetto di spesa")
    parser.add_argument("--senza-secondo-tentativo", action="store_true",
                        help="non fa il secondo tentativo con il modello più forte")
    parser.add_argument("--ai-max-foto", type=int, default=AI_MAX_PHOTOS,
                        help="disco in sottocartella: quante foto al massimo inviare all'AI nella stessa chiamata "
                             f"(default {AI_MAX_PHOTOS})")
    parser.add_argument("--db", default=str(dd.DEFAULT_DB), help="database creato da discogs_dump.py")
    parser.add_argument("--uscita", default=str(OUT_DIR), help="cartella dei risultati (default: risultati/)")
    parser.add_argument("--backup-da-tenere", type=int, default=BACKUPS_TO_KEEP,
                        help=f"copie dello stato da tenere in data/backup/ (default {BACKUPS_TO_KEEP})")
    parser.add_argument("--secondi-stesso-disco", type=float, default=SAME_RECORD_SECONDS,
                        help="due foto della stessa release e grado scattate a meno di tanti secondi sono considerate "
                             f"lo stesso disco (es. fronte e retro) e vanno da controllare (default {SAME_RECORD_SECONDS})")
    parser.add_argument("--copie-consecutive", action="store_true",
                        help="disattiva il controllo sui secondi: le foto della stessa release e grado sono sempre "
                             "copie diverse (quando fotografi davvero più copie una dopo l'altra)")
    parser.add_argument("--cache-prezzi-giorni", type=float, default=CACHE_PRICES_DAYS,
                        help="dopo quanti giorni prezzi suggeriti, copie in vendita e want/have salvati si richiedono "
                             f"di nuovo a Discogs (default {CACHE_PRICES_DAYS})")
    parser.add_argument("--cache-vendibilita-giorni", type=float, default=CACHE_SELLABLE_DAYS,
                        help="dopo quanti giorni si ricontrolla se una release è bloccata dal marketplace "
                             f"(default {CACHE_SELLABLE_DAYS})")
    args = parser.parse_args()
    status = "DRAFT" if args.bozza else "FOR_SALE"
    check_price_args(args)
    if args.ai_max_foto < 1:
        parser.error("--ai-max-foto deve essere almeno 1")
    ALLOWED_FORMATS[:] = [f.strip() for f in args.formati_ammessi.split(",") if f.strip()] or ["Vinyl"]
    if args.rielabora and not args.bozza:
        raise SystemExit("--rielabora funziona solo insieme a --bozza: rielaborando foto già elaborate gli annunci\n"
                         "devono essere bozze, per non mettere mai in vendita dei doppioni.")
    if args.rielabora and args.simula:
        raise SystemExit("--rielabora cambia lo stato vero (data/vendita_stato.sqlite) e non si può usare con --simula:\n"
                         "per ripetere un test usa --rielabora --bozza, gli annunci restano bozze.")

    if not (args.cartella or args.togli or args.abbina or args.pubblica):
        parser.error("indica la cartella delle foto (oppure --pubblica, --togli, --abbina)")
    if args.cartella and not Path(args.cartella).expanduser().is_dir():
        folder = Path(args.cartella).expanduser()
        similar = sorted(p.name for p in folder.parent.glob("*") if p.is_dir()
                         and p.name.replace(" ", "-").lower() == folder.name.replace(" ", "-").lower())
        raise SystemExit(f"Cartella non trovata: {folder}"
                         + (f"\nForse intendevi: {folder.parent / similar[0]} (nel Terminale va tra virgolette se ha "
                            "uno spazio, oppure rinominala con il trattino)" if similar else ""))
    if (args.togli or args.abbina or args.pubblica) and args.simula:
        parser.error("--togli, --abbina e --pubblica cambiano lo stato vero: non si usano con --simula")
    if args.togli:
        saved = backup_state(STATE_DB, args.backup_da_tenere)
        if saved:
            print(f"Backup dello stato: {saved}")
        state = open_state(STATE_DB)
        opened.append(state)
        out_dir = Path(args.uscita).expanduser()
        targets, rows, rest = remove_discs(state, out_dir, [n.strip() for n in args.togli.split(",") if n.strip()])
        write_outputs(state, out_dir, [], [])
        for eid in targets:
            print(f"Tolto: {eid}")
        for r in rows:
            print(f"  riga {r['external_id']} (release {r['release_id']}, {r['quantita']} copie) tolta da "
                  f"inventario_{r['parte']:03d}.csv; la versione di prima è in {out_dir / 'archivio'}")
        if rest:
            print(f"  tornano da elaborare: {', '.join(rest)}: rilancia vendi.py su questa cartella, finiranno "
                  "in un file CSV nuovo")
        print("Se avevi già caricato su Discogs il file di prima, NON ricaricarlo: dimmelo e si corregge su Discogs.")
        return

    if args.abbina:
        saved = backup_state(STATE_DB, args.backup_da_tenere)
        if saved:
            print(f"Backup dello stato: {saved}")
        state = open_state(STATE_DB)
        opened.append(state)
        con = dd.open_db(args.db)
        opened.append(con)
        api = DiscogsAPI(load_token())
        for eid, release in assign_releases(state, con, api, args.abbina):
            print(f"Abbinato: {eid} -> {describe_release(release)} [release {release['id']}]")
        write_outputs(state, Path(args.uscita).expanduser(), [], [])
        if not args.cartella:
            print("Al prossimo lancio di vendi.py sulla cartella del lotto il disco viene prezzato e messo tra i pronti.")
            return

    if not args.cartella:   # solo --pubblica
        api = DiscogsAPI(load_token())
        identity = api.identity()
        print(f"Collegato a Discogs come {identity.get('username')}")
        saved = backup_state(STATE_DB, args.backup_da_tenere)
        if saved:
            print(f"Backup dello stato: {saved}")
        state = open_state(STATE_DB)
        opened.append(state)
        recover_pending_listings(state, api, identity["username"])
        stats = {"api": 0, "problemi": 0}
        done = publish_pending(state, api, stats)
        write_outputs(state, Path(args.uscita).expanduser(), [], [])
        print(f"Pubblicati: {done}; rifiutati: {stats['problemi']}; richieste API: {api.calls}")
        return

    if args.grado:
        group_loose_photos(args)

    photos, warnings = scan_photos(args.cartella)
    for w in warnings:
        print(f"Attenzione: {w}")
    if args.limite:
        photos = photos[:args.limite]
    discs = sum(1 for p in photos if p.is_disc)
    print(f"Foto da elaborare: {len(photos)}" + (f" ({discs} dischi in sottocartella, "
                                                 f"{sum(len(p.files) for p in photos if p.is_disc)} foto)" if discs else "")
          + (" (SIMULAZIONE: nessun annuncio verrà pubblicato)" if args.simula else "")
          + (" - annunci come BOZZA (Draft)" if args.bozza else ""))

    con = dd.open_db(args.db)
    opened.append(con)
    use_ocr = ocr_available()
    if not use_ocr:
        print("Attenzione: OCR non disponibile (serve macOS con 'pip install ocrmac'): uso solo il barcode.")
    api = DiscogsAPI(load_token())
    identity = api.identity()  # controlla subito che il token funzioni
    account_currency = api.user(identity["username"]).get("curr_abbr", "")
    print(f"Collegato a Discogs come {identity.get('username')} (valuta dell'account: {account_currency or '?'})")

    if not args.simula:
        saved = backup_state(STATE_DB, args.backup_da_tenere)
        if saved:
            print(f"Backup dello stato: {saved}")
    state = open_state(STATE_DB)
    opened.append(state)
    ai = ai2 = None
    ai_spent_before = state.execute("SELECT COALESCE(SUM(ai_costo), 0) FROM foto").fetchone()[0]
    if not args.senza_ai:
        ai = AIVision(args.ai_modello, args.ai_tetto, ai_spent_before)
        if not args.senza_secondo_tentativo and args.ai_modello_secondo != args.ai_modello:
            ai2 = AIVision(args.ai_modello_secondo, args.ai_tetto, ai_spent_before, wallet=ai.wallet)
        print(f"AI ({args.ai_modello}) usata solo quando la parte locale non basta: "
              f"spesa finora {money(ai_spent_before)}, tetto {money(args.ai_tetto)}")
    if not args.simula:
        recover_pending_listings(state, api, identity["username"])
    gemini = None
    gemini_key = None if (args.senza_gemini or ai is None) else env_value_or_none("GEMINI_API_KEY")
    if gemini_key:
        gemini = GeminiVision(gemini_key, args.gemini_modello, wallet=ai.wallet)
        print(f"Gemini ({args.gemini_modello}) come seconda opinione sui dischi riconosciuti senza codice")
    google = None
    google_key = None if (args.senza_google or ai is None) else env_value_or_none("GOOGLE_VISION_KEY")
    if args.google_vision and ai is not None and not google_key:
        google_key = load_env_value("GOOGLE_VISION_KEY", "la chiave API di Google Cloud Vision",
                                    "https://console.cloud.google.com/apis/credentials")
    if google_key:
        google = GoogleVision(google_key, wallet=ai.wallet)
        print("Google Vision (ricerca web dell'immagine) attivo come terzo servizio, solo sui dischi non trovati")
    covers = None
    if not args.senza_copertine:
        cm = copertine_module()
        trusted = [r[0] for r in state.execute("SELECT release_id FROM conferme")]
        covers = CoverCheck(cm.CoverStore(api, COVER_DIR), cm.Matcher(), trusted)
        print(f"Confronto delle copertine: {covers.matcher.backend}"
              + (f", {len(trusted)} release già confermate a mano" if trusted else ""))
    # Nomi ripetuti: prima di elaborare qualsiasi foto, ognuna deve essere riconoscibile senza equivoci.
    conflicts = check_photo_identity(state, photos)
    if conflicts:
        state.close()
        con.close()
        raise SystemExit("Mi fermo prima di elaborare: ci sono foto con lo stesso nome ma contenuto diverso, o la "
                         "stessa foto con due nomi.\n  " + "\n  ".join(conflicts)
                         + "\nRinomina le foto nuove (python3 rinomina_foto.py <cartella>) e rilancia.")
    recheck = set()   # foto rielaborate: la vendibilità della loro release va ricontrollata
    if args.rielabora:
        # Prima di tutto: cosa è davvero online. Nessuna riga online (o che lo è stata) si rielabora.
        inventory = sales = None
        try:
            inventory = fetch_inventory(api, identity["username"])
            sales = fetch_sales(api)
        except (InventoryUnreadable, OrdersUnreadable) as e:
            print(f"--rielabora: impossibile leggere l'inventario o gli ordini Discogs ({e}).\n"
                  "  Per sicurezza nessuna riga CSV né annuncio API viene rielaborato: solo le foto mai messe in "
                  "vendita.")
        redo, skipped = prepare_rework(state, photos, Path(args.uscita).expanduser(), inventory, sales)
        recheck = set(redo)
        print(f"--rielabora: {len(redo)} foto verranno rielaborate da capo"
              + (f"; {len(skipped)} saltate perché online su Discogs (o lo sono state, o l'inventario non si legge):"
                 f" {', '.join(skipped)}" if skipped else ""))

    parts = PartAllocator(last_part(state) + 1)   # le righe nuove vanno sempre in file nuovi
    simulated_csv, simulated_listings, simulated_collectors, simulated_rows_info = [], [], [], []
    stats = {"collezionistici": 0, "righe_csv": 0, "copie_csv": 0, "api": 0, "problemi": 0, "gia_fatte": 0,
             "non_vendibili": 0, "non_verificati": 0, "secondo_tentati": 0, "secondo_recuperate": 0,
             "secondo_costo": 0.0, "ric_locale": 0, "ric_ai": 0, "ric_secondo": 0, "ric_copertina": 0, "tolti": 0, "pronti": 0,
             "pubblicati": 0}
    sale_errors = []
    price_calls = 0
    total = len(photos)
    budget_stop = False

    try:
        # 1. Riconoscimento di ogni foto (i risultati restano salvati).
        todo = []
        for n, photo in enumerate(photos, 1):
            eid = photo.external_id
            prefix = f"[{n}/{total}] {photo.name}"
            if is_assigned(state, eid, photo.copies):
                stats["gia_fatte"] += 1
                continue
            row = state.execute("SELECT * FROM foto WHERE external_id = ?", (eid,)).fetchone()
            fingerprint = photo.fingerprint()
            same_photo = row is not None and row["hash"] == photo.sha256  # stesso contenuto, anche se spostata
            cache = {"read": json.loads(row["ai_dati"]) if same_photo and row["ai_dati"] else None,
                     "choice": json.loads(row["ai_scelta"]) if same_photo and row["ai_scelta"] else None,
                     "gemini": json.loads(row["gemini_scelta"]) if same_photo and row["gemini_scelta"] else None}
            # La lettura del secondo tentativo vale solo per lo stesso modello: cambiando modello si rifà
            same2 = same_photo and ai2 is not None and (row["ai2_modello"] or "claude-sonnet-5-5") == ai2.model
            cache2 = {"read": json.loads(row["ai2_dati"]) if same2 and row["ai2_dati"] else None,
                      "choice": json.loads(row["ai2_scelta"]) if same2 and row["ai2_scelta"] else None}
            unsure = row is not None and row["esito"] in ("non_trovato", "multiplo")
            if (not same_photo or row["esito"] in ("errore", "sospeso", "rielabora")
                    or (args.riprova and row["esito"] in PROBLEMS)
                    or (ai and unsure and cache["read"] is None)
                    or (ai2 and unsure and cache2["read"] is None)):
                rec = recognize_safely(photo.images, con, api, use_ocr, ai, cache, args.ai_max_foto, covers, google,
                                       gemini)
                if rec is None:
                    budget_stop = True
                    break
                # Secondo tentativo con un modello più forte, solo se il primo non ha trovato il disco
                rec2, second = None, False
                if ai2 and rec.esito in ("non_trovato", "multiplo"):
                    rec2 = recognize_safely(photo.images, con, api, use_ocr, ai2, {**cache2, "gemini": cache["gemini"]},
                                            args.ai_max_foto, covers, google, gemini)
                    if rec2 is None:  # tetto di spesa: salvo il primo tentativo e mi fermo
                        budget_stop = True
                    else:
                        stats["secondo_tentati"] += 1
                        stats["secondo_costo"] += rec2.ai_cost
                        if rec2.esito not in ("non_trovato", "multiplo", "errore", "sospeso"):
                            second = True
                            stats["secondo_recuperate"] += 1
                            rec2.details += f"; riconosciuto al secondo tentativo ({ai2.model})"
                final = rec2 if second else rec
                if final.esito == "trovato":
                    stats["ric_secondo" if second else "ric_copertina" if final.fonte.startswith("copertina")
                          else "ric_ai" if final.fonte.startswith("ai") else "ric_locale"] += 1
                old_cost = row["ai_costo"] if same_photo and row["ai_costo"] else 0.0
                state.execute(
                    "INSERT OR REPLACE INTO foto (external_id, cartella, foto, impronta, media, sleeve, esito, fonte,"
                    " release_id, candidati, dettagli, aggiornato, ai_dati, ai_costo, ai_scelta, disco, metodo, motivo,"
                    " hash, ai2_dati, ai2_scelta, secondo, n_foto, hash_foto, ai2_modello, gemini_scelta)"
                    " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (eid, photo.folder, str(photo.path), fingerprint, photo.media, photo.sleeve, final.esito,
                     final.fonte, final.release_id, format_candidates(final.candidates), final.details, now(),
                     json.dumps(rec.ai_read) if rec.ai_read is not None else None,
                     old_cost + rec.ai_cost + (rec2.ai_cost if rec2 else 0.0),
                     json.dumps(rec.ai_choice) if rec.ai_choice is not None else None, describe_release(final.release),
                     final.metodo, final.motivo, photo.sha256,
                     json.dumps(rec2.ai_read) if rec2 and rec2.ai_read is not None else
                     (row["ai2_dati"] if same_photo and row else None),
                     json.dumps(rec2.ai_choice) if rec2 and rec2.ai_choice is not None else
                     (row["ai2_scelta"] if same_photo and row else None),
                     ai2.model if second else None, *disc_columns(photo),
                     ai2.model if rec2 is not None else (row["ai2_modello"] if same_photo and row else None),
                     json.dumps(final.gemini) if final.gemini else (row["gemini_scelta"] if same_photo and row else None)),
                )
                rec = final
                state.commit()
                row = state.execute("SELECT * FROM foto WHERE external_id = ?", (eid,)).fetchone()
                if rec.esito == "trovato":
                    how = row["fonte"]
                    if rec.ai_choice and rec.ai_choice.get("confidence"):
                        how += f", sicurezza {CONFIDENCE_IT.get(rec.ai_choice['confidence'], '?')}"
                    print(f"{prefix}: {row['disco']} [release {row['release_id']}, {how}]"
                          + (" - Unofficial Release: probabilmente non vendibile" if is_unofficial(rec.release) else ""))
                elif rec.esito == "da_verificare":
                    print(f"{prefix}: DA VERIFICARE, proposto {row['disco']} [release {row['release_id']},"
                          f" {row['fonte']}]: {rec.motivo}")
                else:
                    print(f"{prefix}: {row['esito']}")
                if rec.esito == "sospeso" or budget_stop:
                    budget_stop = True
                    break
            if row["esito"] in ("trovato", "senza_prezzo", "non_verificato", "stesso_disco"):
                todo.append((photo, row))
            elif row["esito"] == "non_vendibile":
                checked = state.execute("SELECT ottenuto FROM vendibilita WHERE release_id = ?",
                                        (row["release_id"],)).fetchone()
                if checked and not is_stale(checked["ottenuto"], args.cache_vendibilita_giorni):
                    stats["non_vendibili"] += 1  # già controllata: nessuna richiesta a Discogs
                else:
                    todo.append((photo, row))    # controllo scaduto: si richiede a Discogs
            elif row["esito"] == "tolto":
                stats["tolti"] += 1      # tolto a mano con --togli: non si elabora più
            elif row["esito"] != "sospeso":
                stats["problemi"] += 1
                if row["esito"] == "da_verificare" and row["release_id"] and row["prezzo"] is None:
                    todo.append((photo, row))  # solo per calcolare il prezzo da mostrare: non va in vendita

        # Stesso artista e titolo su release diverse (es. LP e CD) nello stesso giro: quasi sempre lo
        # stesso disco fotografato più volte e riconosciuto in due modi. Tutte da controllare, prima
        # di qualsiasi richiesta a Discogs. Il controllo si ripete a ogni lancio.
        for members in same_title_other_release([(p, r) for p, r in todo if r["esito"] != "da_verificare"]):
            releases = sorted({r["release_id"] for _, r in members})
            reason = ("stesso artista e titolo su release diverse (es. LP e CD): "
                      + ", ".join(f"{p.external_id} -> {r['release_id']}" for p, r in members)
                      + "; probabilmente lo stesso disco fotografato più volte")
            for p, _ in members:
                state.execute("UPDATE foto SET esito = 'stesso_disco', motivo = ? WHERE external_id = ?",
                              (reason, p.external_id))
            state.commit()
            stats["problemi"] += len(members)
            flagged = {p.external_id for p, _ in members}
            todo = [(p, r) for p, r in todo if p.external_id not in flagged]
            print(f"{artist_title(members[0][1]['disco'])}: DA CONTROLLARE, stesso artista e titolo su "
                  f"{len(releases)} release diverse ({', '.join(map(str, releases))})")

        # 2. Stessa release e stesso grado = copie dello stesso disco: un unico annuncio.
        groups = {}
        for photo, row in todo:
            groups.setdefault((row["release_id"], photo.media, photo.sleeve), []).append((photo, row))

        def group_label(members):
            copies = sum(p.copies for p, _ in members)
            return (", ".join(p.external_id for p, _ in members),
                    f"release {release_id} {grade_text(media, sleeve)}" + (f" x{copies}" if copies > 1 else ""))

        for (release_id, media, sleeve), members in groups.items():
            names, label = group_label(members)
            # Foto già da verificare: serve solo il prezzo da mostrare in da_controllare.csv
            to_check = [(p, r) for p, r in members if r["esito"] == "da_verificare"]
            members = [(p, r) for p, r in members if r["esito"] != "da_verificare"]

            # Più foto sciolte della stessa release e grado: copie diverse o lo stesso disco fotografato più
            # volte? Non vale per i dischi in sottocartella: lì le foto sono già dello stesso disco.
            singles = [(p, r) for p, r in members if not p.is_disc]
            if len(singles) >= 2 and not args.copie_consecutive:
                close, no_exif, used = same_record_gap([p for p, _ in singles], args.secondi_stesso_disco)
                print(f"{label}: date di scatto usate: {used}")
                if close is not None:
                    reason = (f"probabilmente lo stesso disco fotografato più volte (scatti a {close:.0f} secondi di "
                              "distanza): tieni una sola foto per copia, o usa --copie-consecutive")
                    for p, _ in singles:
                        state.execute("UPDATE foto SET esito = 'stesso_disco', motivo = ? WHERE external_id = ?",
                                      (reason, p.external_id))
                    state.commit()
                    stats["problemi"] += len(singles)
                    print(f"{label} ({', '.join(p.external_id for p, _ in singles)}): DA CONTROLLARE, {reason}")
                    members = [(p, r) for p, r in members if p.is_disc]
                    if not members:
                        continue
                    names, label = group_label(members)
                if no_exif:
                    print(f"Attenzione: {label}: data di scatto mancante (DateTimeOriginal) per {len(no_exif)} foto "
                          f"({', '.join(p.external_id for p in no_exif)}): non posso controllare se sono lo stesso "
                          "disco, le conto come copie diverse")

            # Più sottocartelle (dischi) con la stessa release e lo stesso grado: copie diverse o lo stesso
            # disco fotografato due volte? Non si può sapere dalle foto: si ferma finché non lo dici tu
            # (--copie-diverse), o finché non togli dal lotto la cartella in più.
            discs = [(p, r) for p, r in members if p.is_disc]
            confirmed = {n.strip() for n in (args.copie_diverse or "").split(",") if n.strip()}
            if len(discs) >= 2 and not all(disc_matches(p, confirmed) for p, _ in discs):
                names_d = ", ".join(p.name for p, _ in discs)
                reason = (f"stessa release e grado in {len(discs)} cartelle ({names_d}): se è lo stesso disco "
                          "fotografato più volte togli dal lotto le cartelle in più; se sono copie diverse rilancia "
                          f"con --copie-diverse {','.join(p.path.name for p, _ in discs)}")
                for p, _ in discs:
                    state.execute("UPDATE foto SET esito = 'stesso_disco', motivo = ? WHERE external_id = ?",
                                  (reason, p.external_id))
                state.commit()
                stats["problemi"] += len(discs)
                print(f"{label} ({', '.join(p.external_id for p, _ in discs)}): DA CONTROLLARE, {reason}")
                members = [(p, r) for p, r in members if not p.is_disc]
                if not members:
                    continue
                names, label = group_label(members)

            # La release si può vendere? Una richiesta per release (GET /releases/{id}), poi in cache.
            # Se è bloccata: niente prezzo, niente statistiche, niente annuncio.
            try:
                sellable, release_data, calls = check_sellable(
                    state, api, release_id, refresh=any(p.external_id in recheck for p, _ in members + to_check),
                    max_age_days=args.cache_vendibilita_giorni)
            except SaleCheckFailed as e:
                for p, _ in members:
                    state.execute("UPDATE foto SET esito = 'non_verificato', motivo = ? WHERE external_id = ?",
                                  (str(e), p.external_id))
                state.commit()
                stats["problemi"] += len(members)
                stats["non_verificati"] += len(members)
                sale_errors.append(str(e))
                if members:
                    print(f"{label} ({names}): impossibile verificare se è vendibile ({e}): va in da_controllare.csv")
                continue
            price_calls += calls
            if not sellable:
                for p, _ in members:
                    state.execute("UPDATE foto SET esito = 'non_vendibile', motivo = ? WHERE external_id = ?",
                                  (NOT_SELLABLE_REASON, p.external_id))
                state.commit()
                stats["non_vendibili"] += len(members)
                print(f"{label} ({names}): NON VENDIBILE, {NOT_SELLABLE_REASON} (vedi non_vendibili.csv)")
                continue

            refresh = args.riprova and any(r["esito"] == "senza_prezzo" for _, r in members)
            try:
                sugg, fetched = get_price_suggestions(state, api, release_id, refresh=refresh,
                                                      max_age_days=args.cache_prezzi_giorni)
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
                state.execute("UPDATE foto SET esito = ?, motivo = NULL WHERE external_id = ?",
                              (new_esito, p.external_id))
            state.commit()
            if new_esito == "senza_prezzo" and not members:
                continue
            if new_esito == "senza_prezzo":
                stats["problemi"] += len(members)
                print(f"{label} ({names}): nessun prezzo suggerito per {media}")
                continue
            suggested = float(suggestion["value"])
            currency = suggestion.get("currency", "")

            if account_currency and currency and currency != account_currency:
                print(f"Attenzione: prezzo suggerito in {currency}, ma il tuo account è in {account_currency}")

            # Dati del marketplace (2 richieste per release, poi in cache), nella valuta dell'account
            cdata, collector = None, None
            try:
                cdata, fetched = get_collector_data(state, api, con, release_id, account_currency or currency,
                                                    release=release_data, max_age_days=args.cache_prezzi_giorni)
                price_calls += fetched
                score, reasons = collector_score(cdata, suggested, args.soglia_prezzo)
                if score >= args.soglia_collezionistico:
                    lowest = cdata.get("lowest_price") if cdata.get("lowest_currency") == currency else None
                    collector = (score, reasons, lowest)
            except ApiError as e:
                print(f"{label} ({names}): dati del marketplace non disponibili ({e})")

            competitors = (competition(cdata, my_listed_prices(state, release_id), account_currency or currency)[:2]
                           if cdata else None)
            price, calc = compute_price(suggested, cdata, media, currency, args, competitors)
            info = f"{label} ({names}): {price:.2f} {currency}" + (f" [COLLEZIONISTICO, punteggio {collector[0]}]"
                                                                    if collector else "")

            # Rete di sicurezza: un disco riconosciuto senza codice (AI o artista e titolo)
            # che vale molto non va in vendita senza un controllo a mano.
            risk = ""
            if collector:
                risk = f"disco COLLEZIONISTICO (punteggio {collector[0]}, prezzo {price:.2f} {currency})"
            elif price > args.soglia_controllo:
                risk = f"prezzo {price:.2f} {currency} sopra la soglia di controllo ({args.soglia_controllo:g})"
            blocked = []
            for p, r in members:
                metodo = r["metodo"] or method_of(r["fonte"], None)
                if risk and metodo in UNVERIFIED_METHODS:
                    blocked.append(p)
                    state.execute("UPDATE foto SET esito = 'da_verificare', metodo = ?, motivo = ?, prezzo = ?"
                                  " WHERE external_id = ?",
                                  (metodo, f"riconosciuto con {metodo} (non con barcode o catalogo esatto) e {risk}"
                                   + ("; Gemini concorda" if gemini_agrees(r) else ""), price, p.external_id))
            for p, _ in to_check:
                state.execute("UPDATE foto SET prezzo = ? WHERE external_id = ?", (price, p.external_id))
            state.commit()
            if blocked:
                stats["problemi"] += len(blocked)
                print(f"{info} -> DA VERIFICARE ({', '.join(p.external_id for p in blocked)}): {risk},"
                      " riconosciuto senza codice")
            members = [(p, r) for p, r in members if p not in blocked]
            if not members:
                continue
            if blocked or to_check:
                names, label = group_label(members)
                info = f"{label} ({names}): {price:.2f} {currency}" + (
                    f" [COLLEZIONISTICO, punteggio {collector[0]}]" if collector else "")
            # Trovato in locale -> CSV; ma con --bozza sempre via API, perché Discogs ignora DRAFT nei CSV.
            # Un disco con alcune copie già pubblicate via API (esecuzione interrotta) resta via API.
            started_api = any(state.execute("SELECT 1 FROM annunci_api WHERE external_id = ?",
                                            (p.external_id,)).fetchone() for p, _ in members)
            is_csv = (args.csv and not args.bozza and not started_api
                      and any(is_local_source(r["fonte"]) for _, r in members))
            if collector:
                stats["collezionistici"] += 1
                c_row = [members[0][0].external_id, release_id, media, sum(p.copies for p, _ in members),
                         ", ".join(p.name for p, _ in members), members[0][1]["disco"] or "", collector[0],
                         "; ".join(collector[1]), suggested, collector[2], price, currency,
                         "CSV" if is_csv else "API", calc, sleeve]
                if args.simula:
                    simulated_collectors.append(c_row)
                else:
                    state.execute("INSERT OR REPLACE INTO collezionistici VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", c_row)

            if is_csv:
                # Trovato in locale: una riga nel CSV con quantity = numero di copie (foto sciolte + copie-N).
                row_id = members[0][0].external_id
                quantity = sum(p.copies for p, _ in members)
                photos_text = ", ".join(p.name for p, _ in members)
                if args.simula:
                    simulated_csv.append(csv_row(release_id, price, media, sleeve, quantity, row_id))
                    simulated_rows_info.append([row_id, release_id, quantity, f"{price:.2f}", "FOR_SALE", photos_text,
                                                calc])
                else:
                    state.execute(
                        "INSERT INTO righe_csv (external_id, parte, release_id, price, media, sleeve, quantita, foto,"
                        " calcolo, status) VALUES (?,?,?,?,?,?,?,?,?,?)",
                        (row_id, parts.assign(quantity), release_id, price, media, sleeve, quantity, photos_text, calc,
                         "FOR_SALE"))
                    for p, _ in members:
                        state.execute("UPDATE foto SET riga_csv = ? WHERE external_id = ?", (row_id, p.external_id))
                state.commit()
                stats["righe_csv"] += 1
                stats["copie_csv"] += quantity
                print(f"{info} -> CSV")
                continue

            # Un annuncio per copia (l'API non ha un campo quantità). Senza --bozza e senza --csv resta
            # "pronto": lo si guarda nel pannello e lo si pubblica con --pubblica.
            for p, eid in [(p, eid) for p, _ in members for eid in copy_ids(p.external_id, p.copies)]:
                if state.execute("SELECT 1 FROM annunci_api WHERE external_id = ?", (eid,)).fetchone():
                    continue  # copia già registrata (pronta, o pubblicata in un'esecuzione interrotta)
                if args.simula:
                    simulated_listings.append([eid, release_id, f"{price:.2f}", GRADES[media], GRADES[sleeve],
                                               API_STATUS[status], calc])
                    stats["api"] += 1
                    print(f"{info} -> annuncio API {eid}" + (" in bozza" if args.bozza else "") + " (simulato)")
                    continue
                state.execute(
                    "INSERT INTO annunci_api (external_id, release_id, price, media, sleeve, stato, inviato, calcolo,"
                    " status) VALUES (?,?,?,?,?,'pronto',?,?,?)",
                    (eid, release_id, price, media, sleeve, now(), calc, status))
                state.commit()
                if not (args.bozza or args.csv):
                    stats["pronti"] += 1
                    print(f"{info} -> pronto da pubblicare ({eid})")
                    continue
                send_listing(state, api, state.execute("SELECT * FROM annunci_api WHERE external_id = ?",
                                                       (eid,)).fetchone(), stats, info)
    except KeyboardInterrupt:
        print("\nInterrotto. Rilancia lo stesso comando per riprendere da qui.")
    finally:
        if args.pubblica and not budget_stop:
            try:
                stats["pubblicati"] = publish_pending(state, api, stats)
            except KeyboardInterrupt:
                print("\nInterrotto durante la pubblicazione: rilancia con --pubblica per finire.")
        out_dir = Path(args.uscita).expanduser()
        to_check = write_outputs(state, out_dir, simulated_csv, simulated_listings, simulated_collectors,
                                 simulated_rows_info)
        print()
        print("Riepilogo di questa esecuzione")
        print(f"  dischi elaborati:            {total} (foto totali: {sum(len(p.images) for p in photos)})")
        print(f"  riconosciuti in questa esecuzione: {stats['ric_locale']} al primo colpo (senza AI), "
              f"{stats['ric_ai']} con l'AI, {stats['ric_secondo']} con il secondo tentativo"
              + (f", {stats['ric_copertina']} con la copertina" if stats["ric_copertina"] else ""))
        if gemini is not None and gemini.calls:
            print(f"  Gemini (seconda opinione): {gemini.calls} dischi controllati ({money(gemini.cost)})")
        if google is not None and google.calls:
            print(f"  Google Vision: {google.calls} foto inviate ({money(google.calls * GOOGLE_VISION_COST)})")
        if covers is not None and covers.compared:
            print(f"  confronti con le copertine di Discogs: {covers.compared} (immagini scaricate: {covers.store.calls})")
        print(f"  righe nel CSV di inventario: {stats['righe_csv']} ({stats['copie_csv']} copie)")
        waiting = state.execute("SELECT COUNT(*) FROM annunci_api WHERE stato = 'pronto'").fetchone()[0]
        if stats["pronti"] or waiting:
            print(f"  pronti da pubblicare:        {stats['pronti']} nuovi, {waiting} in attesa in tutto"
                  + ("" if args.pubblica else " (guardali nel pannello, poi: python vendi.py --pubblica)"))
        print(f"  annunci via API{' (simulati)' if args.simula else ''}: {stats['api']}"
              + (f" (di cui {stats['pubblicati']} con --pubblica)" if args.pubblica else ""))
        print(f"  foto da controllare:         {stats['problemi']}")
        print(f"  foto già in vendita:         {stats['gia_fatte']}")
        if stats["tolti"]:
            print(f"  dischi tolti (--togli):      {stats['tolti']}")
        print(f"  dischi non vendibili (bloccati da Discogs): {stats['non_vendibili']} (vedi non_vendibili.csv)")
        print(f"  dischi collezionistici:      {stats['collezionistici']} (vedi collezionistici.csv)")
        print(f"  richieste API: {api.calls} (di cui prezzi e dati collezionistici: {price_calls})")
        if ai2 and stats["secondo_tentati"]:
            print(f"  secondo tentativo ({ai2.model}): {stats['secondo_recuperate']} foto recuperate su "
                  f"{stats['secondo_tentati']}, costo {money(stats['secondo_costo'])}")
        if ai:
            print(f"  spesa AI: {money(ai.spent - ai_spent_before)} in questa esecuzione, {money(ai.spent)} in totale"
                  f" (tetto {money(args.ai_tetto)})")
        if stats["non_verificati"]:
            print(f"\nATTENZIONE: per {stats['non_verificati']} foto non è stato possibile verificare se la release è"
                  f" vendibile\n(ultimo errore: {sale_errors[-1]}).\nSono in da_controllare.csv e verranno ricontrollate"
                  " al prossimo lancio.")
        if budget_stop:
            print(f"\nTETTO DI SPESA AI RAGGIUNTO ({money(args.ai_tetto)}): lo script si è fermato qui.\n"
                  "Le foto già riconosciute sono state messe in vendita normalmente. Per continuare con le altre,\n"
                  "rilancia lo stesso comando con un tetto più alto, es. --ai-tetto 80.")
        print(f"Risultati in {out_dir}/  (righe in da_controllare.csv: {to_check})")
        if args.simula:
            print(f"Simulazione in {out_dir / 'simulazione'}/")
        state.close()
        con.close()
        if not args.senza_pannello and not args.simula:
            open_panel(out_dir)


if __name__ == "__main__":
    main()
