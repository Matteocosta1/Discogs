import json, time, re, unicodedata, urllib.request, urllib.parse
UA = {"User-Agent": "VinylHustler/1.0"}
def get(url):
    for t in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=20) as r:
                time.sleep(2.6)
                return json.load(r)
        except Exception as e:
            time.sleep(15)
    return {}
def norma(s):
    s = unicodedata.normalize("NFKD", s.lower())
    s = re.sub(r"\(.*?\)|\[.*?\]", "", s)
    return re.sub(r"[^a-z0-9]", "", s)
def simili(a, b): return bool(a) and bool(b) and (a == b or a in b or b in a)
def apple(artista, r):
    if r.get("barcode") is not None: pass
    q = urllib.parse.urlencode({"term": f"{artista} {r['title']}", "entity": "album", "country": "it", "limit": "10"})
    d = get("https://itunes.apple.com/search?" + q)
    t, c = norma(r["title"]), norma(artista)
    for a in d.get("results", []):
        if simili(norma(a.get("collectionName", "")), t) and simili(norma(a.get("artistName", "")), c):
            return a.get("collectionName")
    return None
def video_ok(r):
    tr = [x for x in r.get("tracklist", []) if x.get("type_", "track") == "track" and x.get("title")]
    vs = [norma(v.get("title", "")) for v in r.get("videos", []) or [] if "youtu" in v.get("uri", "")]
    return sum(1 for x in tr if len(norma(x["title"])) >= 3 and any(norma(x["title"]) in v for v in vs)), len(tr)
for aid, nome in [(1289, "Daft Punk"), (4654, "Kraftwerk"), (82730, "The Beatles"), (8760, "Aux 88")]:
    print(f"\n===== {nome}")
    d = get(f"https://api.discogs.com/artists/{aid}/releases?sort=year&sort_order=asc&per_page=12")
    n = 0
    for it in d.get("releases", []):
        if it.get("role") != "Main": continue
        if n >= 5: break
        n += 1
        if it["type"] == "master":
            v = get(f"https://api.discogs.com/masters/{it['id']}/versions?sort=released&sort_order=asc&per_page=1")
            vecchia = (v.get("versions") or [{}])[0].get("id")
            principale = it.get("main_release")
        else:
            vecchia = principale = it["id"]
        for etichetta, rid in [("PIU' VECCHIA", vecchia), ("PRINCIPALE ", principale)]:
            if not rid: continue
            r = get(f"https://api.discogs.com/releases/{rid}")
            if not r: print("  ?", rid); continue
            art = re.sub(r" \(\d+\)$", "", r.get("artists_sort", ""))
            vid, tot = video_ok(r)
            mela = apple(art, r)
            print(f"  {it.get('year')} {it['title'][:34]:34} {etichetta} #{rid}: tracce {tot}, con video {vid}, Apple {'SI ('+mela+')' if mela else 'no'}, barcode {'si' if any(i.get('type')=='Barcode' for i in r.get('identifiers',[])) else 'no'}")
            if etichetta.startswith("PIU") and vecchia == principale: break
