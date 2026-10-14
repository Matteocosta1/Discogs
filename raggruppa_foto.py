#!/usr/bin/env python3
"""
Raggruppa le foto sciolte in sottocartelle, una per disco, pronte per vendi.py.

    ~/Desktop/scatti/{IMG_2101.HEIC, IMG_2102.HEIC, ...}
      ->  ~/Desktop/lotto-02/VG+/disco-001/{IMG_2101.HEIC, IMG_2102.HEIC, IMG_2103.HEIC}
          ~/Desktop/lotto-02/VG+/disco-002/...

  1. legge la data di scatto di ogni foto: SOLO il tag EXIF DateTimeOriginal (anche dalle HEIC
     dell'iPhone); se una foto non ce l'ha si ferma e lo dice, senza inventare (niente date di
     modifica: con AirDrop o WhatsApp sono uguali per tutte le foto);
  2. ordina le foto per data di scatto; un nuovo disco inizia quando tra due scatti consecutivi
     passano più di --pausa secondi (default 20);
  3. mostra l'anteprima (disco-001: 3 foto, 12:04:10-12:04:31; ...) e i gruppi sospetti: più di 4
     foto (forse due dischi) o 1 sola foto (forse manca il retro);
  4. --grado è un grado (VG+) o DISCO_COPERTINA (M_NM: disco M, copertina NM);
     dopo conferma SPOSTA (non copia) le foto in <destinazione>/<grado>/disco-NNN; la numerazione
     continua dopo le sottocartelle disco-NNN già presenti. Con --simula mostra solo l'anteprima.

Esempio:
    python3 raggruppa_foto.py ~/Desktop/scatti --grado VG+ --destinazione ~/Desktop/lotto-02 --simula
    python3 raggruppa_foto.py ~/Desktop/scatti --grado VG+ --destinazione ~/Desktop/lotto-02
"""

import argparse
import re
import shutil
from pathlib import Path

import vendi

PAUSE_SECONDS = 20
MAX_PHOTOS_PER_DISC = 4   # oltre: gruppo sospetto (forse due dischi)
DISC_RE = re.compile(r"^disco-(\d+)$")


def loose_photos(folder):
    """Le foto direttamente nella cartella (non nelle sottocartelle), senza i file nascosti."""
    return sorted((f for f in Path(folder).iterdir()
                   if f.is_file() and not f.name.startswith(".") and f.suffix.lower() in vendi.IMAGE_EXTS),
                  key=lambda f: vendi.natural_key(f.name))


def taken_times(photos):
    """[(data di scatto, foto)] e l'elenco delle foto senza DateTimeOriginal."""
    taken = [(vendi.photo_taken_at(p), p) for p in photos]
    return [(t, p) for t, p in taken if t is not None], [p for t, p in taken if t is None]


def make_groups(taken, pause):
    """Gruppi di foto [(data, foto)]: nuovo disco quando tra due scatti passano più di `pause` secondi."""
    groups = []
    for t, p in sorted(taken, key=lambda x: (x[0], vendi.natural_key(x[1].name))):
        if groups and (t - groups[-1][-1][0]).total_seconds() <= pause:
            groups[-1].append((t, p))
        else:
            groups.append([(t, p)])
    return groups


def first_free_number(grade_dir):
    """Primo numero dopo le sottocartelle disco-NNN già presenti nella cartella del grado."""
    used = [int(m.group(1)) for d in (grade_dir.iterdir() if grade_dir.is_dir() else [])
            if d.is_dir() and (m := DISC_RE.match(d.name))]
    return max(used, default=0) + 1


def suspicion(group):
    if len(group) > MAX_PHOTOS_PER_DISC:
        return f"più di {MAX_PHOTOS_PER_DISC} foto: forse due dischi"
    if len(group) == 1:
        return "1 sola foto: forse manca il retro, o è un disco a sé"
    return ""


def fixed_groups(photos, per_disc):
    """Gruppi di esattamente per_disc foto nell'ordine di scatto (data EXIF se c'è per tutte, altrimenti
    l'ordine dei nomi: i nomi IMG_NNNN dell'iPhone seguono lo scatto). SystemExit se il conto non torna."""
    if len(photos) % per_disc:
        raise SystemExit(f"Mi fermo: {len(photos)} foto non sono divisibili per {per_disc} per disco: manca o "
                         "avanza una foto (un disco fotografato una volta sola, o uno scatto doppio). Nessuna foto "
                         "è stata spostata.")
    taken, missing = taken_times(photos)
    if missing:
        print(f"Attenzione: {len(missing)} foto senza data di scatto: uso l'ordine dei nomi dei file.")
        ordered = photos
    else:
        ordered = [p for _t, p in sorted(taken, key=lambda x: (x[0], vendi.natural_key(x[1].name)))]
    when = {p: t for t, p in taken}
    return [[(when.get(p), p) for p in ordered[i:i + per_disc]] for i in range(0, len(ordered), per_disc)]


def plan(source, grade_dir, pause, per_disc=0):
    """[(nome sottocartella, gruppo, sospetto)] oppure SystemExit se qualche foto non ha la data di scatto.
    per_disc > 0: gruppi fissi di tante foto (es. 2: fronte e retro), nell'ordine di scatto."""
    photos = loose_photos(source)
    if not photos:
        raise SystemExit(f"Nessuna foto in {source}.")
    if per_disc:
        start = first_free_number(grade_dir)
        return [(f"disco-{start + i:03d}", group, "") for i, group in enumerate(fixed_groups(photos, per_disc))]
    taken, missing = taken_times(photos)
    if missing:
        raise SystemExit(f"Mi fermo: {len(missing)} foto senza data di scatto (EXIF DateTimeOriginal), non posso "
                         "sapere in che ordine sono state scattate:\n  " + "\n  ".join(p.name for p in missing)
                         + "\nSuccede con le foto passate da WhatsApp o simili: usa gli originali (AirDrop o cavo), "
                         "oppure mettile a mano in una sottocartella. Nessuna foto è stata spostata.")
    start = first_free_number(grade_dir)
    return [(f"disco-{start + i:03d}", group, suspicion(group)) for i, group in enumerate(make_groups(taken, pause))]


def ask_confirmation(question):
    try:
        answer = input(f"{question} [s/N] ").strip().lower()
    except EOFError:
        return False
    return answer in ("s", "si", "sì", "y", "yes")


def main():
    parser = argparse.ArgumentParser(description="Raggruppa le foto sciolte in sottocartelle, una per disco")
    parser.add_argument("cartella", help="cartella con le foto sciolte (fronte, retro, etichetta di più dischi)")
    parser.add_argument("--grado", required=True,
                        help=f"grado dei dischi: {', '.join(vendi.GRADES)} (uguale per disco e copertina) oppure "
                             "DISCO_COPERTINA, es. M_NM (disco M, copertina NM)")
    parser.add_argument("--destinazione", required=True,
                        help="cartella del lotto: le foto vanno in <destinazione>/<grado>/disco-NNN")
    parser.add_argument("--pausa", type=float, default=PAUSE_SECONDS,
                        help=f"secondi tra due scatti oltre i quali inizia un nuovo disco (default {PAUSE_SECONDS})")
    parser.add_argument("--per-disco", type=int, default=0, metavar="N",
                        help="foto per disco fisse, nell'ordine di scatto (es. 2: fronte e retro); al posto della pausa")
    parser.add_argument("--si", action="store_true", help="sposta senza chiedere conferma")
    parser.add_argument("--simula", action="store_true", help="mostra solo l'anteprima, non sposta niente")
    args = parser.parse_args()

    source = Path(args.cartella).expanduser()
    if not source.is_dir():
        raise SystemExit(f"Cartella non trovata: {source}")
    grades = vendi.read_grades(args.grado)
    if not grades:
        raise SystemExit(f"Grado non valido: {args.grado} (usa {vendi.GRADE_FORMATS})")
    grade_dir = Path(args.destinazione).expanduser() / vendi.grade_text(*grades)

    groups = plan(source, grade_dir, args.pausa, args.per_disco)
    show_plan(groups, grade_dir, args.pausa, args.per_disco)
    if args.simula:
        print("\nSimulazione: nessuna foto è stata spostata.")
        return
    if not args.si and not ask_confirmation(f"\nSpostare le foto in {len(groups)} sottocartelle?"):
        print("Annullato: nessuna foto è stata spostata.")
        return
    move_groups(groups, grade_dir)


def show_plan(groups, grade_dir, pause, per_disc=0):
    how = f"{per_disc} foto per disco nell'ordine di scatto" if per_disc else \
        f"nuovo disco dopo più di {pause:g} secondi tra due scatti"
    print(f"Foto: {sum(len(g) for _n, g, _s in groups)}, dischi: {len(groups)} ({how}) -> {grade_dir}/")
    for name, group, why in groups:
        times = (f"{group[0][0]:%H:%M:%S}-{group[-1][0]:%H:%M:%S}" if group[0][0] and group[-1][0] else "")
        print(f"  {name}: {len(group)} foto{', ' + times if times else ''}"
              f" ({', '.join(p.name for _t, p in group)})" + (f"   SOSPETTO: {why}" if why else ""))
    suspicious = [(name, why) for name, _g, why in groups if why]
    if suspicious:
        print(f"\nGruppi sospetti: {len(suspicious)}, controllali dopo lo spostamento:")
        for name, why in suspicious:
            print(f"  {name}: {why}")


def move_groups(groups, grade_dir):
    for name, group, _why in groups:
        target = grade_dir / name
        target.mkdir(parents=True, exist_ok=False)
        for _t, p in group:
            shutil.move(str(p), target / p.name)
    print(f"Spostate {sum(len(g) for _n, g, _s in groups)} foto in {len(groups)} sottocartelle di {grade_dir}/.")


if __name__ == "__main__":
    main()
