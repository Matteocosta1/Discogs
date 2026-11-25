import json, time, urllib.request
UA = {"User-Agent": "VinylHustler/1.0"}
def get(u):
    with urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=20) as r:
        time.sleep(2.6); return json.load(r)
r = get("https://api.discogs.com/releases/7982")
print("labels", [(l.get('id'), l.get('name')) for l in r.get('labels', [])], "artists", [(a.get('id'), a.get('name')) for a in r.get('artists', [])])
lid = r['labels'][0]['id']
l = get(f"https://api.discogs.com/labels/{lid}")
print("label keys", list(l.keys())); print("parent", l.get('parent_label'), "sub", (l.get('sublabels') or [])[:2])
for q in ["", "&sort=year&sort_order=asc", "&sort=year&sort_order=desc"]:
    p = get(f"https://api.discogs.com/labels/{lid}/releases?per_page=8{q}")
    print("label releases", q or "(default)", p.get('pagination', {}).get('items'), [(x.get('year'), x.get('title')[:20], x.get('artist')[:15]) for x in p['releases']])
print("label item keys", list(p['releases'][0].keys()))
a = get("https://api.discogs.com/artists/1289/releases?sort=year&sort_order=asc&per_page=6")
print("artist items", a.get('pagination'))
for x in a['releases']: print(json.dumps(x)[:400])
