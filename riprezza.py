#!/usr/bin/env python3
"""
Riprezzamento periodico (circa una volta al mese), SOLO AL RIALZO.

Ricontrolla il mercato per i tuoi annunci In vendita su Discogs e propone un
prezzo nuovo solo se è più alto di quello attuale. Non abbassa MAI un prezzo.

  1. backup dello stato (data/backup/);
  2. legge dal tuo inventario gli annunci In vendita (bozze, venduti e annunci in
     un ordine non si toccano); di default tutti, con --solo-script solo quelli
     creati da vendi.py; ogni giro controlla al massimo --max-annunci annunci,
     prima quelli verificati da più tempo (con più giri si copre tutto a rotazione);
  3. ricalcola il prezzo con la STESSA regola di vendi.py (base, minimo suggerito
     per il grado dell'annuncio, premi scarsità e richiesta a scalini, griglia
     2,50 per eccesso), con dati di mercato aggiornati (--cache-prezzi-giorni);
  4. ESCLUDE I TUOI ANNUNCI dal calcolo: le statistiche di Discogs contano anche le
     tue copie, e senza correzione il prezzo si alimenterebbe da solo (sei l'unico a
     30 €, "1 copia, più basso 30 €", +50% -> 45 €, il mese dopo 67,50 €...):
     - copie della concorrenza = copie in vendita meno le tue (tutte le condizioni);
     - se il prezzo più basso è uguale o maggiore di un tuo prezzo per quella
       release (il più basso potresti essere tu) non lo usa: base = suggerito;
     - 0 copie della concorrenza: regola "0 copie" sul suggerito;
  5. se il più basso potresti essere tu ma ci sono altri venditori, gli altri
     chiedono di più e il tuo prezzo è probabilmente sotto mercato: NON alza in
     automatico, l'annuncio va nella sezione "sei il più economico" con il link alla
     pagina di vendita della release, da controllare a mano;
  6. propone il prezzo nuovo solo se supera quello attuale di almeno un gradino
     (2,50); altrimenti "invariato". Aumenti oltre --rialzo-massimo (default 50%) o
     prezzi sopra --soglia-controllo (default 100) vanno "da controllare" a mano;
     senza dati di mercato l'annuncio non si tocca;
  7. salva want e have di ogni release con la data: se i want sono cresciuti più di
     --crescita-want (default 30%) dal controllo precedente, segnala il disco
     "in crescita";
  8. scrive risultati/riprezzamento_AAAAMMGG.csv e un riepilogo;
  9. con --applica chiede conferma e aggiorna i prezzi via API uno per uno:
     rilegge ogni annuncio, reinvia TUTTI i suoi campi con il solo prezzo nuovo, lo
     rilegge ancora e si ferma se un campo diverso dal prezzo è cambiato. Ogni
     modifica resta nello storico (tabella riprezzamenti); se lo interrompi, al
     lancio successivo con --applica riprende da dove era, senza ripetere.

Esempi:
    python3 riprezza.py                 # propone e basta
    python3 riprezza.py --applica       # propone, chiede conferma, applica
"""

import argparse
import datetime as dt
from pathlib import Path

import vendi
from vendi import (GRADES, ApiError, ApiUncertain, DiscogsAPI, InventoryUnreadable, changed_fields, compute_price,
                   fetch_inventory, fmt, get_collector_data, get_price_suggestions, listing_edit_body, load_token, now,
                   open_state, write_csv)

GRADE_OF = {condition: grade for grade, condition in GRADES.items()}
MAX_LISTINGS = 500
MAX_RAISE_PCT = 50.0
WANT_GROWTH_PCT = 30.0
EXAMPLES = 10

SCHEMA = """
CREATE TABLE IF NOT EXISTS riprezzamenti (        -- storico: ogni prezzo cambiato da riprezza.py
    listing_id    INTEGER,
    data          TEXT,
    prezzo_vecchio REAL,
    prezzo_nuovo  REAL,
    calcolo       TEXT
);
CREATE TABLE IF NOT EXISTS riprezzamento_controlli ( -- quando è stato controllato l'ultima volta ogni annuncio
    listing_id      INTEGER PRIMARY KEY,
    ultimo_controllo TEXT
);
CREATE TABLE IF NOT EXISTS riprezzamento_piano (  -- modifiche approvate con --applica, per riprendere
    listing_id    INTEGER PRIMARY KEY,
    prezzo_vecchio REAL,
    prezzo_nuovo  REAL,
    calcolo       TEXT,
    approvato     TEXT,
    stato         TEXT,      -- da_fare / fatto / saltato / errore
    messaggio     TEXT
);
CREATE TABLE IF NOT EXISTS want_storico (         -- want e have di ogni release nel tempo
    release_id INTEGER,
    data       TEXT,
    want       INTEGER,
    have       INTEGER,
    PRIMARY KEY (release_id, data)
);
"""

ESITI = ["da alzare", "invariato", "da controllare", "sei il più economico", "dati non disponibili"]
HEADER = ["listing_id", "external_id", "artista_titolo", "grado", "prezzo_attuale", "prezzo_proposto", "aumento_pct",
          "esito", "motivo", "in_crescita", "want_have", "creato_da", "calcolo_prezzo", "link_annuncio",
          "link_vendite_release"]


def ask(question):
    try:
        return input(f"{question} [s/N] ").strip().lower() in ("s", "si", "sì", "y", "yes")
    except EOFError:
        return False


def script_ids(state):
    """external_id e listing_id degli annunci creati da vendi.py."""
    eids = {r[0] for r in state.execute("SELECT external_id FROM foto")}
    eids |= {r[0] for r in state.execute("SELECT external_id FROM righe_csv")}
    eids |= {r[0] for r in state.execute("SELECT external_id FROM annunci_api")}
    listings = {r[0] for r in state.execute("SELECT listing_id FROM annunci_api WHERE listing_id IS NOT NULL")}
    return eids, listings


def price_of(item):
    return float((item.get("price") or {}).get("value") or 0)


def want_growth(state, release_id, data):
    """Salva want/have della release con la data dei dati di mercato e restituisce la crescita % dei
    want rispetto al controllo precedente (None se non c'è un controllo precedente)."""
    row = state.execute("SELECT ottenuto FROM collezione WHERE release_id = ?", (release_id,)).fetchone()
    when = row["ottenuto"] if row else now()
    state.execute("INSERT OR IGNORE INTO want_storico VALUES (?, ?, ?, ?)",
                  (release_id, when, data.get("want") or 0, data.get("have") or 0))
    prev = state.execute("SELECT want FROM want_storico WHERE release_id = ? AND data < ? ORDER BY data DESC LIMIT 1",
                         (release_id, when)).fetchone()
    if not prev or not prev["want"]:
        return None
    return ((data.get("want") or 0) - prev["want"]) / prev["want"] * 100


def analyze(item, ctx, args):
    """Una riga del CSV di riprezzamento per un annuncio."""
    rid = (item.get("release") or {}).get("id")
    current = price_of(item)
    grade = GRADE_OF.get(item.get("condition"))
    row = {"listing_id": item["id"], "external_id": item.get("external_id") or "",
           "artista_titolo": (item.get("release") or {}).get("description", ""), "grado": grade or item.get("condition"),
           "prezzo_attuale": current, "prezzo_proposto": None, "aumento_pct": None, "esito": "", "motivo": "",
           "in_crescita": "", "want_have": "", "calcolo_prezzo": "", "release_id": rid,
           "creato_da": "script" if item.get("external_id") in ctx["eids"] or item["id"] in ctx["listings"] else "a mano",
           "link_annuncio": f"https://www.discogs.com/sell/item/{item['id']}",
           "link_vendite_release": f"https://www.discogs.com/sell/release/{rid}"}
    if grade is None:
        row.update(esito="dati non disponibili", motivo=f"condizione '{item.get('condition')}' non gestita dalla regola")
        return row

    market = ctx["market"].get(rid)
    if market is None:
        try:
            sugg, _ = get_price_suggestions(ctx["state"], ctx["api"], rid, max_age_days=args.cache_prezzi_giorni)
            data, _ = get_collector_data(ctx["state"], ctx["api"], None, rid, ctx["currency"],
                                         max_age_days=args.cache_prezzi_giorni)
            growth = want_growth(ctx["state"], rid, data)
            market = (sugg, data, growth)
        except (ApiError, ApiUncertain) as e:
            market = (None, None, str(e))
        ctx["market"][rid] = market
    sugg, data, growth = market
    suggestion = (sugg or {}).get(GRADES[grade]) or {}
    if data is None or not suggestion.get("value"):
        row.update(esito="dati non disponibili",
                   motivo=f"dati di mercato non disponibili ({growth})" if data is None else
                   f"nessun prezzo suggerito per {grade}")
        return row

    want, have = data.get("want") or 0, data.get("have") or 0
    row["want_have"] = f"{want}/{have}"
    if growth is not None and growth > args.crescita_want:
        row["in_crescita"] = f"want +{growth:.0f}%"

    # I miei annunci di questa release (tutte le condizioni) non sono concorrenza
    mine = ctx["mine"].get(rid, [])
    competitors = max((data.get("num_for_sale") or 0) - len(mine), 0)
    lowest = data.get("lowest_price") if data.get("lowest_currency") == ctx["currency"] else None
    maybe_me = lowest is not None and mine and lowest >= min(mine) - 0.005
    adjusted = {**data, "num_for_sale": competitors, "lowest_price": None if maybe_me else lowest}
    price, calc = compute_price(float(suggestion["value"]), adjusted, grade, ctx["currency"], args)
    note = (f"copie della concorrenza {competitors} (tue {len(mine)})"
            + (f"; più basso in vendita {fmt(lowest)} = forse tu, non usato" if maybe_me else ""))
    row.update(prezzo_proposto=price, calcolo_prezzo=f"{note}; {calc}",
               aumento_pct=(price / current - 1) * 100 if current else None)

    step = float(args.passo_prezzo)
    if maybe_me and competitors > 0:
        row.update(esito="sei il più economico",
                   motivo="il prezzo più basso in vendita potresti essere tu e ci sono altri venditori, che chiedono "
                          "di più: controlla a mano la pagina di vendita della release")
    elif price < current + step - 0.005:
        row["esito"] = "invariato"
    elif row["aumento_pct"] is not None and row["aumento_pct"] > args.rialzo_massimo:
        row.update(esito="da controllare", motivo=f"aumento del {row['aumento_pct']:.0f}% oltre il massimo "
                                                  f"automatico ({args.rialzo_massimo:g}%)")
    elif price > args.soglia_controllo:
        row.update(esito="da controllare", motivo=f"prezzo nuovo {fmt(price)} sopra la soglia di controllo "
                                                  f"({args.soglia_controllo:g})")
    else:
        row["esito"] = "da alzare"
    return row


def csv_rows(rows):
    order = {e: n for n, e in enumerate(ESITI)}
    out = []
    for r in sorted(rows, key=lambda r: (order.get(r["esito"], 9), -(r["aumento_pct"] or 0))):
        out.append([r["listing_id"], r["external_id"], r["artista_titolo"], r["grado"], f"{r['prezzo_attuale']:.2f}",
                    f"{r['prezzo_proposto']:.2f}" if r["prezzo_proposto"] is not None else "",
                    f"{r['aumento_pct']:.1f}" if r["aumento_pct"] is not None else "", r["esito"], r["motivo"],
                    r["in_crescita"], r["want_have"], r["creato_da"], r["calcolo_prezzo"], r["link_annuncio"],
                    r["link_vendite_release"]])
    return out


def print_summary(rows, currency):
    counts = {e: sum(1 for r in rows if r["esito"] == e) for e in ESITI}
    raise_rows = [r for r in rows if r["esito"] == "da alzare"]
    total = sum(r["prezzo_proposto"] - r["prezzo_attuale"] for r in raise_rows)
    growing = [r for r in rows if r["in_crescita"]]
    print(f"\nRiepilogo ({len(rows)} annunci controllati)")
    for e in ESITI:
        print(f"  {e}: {counts[e]}")
    print(f"  in crescita (want aumentati): {len(growing)}")
    print(f"  aumento totale del valore dell'inventario se applichi: +{fmt(total)} {currency}")
    for title, esito in (("Sei il più economico (controlla a mano)", "sei il più economico"),
                         ("Da controllare a mano", "da controllare")):
        chosen = [r for r in rows if r["esito"] == esito]
        if chosen:
            print(f"\n{title}:")
            for r in chosen[:EXAMPLES]:
                print(f"  {r['external_id'] or r['listing_id']} {r['artista_titolo']}: {fmt(r['prezzo_attuale'])}"
                      f" -> {fmt(r['prezzo_proposto'])}  {r['link_vendite_release']}")
            if len(chosen) > EXAMPLES:
                print(f"  ... e altri {len(chosen) - EXAMPLES} (vedi il CSV)")
    if growing:
        print("\nIn crescita:")
        for r in growing[:EXAMPLES]:
            print(f"  {r['external_id'] or r['listing_id']} {r['artista_titolo']}: {r['in_crescita']} "
                  f"(want/have {r['want_have']}, {r['esito']})")
    return raise_rows


def apply_plan(state, api, currency):
    """Applica le modifiche approvate ancora da fare (anche quelle di un giro interrotto)."""
    todo = state.execute("SELECT * FROM riprezzamento_piano WHERE stato = 'da_fare' ORDER BY listing_id").fetchall()
    done = 0
    for n, p in enumerate(todo, 1):
        lid = p["listing_id"]

        def mark(stato, message=""):
            state.execute("UPDATE riprezzamento_piano SET stato = ?, messaggio = ? WHERE listing_id = ?",
                          (stato, message, lid))
            state.commit()

        try:
            item = api.get_listing(lid)
        except ApiError as e:
            mark("errore", str(e))
            print(f"[{n}/{len(todo)}] {lid}: non letto ({e})")
            continue
        if item.get("status") != "For Sale":
            mark("saltato", f"non più In vendita ({item.get('status')})")
            print(f"[{n}/{len(todo)}] {lid}: saltato, non più In vendita")
            continue
        current = price_of(item)
        if abs(current - p["prezzo_nuovo"]) < 0.005:
            mark("fatto", "già al prezzo nuovo")
            continue
        if abs(current - p["prezzo_vecchio"]) >= 0.005:
            mark("saltato", f"prezzo cambiato nel frattempo ({fmt(current)})")
            print(f"[{n}/{len(todo)}] {lid}: saltato, il prezzo è cambiato nel frattempo ({fmt(current)})")
            continue
        try:
            api.edit_listing_fields(lid, listing_edit_body(item, price=p["prezzo_nuovo"]))
            after = api.get_listing(lid)
        except (ApiError, ApiUncertain) as e:
            mark("errore", str(e))
            print(f"[{n}/{len(todo)}] {lid}: modifica non riuscita ({e})")
            continue
        state.execute("INSERT INTO riprezzamenti VALUES (?, ?, ?, ?, ?)",
                      (lid, now(), p["prezzo_vecchio"], p["prezzo_nuovo"], p["calcolo"]))
        diff = changed_fields(item, after, ignore=("price",))
        if diff or abs(price_of(after) - p["prezzo_nuovo"]) >= 0.005:
            mark("errore", f"campi cambiati: {diff}")
            raise SystemExit(f"ATTENZIONE: la modifica dell'annuncio {lid} ha cambiato anche altri campi: {diff}.\n"
                             "Mi fermo. Controlla l'annuncio su Discogs (https://www.discogs.com/sell/item/"
                             f"{lid}) e dimmelo.")
        mark("fatto")
        done += 1
        print(f"[{n}/{len(todo)}] {lid}: {fmt(p['prezzo_vecchio'])} -> {fmt(p['prezzo_nuovo'])} {currency}")
    return done, len(todo)


def main():
    parser = argparse.ArgumentParser(description="Riprezzamento periodico degli annunci, solo al rialzo")
    vendi.add_price_args(parser)
    parser.add_argument("--applica", action="store_true",
                        help="dopo il riepilogo chiede conferma e aggiorna i prezzi via API (senza: propone e basta)")
    parser.add_argument("--solo-script", action="store_true", help="solo gli annunci creati da vendi.py")
    parser.add_argument("--max-annunci", type=int, default=MAX_LISTINGS,
                        help=f"annunci da controllare in questo giro, prima i verificati da più tempo (default {MAX_LISTINGS})")
    parser.add_argument("--rialzo-massimo", type=float, default=MAX_RAISE_PCT,
                        help=f"aumento %% oltre il quale il prezzo va controllato a mano (default {MAX_RAISE_PCT:g})")
    parser.add_argument("--crescita-want", type=float, default=WANT_GROWTH_PCT,
                        help=f"crescita %% dei want dal controllo precedente per segnalare un disco 'in crescita' "
                             f"(default {WANT_GROWTH_PCT:g})")
    parser.add_argument("--cache-prezzi-giorni", type=float, default=vendi.CACHE_PRICES_DAYS,
                        help=f"dati di mercato più vecchi di tanti giorni si richiedono a Discogs "
                             f"(default {vendi.CACHE_PRICES_DAYS})")
    parser.add_argument("--uscita", default=str(vendi.OUT_DIR), help="cartella dei risultati (default: risultati/)")
    parser.add_argument("--backup-da-tenere", type=int, default=vendi.BACKUPS_TO_KEEP,
                        help=f"copie dello stato da tenere in data/backup/ (default {vendi.BACKUPS_TO_KEEP})")
    args = parser.parse_args()
    vendi.check_price_args(args)
    out_dir = Path(args.uscita).expanduser()

    saved = vendi.backup_state(vendi.STATE_DB, args.backup_da_tenere)
    if saved:
        print(f"Backup dello stato: {saved}")
    state = open_state(vendi.STATE_DB)
    state.executescript(SCHEMA)
    try:
        api = DiscogsAPI(load_token())
        username = api.identity()["username"]
        currency = api.user(username).get("curr_abbr", "")
        print(f"Collegato a Discogs come {username} (valuta: {currency}). Leggo gli annunci In vendita...")
        try:
            inventory = fetch_inventory(api, username, statuses=["For Sale"])
        except InventoryUnreadable as e:
            raise SystemExit(f"Impossibile leggere l'inventario Discogs: {e}\nNiente è stato modificato.")
        for_sale = [i for i in inventory.by_listing.values() if i.get("status") == "For Sale"]
        eids, listings = script_ids(state)
        if args.solo_script:
            for_sale = [i for i in for_sale if i.get("external_id") in eids or i["id"] in listings]
        mine = {}
        for i in inventory.by_listing.values():  # tutte le mie copie in vendita, anche quelle non controllate ora
            if i.get("status") == "For Sale":
                mine.setdefault((i.get("release") or {}).get("id"), []).append(price_of(i))

        checked = dict(state.execute("SELECT listing_id, ultimo_controllo FROM riprezzamento_controlli"))
        for_sale.sort(key=lambda i: (checked.get(i["id"]) or "", i["id"]))
        batch = for_sale[:args.max_annunci]
        print(f"Annunci In vendita: {len(for_sale)}; in questo giro ne controllo {len(batch)} "
              "(prima quelli verificati da più tempo)")

        ctx = {"state": state, "api": api, "currency": currency, "mine": mine, "market": {}, "eids": eids,
               "listings": listings}
        rows = []
        for n, item in enumerate(batch, 1):
            rows.append(analyze(item, ctx, args))
            state.execute("INSERT OR REPLACE INTO riprezzamento_controlli VALUES (?, ?)", (item["id"], now()))
            state.commit()
            if n % 50 == 0:
                print(f"  {n}/{len(batch)} controllati...")

        path = out_dir / f"riprezzamento_{dt.date.today():%Y%m%d}.csv"
        write_csv(path, HEADER, csv_rows(rows))
        raise_rows = print_summary(rows, currency)
        print(f"\nDettaglio in {path}")

        pending = state.execute("SELECT COUNT(*) FROM riprezzamento_piano WHERE stato = 'da_fare'").fetchone()[0]
        if not args.applica:
            if pending:
                print(f"\nCi sono {pending} modifiche approvate e non ancora applicate (giro interrotto): "
                      "rilancia con --applica per completarle.")
            print("\nNessun prezzo è stato modificato (per applicare: python3 riprezza.py --applica).")
            return
        if not raise_rows and not pending:
            print("\nNessun prezzo da alzare.")
            return
        question = f"\nAlzare il prezzo di {len(raise_rows)} annunci"
        question += f" (più {pending} rimasti da un giro interrotto)?" if pending else "?"
        if not ask(question):
            print("Annullato: nessun prezzo è stato modificato.")
            return
        for r in raise_rows:
            state.execute("INSERT OR REPLACE INTO riprezzamento_piano VALUES (?, ?, ?, ?, ?, 'da_fare', '')",
                          (r["listing_id"], r["prezzo_attuale"], r["prezzo_proposto"], r["calcolo_prezzo"], now()))
        state.commit()
        try:
            done, total = apply_plan(state, api, currency)
        except KeyboardInterrupt:
            print("\nInterrotto: rilancia con --applica per completare le modifiche rimaste.")
            return
        print(f"\nPrezzi aggiornati: {done} su {total}. Storico nella tabella riprezzamenti dello stato.")
    finally:
        state.close()


if __name__ == "__main__":
    main()
