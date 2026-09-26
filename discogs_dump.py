#!/usr/bin/env python3
"""
Scarica l'ultimo dump mensile delle release di Discogs e lo importa in un
database SQLite locale, con indice sul barcode.

Si può rilanciare ogni mese: se il dump più recente è già stato importato
non fa nulla; altrimenti ricostruisce il database da zero e lo sostituisce
solo a importazione completata (il database vecchio resta usabile fino alla fine).

Usa solo la libreria standard di Python (3.8+).

Esempi:
    python3 discogs_dump.py aggiorna
    python3 discogs_dump.py aggiorna --file ~/Downloads/discogs_20260901_releases.xml.gz
    python3 discogs_dump.py cerca 5099902987125
    python3 discogs_dump.py info
"""

import argparse
import datetime as dt
import gzip
import hashlib
import os
import re
import sqlite3
import sys
import time
import unicodedata
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
DEFAULT_DB = DATA_DIR / "discogs.sqlite"
DOWNLOAD_DIR = DATA_DIR / "downloads"

USER_AGENT = "DiscogsDumpImporter/1.0 (+https://github.com/Matteocosta1/Discogs)"

# Pagine da cui si prova a scoprire l'ultimo dump disponibile, in ordine.
INDEX_URLS = [
    "https://data.discogs.com/?prefix=data/{year}/",
    "https://discogs-data-dumps.s3-us-west-2.amazonaws.com/?prefix=data/{year}/",
]
# URL da cui si prova a scaricare un file del dump, in ordine.
FILE_URLS = [
    "https://discogs-data-dumps.s3-us-west-2.amazonaws.com/data/{year}/{name}",
    "https://discogs-data-dumps.s3.us-west-2.amazonaws.com/data/{year}/{name}",
]

RELEASES_RE = re.compile(r"discogs_(\d{8})_releases\.xml\.gz")
BATCH_SIZE = 5000
# Aumentare quando cambia lo schema: un database più vecchio viene reimportato.
SCHEMA_VERSION = 3


# --------------------------------------------------------------------------
# Rete
# --------------------------------------------------------------------------

def http_get(url, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    return urllib.request.urlopen(req, timeout=timeout)


def find_latest_dump():
    """Restituisce (data 'YYYYMMDD', lista di URL candidati) dell'ultimo dump."""
    today = dt.date.today()
    found = {}  # data -> URL assoluti trovati nella pagina
    errors = []
    for year in (today.year, today.year - 1):
        for tpl in INDEX_URLS:
            url = tpl.format(year=year)
            try:
                with http_get(url) as resp:
                    html = resp.read().decode("utf-8", "replace")
            except (urllib.error.URLError, OSError) as e:
                errors.append(f"{url}: {e}")
                continue
            for m in RELEASES_RE.finditer(html):
                found.setdefault(m.group(1), [])
            # Link assoluti presenti nella pagina (se ci sono, hanno la precedenza).
            for m in re.finditer(r'https?://[^"\'<>\s]*discogs_(\d{8})_releases\.xml\.gz', html):
                found.setdefault(m.group(1), []).append(m.group(0).replace("&amp;", "&"))
        if found:
            break
    if not found:
        msg = "\n  ".join(errors) or "nessun dump trovato nelle pagine indice"
        raise SystemExit(
            "Impossibile trovare l'ultimo dump di Discogs.\n  " + msg +
            "\nScaricalo a mano da https://data.discogs.com/ e usa:\n"
            "  python3 discogs_dump.py aggiorna --file PERCORSO/discogs_AAAAMMGG_releases.xml.gz"
        )
    date = max(found)
    name = f"discogs_{date}_releases.xml.gz"
    urls = found[date] + [tpl.format(year=date[:4], name=name) for tpl in FILE_URLS]
    return date, list(dict.fromkeys(urls))


def fetch_checksums(date):
    """Scarica CHECKSUM.txt del dump e restituisce {nome_file: sha256}, o {} se non disponibile."""
    name = f"discogs_{date}_CHECKSUM.txt"
    for tpl in FILE_URLS:
        try:
            with http_get(tpl.format(year=date[:4], name=name)) as resp:
                text = resp.read().decode("utf-8", "replace")
        except (urllib.error.URLError, OSError):
            continue
        sums = {}
        for line in text.splitlines():
            parts = line.split()
            if len(parts) == 2:
                sums[parts[1].lstrip("*")] = parts[0].lower()
        return sums
    return {}


def download(urls, dest):
    """Scarica il primo URL funzionante in dest, riprendendo un download interrotto."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        print(f"File già scaricato: {dest}")
        return
    part = dest.with_name(dest.name + ".part")
    last_error = None
    for url in urls:
        offset = part.stat().st_size if part.exists() else 0
        headers = {"User-Agent": USER_AGENT}
        if offset:
            headers["Range"] = f"bytes={offset}-"
        try:
            resp = urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60)
        except (urllib.error.URLError, OSError) as e:
            last_error = f"{url}: {e}"
            continue
        with resp:
            if offset and resp.status != 206:  # il server non supporta la ripresa
                offset = 0
            total = resp.headers.get("Content-Length")
            total = int(total) + offset if total else None
            print(f"Scarico {url}")
            done = offset
            t0 = time.time()
            with open(part, "ab" if offset else "wb") as f:
                while True:
                    chunk = resp.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
                    done += len(chunk)
                    if time.time() - t0 > 1:
                        t0 = time.time()
                        pct = f" ({done * 100 / total:.1f}%)" if total else ""
                        print(f"\r  {done / 1e9:.2f} GB{pct}", end="", flush=True)
            print()
        if total and part.stat().st_size < total:
            raise SystemExit("Download incompleto: rilancia lo stesso comando per riprenderlo.")
        part.rename(dest)
        return
    raise SystemExit(
        f"Download non riuscito ({last_error}).\n"
        "Scarica il file a mano da https://data.discogs.com/ e usa l'opzione --file."
    )


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# --------------------------------------------------------------------------
# Database
# --------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value TEXT
);
CREATE TABLE releases (
    id           INTEGER PRIMARY KEY,
    title        TEXT,
    artists      TEXT,     -- nomi degli artisti, come appaiono sulla release
    labels       TEXT,     -- "Etichetta (catno)", separati da "; "
    catno        TEXT,     -- primo numero di catalogo
    formats      TEXT,     -- es. "Vinyl, LP, Album; CD"
    country      TEXT,
    released     TEXT,     -- data così come su Discogs (es. "1977-03-00")
    year         INTEGER,
    genres       TEXT,
    styles       TEXT,
    master_id    INTEGER,
    status       TEXT,
    data_quality TEXT
);
CREATE TABLE catnos (
    release_id INTEGER NOT NULL,
    label      TEXT,              -- nome dell'etichetta
    catno      TEXT NOT NULL,     -- valore originale
    catno_norm TEXT NOT NULL      -- solo cifre/lettere, maiuscole (per la ricerca)
);
CREATE TABLE barcodes (
    release_id   INTEGER NOT NULL,
    barcode      TEXT NOT NULL,   -- valore originale
    barcode_norm TEXT NOT NULL,   -- solo cifre/lettere, maiuscole (per la ricerca)
    description  TEXT
);
"""

INDEXES = """
CREATE INDEX idx_barcodes_norm    ON barcodes(barcode_norm);
CREATE INDEX idx_barcodes_release ON barcodes(release_id);
CREATE INDEX idx_releases_master  ON releases(master_id);
CREATE INDEX idx_catnos_norm      ON catnos(catno_norm);
"""


# Indice di ricerca testuale su artista e titolo (SQLite FTS5), con il testo già
# normalizzato da normalize_text. releases_vocab elenca le parole presenti e in
# quante release compaiono.
FTS_SCHEMA = """
CREATE VIRTUAL TABLE releases_fts USING fts5(artists, title, content='', tokenize='unicode61 remove_diacritics 2');
CREATE VIRTUAL TABLE releases_vocab USING fts5vocab(releases_fts, 'row');
"""


def normalize_barcode(value):
    return re.sub(r"[^0-9A-Za-z]", "", value or "").upper()


def normalize_text(value):
    """Testo per la ricerca di artista e titolo: minuscole, senza accenti né punteggiatura."""
    value = unicodedata.normalize("NFKD", value or "")
    value = "".join(c for c in value if not unicodedata.combining(c)).lower()
    return " ".join(re.sub(r"[^a-z0-9]+", " ", value).split())


def normalize_catno(value):
    return re.sub(r"[^0-9A-Za-z]", "", value or "").upper()


def text_of(elem, tag):
    child = elem.find(tag)
    return (child.text or "").strip() if child is not None and child.text else ""


def parse_release(el):
    rid = int(el.get("id"))
    artist_els = el.findall("artists/artist")
    artists_str = ""
    for i, a in enumerate(artist_els):
        name = text_of(a, "anv") or text_of(a, "name")
        artists_str += re.sub(r" \(\d+\)$", "", name)  # "Nome (2)" -> "Nome"
        if i < len(artist_els) - 1:
            join = text_of(a, "join")
            artists_str += ", " if join in ("", ",") else f" {join} "

    labels = el.findall("labels/label")
    labels_str = "; ".join(
        f"{l.get('name', '')} ({l.get('catno', '')})" if l.get("catno") else l.get("name", "")
        for l in labels
    )
    catno = labels[0].get("catno", "") if labels else ""

    formats = []
    for f in el.findall("formats/format"):
        bits = [f.get("name", "")]
        bits += [d.text for d in f.findall("descriptions/description") if d.text]
        if f.get("text"):
            bits.append(f.get("text"))
        qty = f.get("qty")
        formats.append((f"{qty} x " if qty and qty != "1" else "") + ", ".join(b for b in bits if b))

    released = text_of(el, "released")
    year = int(released[:4]) if released[:4].isdigit() and released[:4] != "0000" else None
    master = el.find("master_id")
    master_id = int(master.text) if master is not None and (master.text or "").strip().isdigit() else None

    release_row = (
        rid,
        text_of(el, "title"),
        artists_str,
        labels_str,
        catno,
        "; ".join(formats),
        text_of(el, "country"),
        released,
        year,
        ", ".join(g.text for g in el.findall("genres/genre") if g.text),
        ", ".join(s.text for s in el.findall("styles/style") if s.text),
        master_id,
        el.get("status", ""),
        text_of(el, "data_quality"),
    )
    catno_rows = []
    seen = set()
    for l in labels:
        norm = normalize_catno(l.get("catno"))
        if norm and norm != "NONE" and (norm, l.get("name")) not in seen:
            seen.add((norm, l.get("name")))
            catno_rows.append((rid, l.get("name", ""), l.get("catno", ""), norm))

    barcode_rows = []
    for ident in el.findall("identifiers/identifier"):
        if ident.get("type") == "Barcode" and ident.get("value"):
            value = ident.get("value").strip()
            norm = normalize_barcode(value)
            if norm:
                barcode_rows.append((rid, value, norm, ident.get("description", "")))
    return release_row, barcode_rows, catno_rows


def build_database(dump_path, db_path, dump_date):
    """Importa il dump in un database nuovo e lo sostituisce a quello esistente."""
    db_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = db_path.with_name(db_path.name + ".new")
    for p in (tmp_path, Path(str(tmp_path) + "-journal")):
        if p.exists():
            p.unlink()

    con = sqlite3.connect(tmp_path)
    con.executescript("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA cache_size=-200000;")
    con.executescript(SCHEMA)

    releases, barcodes, catnos = [], [], []
    count = 0
    t0 = time.time()
    print(f"Importo {dump_path.name} (può richiedere qualche ora)...")

    def flush():
        con.executemany("INSERT OR REPLACE INTO releases VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", releases)
        con.executemany("INSERT INTO barcodes VALUES (?,?,?,?)", barcodes)
        con.executemany("INSERT INTO catnos VALUES (?,?,?,?)", catnos)
        con.commit()
        releases.clear()
        barcodes.clear()
        catnos.clear()

    with gzip.open(dump_path, "rb") as f:
        context = ET.iterparse(f, events=("start", "end"))
        _, root = next(context)
        depth = 1
        for event, el in context:
            if event == "start":
                depth += 1
                continue
            depth -= 1
            if depth != 1 or el.tag != "release":
                continue
            try:
                rel, bcs, cats = parse_release(el)
            except (TypeError, ValueError) as e:
                print(f"\n  release saltata (id={el.get('id')}): {e}")
            else:
                releases.append(rel)
                barcodes.extend(bcs)
                catnos.extend(cats)
                count += 1
            root.clear()  # libera la memoria delle release già lette
            if len(releases) >= BATCH_SIZE:
                flush()
                rate = count / max(time.time() - t0, 1e-6)
                print(f"\r  {count:,} release importate ({rate:,.0f}/s)", end="", flush=True)
    flush()
    print(f"\r  {count:,} release importate.            ")

    print("Creo gli indici...")
    con.executescript(INDEXES)
    print("Creo l'indice di ricerca per artista e titolo (può richiedere un po')...")
    con.create_function("norm_text", 1, normalize_text, deterministic=True)
    con.executescript(FTS_SCHEMA)
    con.execute("INSERT INTO releases_fts (rowid, artists, title) "
                "SELECT id, norm_text(artists), norm_text(title) FROM releases")
    con.execute("INSERT INTO releases_fts (releases_fts) VALUES ('optimize')")
    con.commit()
    con.executemany(
        "INSERT INTO meta VALUES (?, ?)",
        [
            ("dump_date", dump_date),
            ("schema_version", str(SCHEMA_VERSION)),
            ("dump_file", dump_path.name),
            ("release_count", str(count)),
            ("imported_at", dt.datetime.now().isoformat(timespec="seconds")),
        ],
    )
    con.commit()
    con.execute("ANALYZE")
    con.close()

    os.replace(tmp_path, db_path)
    print(f"Database pronto: {db_path}")


def read_meta(db_path):
    if not db_path.exists():
        return {}
    try:
        with sqlite3.connect(db_path) as con:
            return dict(con.execute("SELECT key, value FROM meta"))
    except sqlite3.Error:
        return {}


def current_dump_date(db_path):
    """Data del dump nel database, o None se manca o ha uno schema vecchio."""
    meta = read_meta(db_path)
    if int(meta.get("schema_version", 1)) < SCHEMA_VERSION:
        return None
    return meta.get("dump_date")


# --------------------------------------------------------------------------
# Ricerca (usata anche da vendi.py)
# --------------------------------------------------------------------------

def open_db(db_path=DEFAULT_DB):
    """Apre il database in sola lettura, controllando che sia aggiornato allo schema attuale."""
    db_path = Path(db_path).expanduser()
    if not db_path.exists():
        raise SystemExit(f"Database non trovato: {db_path}\nLancia prima: python3 discogs_dump.py aggiorna")
    if int(read_meta(db_path).get("schema_version", 1)) < SCHEMA_VERSION:
        raise SystemExit(
            "Il database è in un formato vecchio (mancano gli indici per catalogo o per artista e titolo).\n"
            "Aggiornalo con: python3 discogs_dump.py aggiorna"
        )
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def barcode_variants(barcode):
    """Varianti equivalenti di un barcode: UPC-A a 12 cifre ed EAN-13 con lo 0 davanti."""
    norm = normalize_barcode(barcode)
    variants = {norm}
    if norm.isdigit() and len(norm) == 12:
        variants.add("0" + norm)
    if norm.isdigit() and len(norm) == 13 and norm.startswith("0"):
        variants.add(norm[1:])
    return sorted(v for v in variants if v)


_RELEASE_COLS = "r.id, r.artists, r.title, r.labels, r.catno, r.formats, r.country, r.released"


def search_by_barcode(con, barcode):
    """Release con quel barcode: lista di dict (vuota se nessuna)."""
    variants = barcode_variants(barcode)
    if not variants:
        return []
    marks = ",".join("?" * len(variants))
    rows = con.execute(
        f"""SELECT DISTINCT {_RELEASE_COLS} FROM barcodes b JOIN releases r ON r.id = b.release_id
            WHERE b.barcode_norm IN ({marks}) ORDER BY r.id""",
        variants,
    ).fetchall()
    return [dict(r) for r in rows]


def search_by_catno(con, catno):
    """Release con quel numero di catalogo: lista di dict con in più 'catno_label'
    (l'etichetta associata a quel catno)."""
    norm = normalize_catno(catno)
    if not norm:
        return []
    rows = con.execute(
        f"""SELECT {_RELEASE_COLS}, c.label AS catno_label
            FROM catnos c JOIN releases r ON r.id = c.release_id
            WHERE c.catno_norm = ? ORDER BY r.id""",
        (norm,),
    ).fetchall()
    return [dict(r) for r in rows]


def _fts_group(words):
    return "(" + " ".join('"' + w.replace('"', "") + '"' for w in words) + ")"


def search_by_words(con, artist_words=(), title_words=(), any_words=(), limit=500):
    """Release che contengono tutte le parole indicate (già normalizzate):
    artist_words nell'artista, title_words nel titolo, any_words in uno dei due.
    Restituisce (lista di id, troncata) dove troncata è True se i risultati erano più di limit."""
    parts = []
    if artist_words:
        parts.append("artists : " + _fts_group(artist_words))
    if title_words:
        parts.append("title : " + _fts_group(title_words))
    if any_words:
        parts.append(_fts_group(any_words))
    if not parts:
        return [], False
    rows = con.execute("SELECT rowid FROM releases_fts WHERE releases_fts MATCH ? LIMIT ?",
                       (" AND ".join(parts), limit + 1)).fetchall()
    return [r[0] for r in rows[:limit]], len(rows) > limit


def word_frequency(con, word):
    """In quante release compare la parola (0 se non esiste nel database)."""
    row = con.execute("SELECT doc FROM releases_vocab WHERE term = ?", (word,)).fetchone()
    return row[0] if row else 0


def get_releases(con, ids):
    """Dettagli delle release indicate, con le etichette e i numeri di catalogo di ognuna."""
    ids = list(dict.fromkeys(ids))
    out = {}
    for i in range(0, len(ids), 500):
        chunk = ids[i:i + 500]
        marks = ",".join("?" * len(chunk))
        for r in con.execute(f"SELECT {_RELEASE_COLS}, r.year, r.master_id FROM releases r WHERE r.id IN ({marks})",
                             chunk):
            out[r["id"]] = {**dict(r), "label_names": [], "catno_norms": []}
        for c in con.execute(f"SELECT release_id, label, catno_norm FROM catnos WHERE release_id IN ({marks})", chunk):
            d = out.get(c["release_id"])
            if d is not None:
                if c["label"] and c["label"] not in d["label_names"]:
                    d["label_names"].append(c["label"])
                d["catno_norms"].append(c["catno_norm"])
    return [out[i] for i in ids if i in out]


# --------------------------------------------------------------------------
# Comandi
# --------------------------------------------------------------------------

def cmd_aggiorna(args):
    db_path = Path(args.db).expanduser()
    if args.file:
        dump_path = Path(args.file).expanduser().resolve()
        m = RELEASES_RE.search(dump_path.name)
        if not dump_path.exists():
            raise SystemExit(f"File non trovato: {dump_path}")
        if not m:
            raise SystemExit("Il nome del file deve essere del tipo discogs_AAAAMMGG_releases.xml.gz")
        date = m.group(1)
    else:
        print("Cerco l'ultimo dump disponibile...")
        date, urls = find_latest_dump()
        print(f"Ultimo dump: {date}")
        dump_path = DOWNLOAD_DIR / f"discogs_{date}_releases.xml.gz"

    installed = current_dump_date(db_path)
    if installed == date and not args.force:
        print(f"Il database è già aggiornato al dump {date}. Niente da fare (usa --force per reimportare).")
        return

    if not args.file:
        download(urls, dump_path)
        sums = fetch_checksums(date)
        expected = sums.get(dump_path.name)
        if expected:
            print("Verifico il checksum...")
            if sha256_of(dump_path) != expected:
                dump_path.unlink()
                raise SystemExit("Checksum errato: file cancellato, rilancia il comando per riscaricarlo.")
            print("  OK")

    build_database(dump_path, db_path, date)

    if not args.file and not args.keep_dump:
        dump_path.unlink()
        print(f"Cancellato il file scaricato {dump_path.name} (usa --keep-dump per tenerlo).")


def cmd_cerca(args):
    db_path = Path(args.db).expanduser()
    if not db_path.exists():
        raise SystemExit("Database non trovato: lancia prima 'python3 discogs_dump.py aggiorna'.")
    con = open_db(db_path)
    if args.catno:
        rows, kind = search_by_catno(con, args.valore), "numero di catalogo"
    elif args.testo:
        ids, _ = search_by_words(con, any_words=normalize_text(args.valore).split(), limit=50)
        rows, kind = get_releases(con, ids), "artista/titolo"
    else:
        rows, kind = search_by_barcode(con, args.valore), "barcode"
    con.close()
    if not rows:
        print(f"Nessuna release con {kind} {args.valore}")
        return
    seen = set()
    for r in rows:
        if r["id"] in seen:
            continue
        seen.add(r["id"])
        print(f"{r['artists']} - {r['title']}")
        print(f"  {r['labels']} | {r['formats']} | {r['country']} {r['released']}")
        print(f"  https://www.discogs.com/release/{r['id']}")


def cmd_info(args):
    db_path = Path(args.db).expanduser()
    if not db_path.exists():
        print("Nessun database ancora.")
        return
    with sqlite3.connect(db_path) as con:
        for key, value in con.execute("SELECT key, value FROM meta ORDER BY key"):
            print(f"{key}: {value}")
    print(f"dimensione: {db_path.stat().st_size / 1e9:.2f} GB")


def main():
    parser = argparse.ArgumentParser(description="Dump mensile delle release di Discogs -> SQLite")
    parser.add_argument("--db", default=str(DEFAULT_DB), help=f"percorso del database (default: {DEFAULT_DB})")
    sub = parser.add_subparsers(dest="comando", required=True)

    p = sub.add_parser("aggiorna", help="scarica l'ultimo dump e aggiorna il database")
    p.add_argument("--file", help="usa un dump già scaricato invece di scaricarlo")
    p.add_argument("--force", action="store_true", help="reimporta anche se il database è già aggiornato")
    p.add_argument("--keep-dump", action="store_true", help="non cancellare il file scaricato dopo l'importazione")
    p.set_defaults(func=cmd_aggiorna)

    p = sub.add_parser("cerca", help="cerca le release per barcode, numero di catalogo (--catno) o artista/titolo (--testo)")
    p.add_argument("valore", help="barcode, numero di catalogo con --catno, parole di artista e titolo con --testo")
    p.add_argument("--catno", action="store_true", help="cerca per numero di catalogo invece che per barcode")
    p.add_argument("--testo", action="store_true", help="cerca per parole di artista e titolo (es. \"pink floyd wall\")")
    p.set_defaults(func=cmd_cerca)

    p = sub.add_parser("info", help="mostra quale dump è nel database")
    p.set_defaults(func=cmd_info)

    args = parser.parse_args()
    try:
        args.func(args)
    except KeyboardInterrupt:
        sys.exit("\nInterrotto. Rilancia lo stesso comando per riprendere.")


if __name__ == "__main__":
    main()
