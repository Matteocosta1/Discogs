import json, os, re, subprocess, time, urllib.parse, urllib.request
UA = 'VinylHustler/1.0 (mockup; matteocosta1@github)'
DISCHI = [('Miles Davis', 'Kind Of Blue'), ('The Clash', 'London Calling'), ('Daft Punk', 'Homework'),
          ('Talking Heads', 'Remain In Light'), ('Massive Attack', 'Mezzanine'), ('Nina Simone', 'Pastel Blues'),
          ('Kraftwerk', 'Trans-Europe Express'), ('Fela Kuti', 'Zombie'), ('Joy Division', 'Closer'),
          ('Aphex Twin', 'Selected Ambient Works 85-92'), ('Herbie Hancock', 'Head Hunters'), ('Portishead', 'Dummy')]
def get(url, js=True):
    for t in range(4):
        try:
            r = urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': UA}), timeout=30)
            b = r.read(); return json.loads(b) if js else b
        except Exception as e:
            print('  errore', url, e); time.sleep(3 + t * 3)
    return None
os.makedirs('copertine', exist_ok=True)
esito = []
for i, (a, t) in enumerate(DISCHI):
    q = urllib.parse.quote('releasegroup:"%s" AND artist:"%s" AND primarytype:album' % (t, a))
    rg = get('https://musicbrainz.org/ws/2/release-group/?fmt=json&limit=3&query=' + q); time.sleep(1.2)
    master = None
    for g in (rg or {}).get('release-groups', []):
        d = get('https://musicbrainz.org/ws/2/release-group/%s?fmt=json&inc=url-rels' % g['id']); time.sleep(1.2)
        for rel in (d or {}).get('relations', []):
            m = re.search(r'discogs\.com/master/(\d+)', rel.get('url', {}).get('resource', ''))
            if m: master = m.group(1); break
        if master: break
    voce = {'artista': a, 'titolo': t, 'master': master}
    if master:
        m = get('https://api.discogs.com/masters/' + master); time.sleep(2.5)
        imgs = (m or {}).get('images') or []
        voce['release'] = (m or {}).get('main_release'); voce['anno'] = (m or {}).get('year')
        url = next((x.get('uri') for x in imgs if x.get('type') == 'primary'), imgs[0].get('uri') if imgs else None)
        if not url:
            html = get('https://www.discogs.com/master/' + master, js=False) or b''
            mm = re.search(rb'property="og:image" content="([^"]+)"', html); url = mm.group(1).decode() if mm else None
        voce['img'] = url
        if url:
            b = get(url, js=False); time.sleep(1)
            if b:
                open('tmp', 'wb').write(b)
                subprocess.run(['convert', 'tmp', '-resize', '300x300^', '-gravity', 'center', '-extent', '300x300', '-quality', '82', 'copertine/%02d.jpg' % i], check=False)
    print(voce); esito.append(voce)
json.dump(esito, open('copertine/elenco.json', 'w'), indent=1)
