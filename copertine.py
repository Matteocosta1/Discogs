"""
Confronto visivo con le copertine di Discogs: quando il testo lascia più release possibili, le loro
immagini (scaricate una volta sola in data/copertine/) vengono confrontate con le foto del disco.

- Su macOS usa Vision (VNGenerateImageFeaturePrintRequest, lo stesso motore delle "foto simili"
  di Foto), gratis e in locale; altrove, o se Vision non è disponibile, un confronto più semplice
  con Pillow (impronta della forma + colori).
- Il confronto dice se la copertina è la stessa, non quale STAMPA è: stampe diverse hanno spesso
  la stessa copertina. Serve a scegliere il titolo giusto e a confermare un riconoscimento senza
  codice; la stampa la decidono catalogo, paese e anno.

Risultato di un confronto: distanza (0 = identica). Soglie per metodo in STRONG (copertina
riconosciuta) e GAP (distacco minimo dal secondo candidato perché la scelta sia univoca).
"""

import json
import sys
from pathlib import Path

MAX_IMAGES = 4            # immagini per release scaricate da Discogs (prima la principale, poi retro/etichette)
MAX_CANDIDATES = 6        # candidati confrontati per disco (richieste API: 1 + immagini per candidato)
STRONG = {"vision": 0.55, "pil": 0.35}   # sotto: stessa copertina
GAP = {"vision": 0.15, "pil": 0.12}      # distacco dal secondo candidato per una scelta univoca
DOUBT = {"vision": 0.15, "pil": 0.12}    # oltre STRONG + DOUBT: copertina sicuramente diversa


class CoverStore:
    """Immagini delle release in cache: data/copertine/<id>-<n>.jpg + <id>.json (anche vuoto, per non
    richiedere due volte una release senza immagini)."""

    def __init__(self, api, folder):
        self.api = api
        self.folder = Path(folder)
        self.calls = 0

    def paths(self, release_id, release=None):
        """File locali delle immagini di una release (scaricandole se servono). release: risposta di
        GET /releases/{id} già in mano, per non rifare la richiesta."""
        index = self.folder / f"{release_id}.json"
        if index.exists():
            try:
                files = [self.folder / name for name in json.loads(index.read_text())]
                return [f for f in files if f.exists()]
            except ValueError:
                pass
        if release is None:
            release = self.api.release(release_id)
            self.calls += 1
        images = sorted(release.get("images") or [], key=lambda i: 0 if i.get("type") == "primary" else 1)
        files = []
        self.folder.mkdir(parents=True, exist_ok=True)
        for n, img in enumerate(images[:MAX_IMAGES]):
            url = img.get("uri") or img.get("uri150")
            if not url:
                continue
            target = self.folder / f"{release_id}-{n}.jpg"
            if not target.exists():
                data = self.api.download(url)
                self.calls += 1
                if not data:
                    continue
                target.write_bytes(data)
            files.append(target)
        index.write_text(json.dumps([f.name for f in files]))
        return files


class Matcher:
    """Impronte visive e distanze. backend: 'vision' (macOS) o 'pil'."""

    def __init__(self, backend=None):
        self.backend = backend or ("vision" if sys.platform == "darwin" and _vision_available() else "pil")
        self._cache = {}

    def feature(self, path):
        key = str(path)
        if key not in self._cache:
            try:
                self._cache[key] = _vision_feature(path) if self.backend == "vision" else _pil_feature(path)
            except Exception:
                self._cache[key] = None
        return self._cache[key]

    def distance(self, a, b):
        """Distanza tra due immagini, o None se non si può calcolare (mai un errore: il confronto delle
        copertine è un aiuto, non deve mai fermare il riconoscimento)."""
        fa, fb = self.feature(a), self.feature(b)
        if fa is None or fb is None:
            return None
        try:
            return _vision_distance(fa, fb) if self.backend == "vision" else _pil_distance(fa, fb)
        except Exception:
            return None

    def compare(self, photos, covers_by_id):
        """{release_id: distanza minima tra le foto del disco e le immagini della release} (solo le
        release con almeno un confronto riuscito)."""
        out = {}
        for rid, covers in covers_by_id.items():
            best = None
            for photo in photos:
                for cover in covers:
                    d = self.distance(photo, cover)
                    if d is not None and (best is None or d < best):
                        best = d
            if best is not None:
                out[rid] = best
        return out

    def strong(self, d):
        return d is not None and d <= STRONG[self.backend]

    def verdict(self, distances):
        """(release scelta o None, testo): la scelta c'è solo se un candidato ha la copertina
        riconosciuta e stacca gli altri di almeno GAP."""
        if not distances:
            return None, "copertine: nessun confronto possibile"
        ranked = sorted(distances.items(), key=lambda x: x[1])
        text = "copertine (" + self.backend + "): " + ", ".join(f"{rid} {d:.2f}" for rid, d in ranked)
        best_id, best = ranked[0]
        if not self.strong(best):
            return None, text + "; nessuna copertina riconosciuta"
        if len(ranked) > 1 and ranked[1][1] - best < GAP[self.backend]:
            return None, text + "; copertine troppo simili tra loro"
        return best_id, text + f"; copertina riconosciuta: release {best_id}"


# --------------------------------------------------------------------------
# Backend Vision (macOS)
# --------------------------------------------------------------------------

def _vision_available():
    try:
        import Foundation  # noqa: F401
        import Vision  # noqa: F401
        return True
    except ImportError:
        return False


def _vision_feature(path):
    """Impronta Vision della foto come vettore normalizzato (lunghezza 1): la distanza si calcola qui,
    senza passare dal metodo computeDistance di Vision (con pyobjc il valore di uscita non arriva)."""
    import Foundation
    import Vision
    url = Foundation.NSURL.fileURLWithPath_(str(path))
    handler = Vision.VNImageRequestHandler.alloc().initWithURL_options_(url, None)
    request = Vision.VNGenerateImageFeaturePrintRequest.alloc().init()
    ok, error = handler.performRequests_error_([request], None)
    if not ok:
        raise RuntimeError(f"Vision: {error}")
    results = request.results()
    if not results:
        raise RuntimeError("Vision: nessuna impronta")
    obs = results[0]
    raw = bytes(obs.data())
    count = int(obs.elementCount())
    fmt = "d" if int(obs.elementType()) == 2 else "f"   # 1 = float, 2 = double
    import struct
    vec = struct.unpack(f"<{count}{fmt}", raw[:count * struct.calcsize(fmt)])
    norm = sum(v * v for v in vec) ** 0.5 or 1.0
    return [v / norm for v in vec]


def _vision_distance(a, b):
    """Distanza euclidea tra due impronte normalizzate: 0 = identiche, circa 1,4 = del tutto diverse."""
    return sum((x - y) ** 2 for x, y in zip(a, b)) ** 0.5


# --------------------------------------------------------------------------
# Backend Pillow: impronta della forma (dHash 16x16) + istogramma dei colori
# --------------------------------------------------------------------------

def _open(path):
    from PIL import Image, ImageOps
    try:
        import pillow_heif
        pillow_heif.register_heif_opener()
    except ImportError:
        pass
    with Image.open(path) as img:
        img.draft("RGB", (512, 512))
        return ImageOps.exif_transpose(img).convert("RGB")


def _auto_crop(img):
    """Ritaglia il disco dallo sfondo: colore di fondo stimato dai bordi, riquadro di ciò che ne
    differisce. Le copertine di Discogs sono già ritagliate; le foto hanno il tavolo intorno."""
    from PIL import Image, ImageChops
    w, h = img.size
    small = img.resize((200, int(200 * h / w) or 1))
    sw, sh = small.size
    border = [small.getpixel((x, y)) for x in range(sw) for y in (0, sh - 1)] + \
             [small.getpixel((x, y)) for y in range(sh) for x in (0, sw - 1)]
    bg = tuple(sorted(c[i] for c in border)[len(border) // 2] for i in range(3))
    diff = ImageChops.difference(small, Image.new("RGB", small.size, bg)).convert("L")
    mask = diff.point(lambda v: 255 if v > 40 else 0)
    box = mask.getbbox()
    if not box:
        return img
    x0, y0, x1, y1 = box
    if (x1 - x0) * (y1 - y0) < 0.2 * sw * sh:   # troppo piccolo: non è il disco
        return img
    sx, sy = w / sw, h / sh
    return img.crop((int(x0 * sx), int(y0 * sy), int(x1 * sx), int(y1 * sy)))


def _pil_feature(path):
    img = _auto_crop(_open(path))
    w, h = img.size
    img = img.crop((int(w * 0.04), int(h * 0.04), int(w * 0.96), int(h * 0.96)))
    g = img.convert("L").resize((17, 16))
    px = list(g.getdata())
    bits = []
    for y in range(16):
        row = px[y * 17:(y + 1) * 17]
        bits += [row[x] < row[x + 1] for x in range(16)]
    small = img.resize((32, 32))
    hist = [0] * 64
    for r, g_, b in small.getdata():
        hist[(r // 64) * 16 + (g_ // 64) * 4 + (b // 64)] += 1
    total = float(sum(hist)) or 1.0
    return bits, [h_ / total for h_ in hist]


def _pil_distance(a, b):
    bits_a, hist_a = a
    bits_b, hist_b = b
    hamming = sum(x != y for x, y in zip(bits_a, bits_b)) / len(bits_a)
    overlap = sum(min(x, y) for x, y in zip(hist_a, hist_b))
    return 0.6 * hamming + 0.4 * (1 - overlap)
