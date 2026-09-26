# Discogs: database locale e messa in vendita

Due script:

- **`discogs_dump.py`**: scarica il dump mensile delle release di Discogs e lo
  importa in un database SQLite locale (`data/discogs.sqlite`), con indici su
  barcode, numero di catalogo e parole di artista e titolo.
- **`vendi.py`**: riconosce i dischi dalle foto, chiede a Discogs il prezzo
  suggerito, aggiunge il ricarico e prepara la vendita. I dischi trovati nel
  database locale finiscono nei CSV di caricamento dell'inventario. Quelli
  trovati solo via API vengono pubblicati direttamente via API.

Il database, i token e le chiavi (`.env`) e i risultati sono nel `.gitignore`, quindi non
finiscono mai nella repository.

---

## Parte 1: il database (`discogs_dump.py`)

- Usa solo Python 3.
- Se il database contiene già l'ultimo dump, lo script non fa nulla.
- Se il dump è nuovo, lo script crea un database nuovo e sostituisce quello
  vecchio solo a fine importazione. Fino ad allora quello vecchio resta usabile.
- Un download interrotto riprende da dove si era fermato: basta rilanciare lo
  stesso comando.

> **Spazio e tempo:** il dump compresso pesa più di 10 GB e il database finale
> qualche decina di GB. Tieni liberi almeno 50 GB. L'importazione richiede
> qualche ora. A fine lavoro il file scaricato viene cancellato (con
> `--keep-dump` lo tieni).

### 1. Prima volta: controlla Python e scarica il progetto

Apri **Terminale** (Applicazioni → Utility → Terminale) e lancia:

```bash
python3 --version
```

Se macOS propone di installare gli "strumenti per sviluppatori da riga di
comando", accetta e poi rilancia il comando. Serve Python 3.8 o più recente.

Poi scarica il progetto nella tua cartella Inizio:

```bash
cd ~
git clone https://github.com/Matteocosta1/Discogs.git
cd ~/Discogs
```

### 2. Crea o aggiorna il database (da rilanciare ogni mese)

```bash
cd ~/Discogs
git pull
caffeinate -i python3 discogs_dump.py aggiorna
```

`caffeinate -i` impedisce al Mac di andare in stop mentre lo script lavora.
Tieni il Mac collegato alla corrente.

> **Se avevi già creato il database con una versione precedente:** ora il
> database ha anche gli indici per numero di catalogo e per artista e titolo,
> che servono a `vendi.py`. Lo stesso comando `aggiorna` se ne accorge da solo,
> riscarica il dump e lo reimporta. Serve una volta sola. L'indice di artista
> e titolo allunga un po' l'importazione e occupa qualche GB in più.

### 3. Cerca una release

```bash
cd ~/Discogs
python3 discogs_dump.py cerca 5099902987125           # per barcode
python3 discogs_dump.py cerca --catno "SHVL 804"      # per numero di catalogo
python3 discogs_dump.py cerca --testo "de andre buona novella"   # per parole di artista e titolo
python3 discogs_dump.py info                          # quale dump c'è nel database
```

Spazi, trattini, maiuscole e accenti vengono ignorati, quindi
`5 099902 98712 5` o `De André` funzionano uguale.

### Se il download automatico non funziona

A volte Discogs cambia gli indirizzi del sito. In quel caso:

1. Apri [data.discogs.com](https://data.discogs.com/) nel browser.
2. Scarica il file più recente che si chiama `discogs_AAAAMMGG_releases.xml.gz`.
   Finisce nella cartella Download.
3. Importalo così (sostituisci il nome del file con quello che hai scaricato):

```bash
cd ~/Discogs
caffeinate -i python3 discogs_dump.py aggiorna --file ~/Downloads/discogs_20260901_releases.xml.gz
```

Se compare un errore `CERTIFICATE_VERIFY_FAILED` e hai installato Python dal
sito python.org, lancia una volta questo comando (cambia `3.12` con la tua
versione) e riprova:

```bash
open "/Applications/Python 3.12/Install Certificates.command"
```

### Opzioni di `discogs_dump.py`

| Opzione | Cosa fa |
| --- | --- |
| `aggiorna --force` | Reimporta anche se il database è già aggiornato |
| `aggiorna --keep-dump` | Non cancella il file `.xml.gz` scaricato |
| `aggiorna --file PERCORSO` | Usa un dump già scaricato |
| `--db PERCORSO` (prima del comando) | Usa un altro file di database |

---

## Parte 2: mettere in vendita (`vendi.py`)

### Come preparare le foto

La struttura è semplicemente `Dischi/<grado>/<foto>`:

- una cartella per grado, con esattamente questi nomi: `M`, `NM`, `VG+`,
  `VG`, `G+`, `G`. Per ora il grado della cartella vale sia per il disco sia
  per la copertina;
- dentro, **una foto del retro per copia**, con i nomi originali dell'iPhone,
  in JPG o HEIC. Non serve rinominare nulla.

```
Dischi/
  NM/
    IMG_1234.HEIC
    IMG_1240.JPG
  VG+/
    IMG_1235.HEIC
    IMG_1236.HEIC   ← stesso disco di IMG_1235, stesso grado: diventano 1 annuncio con quantità 2
  VG/
    IMG_1237.JPG    ← stesso disco ma VG: annuncio separato
```

- **L'external_id è il nome della foto senza estensione** (es. `IMG_1234`). È
  un campo privato su Discogs: quando un disco si vende, ti dice quale foto
  corrisponde.
- **Copie:** le foto riconosciute come la **stessa release con lo stesso
  grado** vengono unite in un unico annuncio, con quantità pari al numero di
  foto. Le copie di gradi diversi vanno nelle rispettive cartelle e diventano
  annunci separati.
- **Controlli all'avvio.** Lo script si ferma subito, prima di fare qualsiasi
  cosa, se trova:
  - una cartella che non è un grado;
  - due foto con lo stesso nome in cartelle diverse (es. `VG/IMG_1234.JPG` e
    `NM/IMG_1234.HEIC`), perché avrebbero lo stesso external_id. Rinominane
    una.

### Cosa fa, foto per foto

Molti dischi non hanno codici sul retro, quindi lo script prova in quest'ordine
e si ferma al primo metodo che funziona. I passi 1-3 sono gratuiti e girano sul
Mac, nel database locale.

1. **Barcode**, letto con zxing-cpp.
2. **Numero di catalogo + etichetta**, letti con l'OCR di macOS. Una release
   trovata per catno viene accettata solo se anche il **nome dell'etichetta**
   compare nella foto, per evitare abbinamenti sbagliati.
3. **Artista e titolo**, letti con l'OCR da tutto il testo della foto,
   compresa l'etichetta centrale del disco se si vede.
   - Lo script parte dalle scritte più grandi, che di solito sono artista e
     titolo.
   - La ricerca è **tollerante agli errori di lettura**: ignora maiuscole,
     accenti e punteggiatura, corregge gli scambi tipici dell'OCR (`0`/`O`,
     `1`/`l`, `5`/`S`…) e accetta parole quasi uguali.
4. Se il disco **non è nel database locale**, lo cerca su Discogs via API:
   prima per barcode, poi per numero di catalogo.
5. Solo con l'opzione **`--ai`** (spenta di default, a pagamento), per le
   foto ancora non riconosciute o ambigue, un modello con visione legge la foto.
   Con i dati letti dall'AI lo script rifà i passi 1-4. Vedi più sotto.

**Quando escono più release possibili** (per esempio lo stesso album stampato
in più paesi), lo script dà un punteggio a ciascuna usando gli altri dati letti
nella foto:

| Dato letto nella foto | Punti |
| --- | --- |
| artista e titolo (percentuale di parole ritrovate) | fino a 1 |
| numero di catalogo | +0,30 |
| nome dell'etichetta | +0,15 |
| anno (es. `℗ 1973`) | +0,10 |
| paese (es. `Made in Italy`) | +0,05 |

Accetta la prima **solo se è chiaramente la migliore**, cioè con almeno 0,15
punti di distacco dalla seconda. Altrimenti la foto va in `da_controllare.csv`
con i candidati ordinati per punteggio e il dettaglio dei punti. Per il passo 3
serve inoltre che artista e titolo siano ritrovati entrambi.

Poi:

- Riconosciute tutte le foto, **raggruppa** quelle con la stessa release e lo
  stesso grado.
- **Prezzo suggerito** da Discogs per il grado della cartella, più il ricarico
  (12% di default). Una chiamata restituisce i prezzi di tutti i gradi di una
  release, quindi gli altri gradi della stessa release riusano il prezzo senza
  nuove chiamate.
- **Uscita:**
  - trovato **in locale** → **una riga** nel CSV di inventario, con
    `quantity` = numero di foto ed `external_id` = nome della prima foto
    del gruppo;
  - trovato **solo via API** → annunci creati direttamente via API
    (`For Sale`). L'API di Discogs non ha un campo quantità, quindi lo script
    crea **un annuncio per foto**, con external_id = nome di quella foto.

Senza `--ai` non si usano modelli AI né servizi a pagamento: barcode e OCR
sono librerie gratuite che girano sul Mac, e l'API di Discogs è gratuita con il
token personale.

### Prima volta: installazione

```bash
cd ~/Discogs
git pull
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Poi crea il file con il token di Discogs. Il token si genera su
[discogs.com/settings/developers](https://www.discogs.com/settings/developers)
("Generate new token").

```bash
cd ~/Discogs
cp .env.example .env
open -e .env
```

Si apre TextEdit. Incolla il token dopo `DISCOGS_TOKEN=` (senza spazi né
virgolette), salva e chiudi.

> I prezzi suggeriti funzionano solo se il tuo account Discogs ha le
> **impostazioni venditore** compilate. Arrivano nella valuta del tuo account
> venditore.

### Ogni volta: apri il Terminale e attiva l'ambiente

```bash
cd ~/Discogs
source .venv/bin/activate
```

### Prova (consigliata prima del lancio vero)

Sostituisci `~/Pictures/Dischi` con la cartella delle tue foto. Puoi anche
trascinare la cartella dal Finder nel Terminale per scriverne il percorso.

```bash
python3 vendi.py ~/Pictures/Dischi --limite 20 --simula
```

- `--limite 20`: elabora solo le prime 20 foto, in ordine di nome.
- `--simula`: riconosce le foto e chiede i prezzi davvero, ma **non pubblica
  nessun annuncio** e non tocca i CSV veri. Scrive tutto in
  `risultati/simulazione/`:
  - `inventario_001.csv`: quello che andrebbe nel caricamento;
  - `annunci_api_simulati.csv`: gli annunci che verrebbero pubblicati via API.

Guarda anche `risultati/da_controllare.csv`.

### Lancio vero

```bash
caffeinate -i python3 vendi.py ~/Pictures/Dischi
```

Con un ricarico diverso, per esempio il 15%:

```bash
caffeinate -i python3 vendi.py ~/Pictures/Dischi --ricarico 15
```

**Tempi:** lo script fa al massimo 60 richieste al minuto a Discogs, come
impone il limite dell'API. Con 10.000 dischi conta diverse ore. Puoi
interromperlo quando vuoi con **Ctrl+C**: rilanciando lo stesso comando
riparte da dove era. Le foto già riconosciute non vengono rianalizzate e gli
annunci già pubblicati non vengono mai ripubblicati.

### Opzione `--ai` (facoltativa, a pagamento)

Per le foto che i metodi gratuiti non riconoscono, o che restano ambigue, puoi
far leggere la foto a un modello AI con visione (Claude di Anthropic). È spenta
di default.

1. Crea una chiave API su
   [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys)
   e aggiungila al file `.env` (si apre con `open -e .env`) nella riga
   `ANTHROPIC_API_KEY=`.
2. Lancia con `--ai` e un **tetto di spesa** in dollari (default 5):

```bash
caffeinate -i python3 vendi.py ~/Pictures/Dischi --ai --ai-tetto 3
```

- **Quali foto:** solo quelle non riconosciute o ambigue con i metodi
  gratuiti. Le foto già riconosciute non vengono mai inviate.
- **Cosa viene inviato:** la foto ridotta (lato lungo 1568 pixel). Il modello
  restituisce artista, titolo, etichetta, catno, anno, paese e barcode, e lo
  script li cerca nel database come se li avesse letti l'OCR.
- **Conflitto AI/OCR:** se l'AI indica un disco diverso da quello che l'OCR
  aveva letto chiaramente, la foto va in `da_controllare.csv` con la nota "in
  contrasto".
- **Tetto di spesa:** vale **in totale, sommando tutte le esecuzioni**. Il
  costo di ogni foto è registrato nello stato. Prima di ogni chiamata lo
  script controlla che il costo massimo previsto stia sotto il tetto; se non
  ci sta, smette di usare l'AI per il resto dell'esecuzione. Per continuare,
  rilancia con un tetto più alto.
- **Nessuna spesa doppia:** una foto già letta dall'AI non viene mai
  reinviata, nemmeno con `--riprova`, a meno che tu la sostituisca con uno
  scatto nuovo.
- **Modello:** di default `claude-haiku-4-5`, il più economico (1 $ per
  milione di token in ingresso, 5 $ in uscita). **Stima:** circa 0,2-0,4
  centesimi di dollaro a foto, quindi 1.000 foto costano circa 2-4 $. Per foto
  difficili puoi scegliere `--ai-modello claude-sonnet-5` (circa il doppio) o
  `claude-opus-5` (circa 5 volte).
- **Riepilogo:** a fine esecuzione mostra quanto hai speso in questa
  esecuzione e in totale.

### I risultati (cartella `risultati/`)

| File | Cosa contiene |
| --- | --- |
| `inventario_001.csv`, `inventario_002.csv`… | Dischi trovati in locale, al massimo 1.000 dischi per file (le copie contano), da caricare su Discogs |
| `inventario_foto.csv` | Per ogni riga dei CSV di inventario, tutte le foto (copie) che contiene |
| `annunci_pubblicati_api.csv` | Annunci pubblicati via API, uno per foto, con link |
| `da_controllare.csv` | Foto da sistemare a mano: nome della foto, cartella, motivo, dettagli letti e candidati |

I CSV di inventario hanno le colonne `release_id`, `price`, `media_condition`,
`sleeve_condition`, `quantity`, `external_id` e `status` (`FOR_SALE`, il
valore indicato dalla guida di Discogs per il caricamento CSV).

- Una riga scritta in un file **resta sempre in quel file**, e le righe delle
  esecuzioni successive vanno in file nuovi.
- Quindi i file che hai già caricato non cambiano: carica solo quelli nuovi.
- Se aggiungi più avanti un'altra foto di una release già messa in vendita con
  lo stesso grado, diventa una **riga nuova** in un file nuovo, non si somma
  alla riga già caricata.

Si caricano dalla pagina di caricamento dell'inventario di Discogs
([discogs.com/sell/upload](https://www.discogs.com/sell/upload)).

> **Al primo caricamento prova con un file piccolo** (per esempio quello
> prodotto con `--limite 20`), che contenga anche una riga con più copie. Le
> colonne e il valore `FOR_SALE` seguono la guida
> [Import and Export Your Inventory (CSV)](https://support.discogs.com/hc/en-us/articles/360007622373-Import-and-Export-Your-Inventory-CSV),
> ma non ho potuto provarli con un caricamento reale. Controlla che la
> quantità risulti giusta. Se Discogs segnala una colonna non valida, dimmelo e
> la correggo.

Motivi possibili in `da_controllare.csv`:

- **non trovato né nel database locale né su Discogs**: le colonne `dettagli`
  e `candidati` dicono cosa è stato letto. Per esempio un catno trovato nel
  database ma senza che l'etichetta si leggesse nella foto.
- **più release possibili**: più stampe (o più dischi) compatibili che non si
  sono potute distinguere. Nella colonna `candidati` trovi i link ordinati per
  punteggio, con i dati che hanno dato punti (es. `artista 100%, titolo 100%,
  paese`): scegli quella giusta su Discogs. Se la nota dice "in contrasto",
  l'AI e l'OCR hanno letto dischi diversi.
- **nessun prezzo suggerito da Discogs**.
- **pubblicazione non confermata**: lo script si è interrotto proprio durante
  la pubblicazione e non è riuscito a verificare se l'annuncio esiste.
  Controlla su Discogs cercando l'`external_id` (es. `IMG_1234`).
- **Discogs ha rifiutato l'annuncio**, con il messaggio di Discogs.

Se sostituisci una foto finita da controllare con uno scatto migliore (stesso
nome), al prossimo lancio viene rianalizzata da sola. Per rianalizzare tutte le
foto da controllare:

```bash
caffeinate -i python3 vendi.py ~/Pictures/Dischi --riprova
```

### Opzioni di `vendi.py`

| Opzione | Cosa fa |
| --- | --- |
| `--ricarico 15` | Ricarico in % sul prezzo suggerito (default 12) |
| `--limite N` | Elabora solo le prime N foto |
| `--simula` | Non pubblica annunci e non tocca i CSV veri; scrive in `risultati/simulazione/` |
| `--riprova` | Rianalizza le foto finite da controllare |
| `--ai` | Usa un modello AI con visione solo per le foto non riconosciute (a pagamento) |
| `--ai-tetto 3` | Spesa AI massima in dollari, sommando tutte le esecuzioni (default 5) |
| `--ai-modello NOME` | `claude-haiku-4-5` (default), `claude-sonnet-5` o `claude-opus-5` |
| `--uscita PERCORSO` | Cartella dei risultati (default `risultati/`) |
| `--db PERCORSO` | Database creato da `discogs_dump.py` (default `data/discogs.sqlite`) |

### Dove sta lo stato

I progressi (foto riconosciute, dati letti dall'AI e relativo costo, prezzi ottenuti, righe CSV e annunci creati) sono in
`data/vendita_stato.sqlite`. È separato da `discogs.sqlite` perché quello viene
ricostruito da zero ogni mese, e i progressi andrebbero persi.

**Non cancellare questo file:** è quello che impedisce di pubblicare due
volte lo stesso disco.

---

## Struttura del database `discogs.sqlite`

- `releases`: una riga per release (`id`, `title`, `artists`, `labels`,
  `catno`, `formats`, `country`, `released`, `year`, `genres`, `styles`,
  `master_id`, `status`, `data_quality`).
- `barcodes`: `release_id`, `barcode`, `barcode_norm` (**indicizzato**).
- `catnos`: `release_id`, `label`, `catno`, `catno_norm` (**indicizzato**).
- `releases_fts`: indice di ricerca testuale (SQLite FTS5) su artista e titolo,
  normalizzati senza maiuscole, accenti e punteggiatura; `releases_vocab`
  elenca le parole presenti.
- `meta`: data del dump, versione dello schema, data di importazione.
