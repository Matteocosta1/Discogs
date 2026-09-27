# Discogs: database locale e messa in vendita

Tre script:

- **`discogs_dump.py`**: scarica il dump mensile delle release di Discogs e lo
  importa in un database SQLite locale (`data/discogs.sqlite`), con indici su
  barcode, numero di catalogo e parole di artista e titolo.
- **`vendi.py`**: riconosce i dischi da una foto qualsiasi (fronte, retro o
  etichetta), senza interventi manuali, calcola il prezzo dai dati del
  marketplace Discogs e prepara la vendita. I dischi trovati nel
  database locale finiscono nei CSV di caricamento dell'inventario. Quelli
  trovati solo via API vengono pubblicati direttamente via API.
- **`pubblica_bozze.py`**: mette in vendita, in blocco e dopo la tua conferma,
  gli annunci che `vendi.py --bozza` ha creato in bozza.

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
- dentro, **una foto per copia**: il **fronte**, il **retro** o l'**etichetta
  centrale**, come ti viene più comodo. Nomi originali dell'iPhone, in JPG o
  HEIC: non serve rinominare nulla.

```
Dischi/
  NM/
    IMG_1234.HEIC   ← fronte
    IMG_1240.JPG    ← retro
  VG+/
    IMG_1235.HEIC   ← etichetta centrale
    IMG_1236.HEIC   ← stesso disco di IMG_1235, stesso grado: 1 annuncio con quantità 2
  VG/
    IMG_1237.JPG    ← stesso disco ma VG: annuncio separato
```

- **L'external_id è il nome della foto senza estensione** (es. `IMG_1234`). È
  un campo privato su Discogs: quando un disco si vende, ti dice quale foto
  corrisponde.
- **Copie:** le foto riconosciute come la **stessa release con lo stesso
  grado** vengono unite in un unico annuncio, con quantità pari al numero di
  foto.
- **Controlli all'avvio.** Lo script si ferma subito se trova una cartella che
  non è un grado, o due foto con lo stesso nome in cartelle diverse (avrebbero
  lo stesso external_id: rinominane una).

### Come riconosce il disco

Il riconoscimento usa due parti che lavorano insieme: la **ricerca locale**,
gratuita, e un **modello AI con visione** (Claude di Anthropic), che entra solo
quando la parte locale non basta.

1. **Parte locale (gratis).** Lo script legge il barcode e tutto il testo della
   foto con l'OCR di macOS, poi cerca nel database locale:
   - per **barcode**;
   - per **numero di catalogo + etichetta**;
   - per **artista + titolo**, in modo tollerante agli errori di lettura
     (maiuscole, accenti, punteggiatura, `0`/`O`, `1`/`l`…).

   Se non trova nulla in locale ma ha letto un barcode o un catno, prova la
   stessa ricerca su Discogs via API, anche questa gratuita. **Se il risultato
   è sicuro, lo usa e non chiama l'AI.**
2. **L'AI guarda la foto** e dice cosa vede: tipo di foto (fronte, retro,
   etichetta), artista, titolo, etichetta, catno, anno, paese, barcode, il
   testo leggibile e, se lo riconosce dalla copertina, il disco che ritiene
   sia.
3. **Di nuovo la parte locale:** con i dati dell'AI cerca i candidati nel
   database e, se non ce ne sono, su Discogs via API (anche per artista e
   titolo).
4. **L'AI sceglie:** riceve la foto e l'elenco dei candidati con i loro dati
   (etichetta, catno, paese, anno, formato, barcode) e indica quello giusto con
   un livello di sicurezza (alta, media o bassa). Se la stampa esatta non si
   può determinare, sceglie la più probabile in base agli indizi visibili.
   - Se dopo il passo 3 c'è un solo candidato, o uno è chiaramente il migliore,
     lo script salta questa seconda chiamata e risparmia.

**Regola di sicurezza: l'AI non può inventare.**
- La release scelta deve sempre esistere nel database o su Discogs: l'AI può
  solo scegliere tra i candidati trovati dallo script.
- Artista e titolo della release devono combaciare con quelli letti o
  riconosciuti nella foto.
- Tutto ciò che non passa questi controlli va in `da_controllare.csv`.

In `da_controllare.csv` finisce solo ciò che nemmeno così si riesce a
identificare.

**Quando nella parte locale escono più release possibili** (per esempio lo
stesso album stampato in più paesi), lo script dà un punteggio a ciascuna con
gli altri dati letti nella foto: artista e titolo (fino a 1), catno (+0,30),
etichetta (+0,15), anno (+0,10), paese (+0,05). La considera sicura solo con
almeno 0,15 punti di distacco dalla seconda; altrimenti decide l'AI.

**Poi, come prima:**
- **Raggruppa** le foto con la stessa release e lo stesso grado.
- **Prezzo** calcolato con la regola descritta più sotto (prezzo più basso in
  vendita, mai sotto il suggerito per il grado, più eventuali premi).
- **Uscita:**
  - trovato **nel database locale** → **una riga** nel CSV di inventario, con
    `quantity` = numero di foto ed `external_id` = nome della prima foto;
  - trovato **solo su Discogs** → annunci creati via API (`For Sale`), **uno
    per foto** perché l'API non ha un campo quantità, con external_id = nome
    di quella foto;
  - con `--bozza` gli annunci (sia nel CSV sia via API) sono creati **in
    bozza** (`Draft`): non sono visibili ai compratori finché non li metti in
    vendita tu da Discogs.

### Prima volta: installazione

```bash
cd ~/Discogs
git pull
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Poi crea il file `.env` con il token di Discogs e la chiave API di Anthropic.

**1. Token di Discogs (gratis).** Vai su
[discogs.com/settings/developers](https://www.discogs.com/settings/developers)
e premi "Generate new token". Copia il token.

**2. Chiave API di Anthropic (per l'AI, a pagamento a consumo).**
1. Vai su [console.anthropic.com](https://console.anthropic.com) e crea un
   account, o entra con quello che hai.
2. In **Settings → Billing** aggiungi un metodo di pagamento e un po' di
   credito, per esempio 10-20 €. Senza credito le chiamate vengono rifiutate.
   Nella stessa pagina puoi impostare anche un limite di spesa mensile
   dell'account, come ulteriore protezione.
3. In **Settings → API Keys** premi **Create Key**, dagli un nome (es.
   `dischi`) e **copia subito la chiave**, che inizia con `sk-ant-`. Viene
   mostrata una volta sola.

**3. Inseriscile nel file `.env`:**

```bash
cd ~/Discogs
cp .env.example .env
open -e .env
```

Si apre TextEdit. Incolla il token dopo `DISCOGS_TOKEN=` e la chiave dopo
`ANTHROPIC_API_KEY=`, senza spazi né virgolette:

```
DISCOGS_TOKEN=AbCdEf123...
ANTHROPIC_API_KEY=sk-ant-...
```

Salva e chiudi. Il file `.env` è nel `.gitignore`: non finisce mai nella
repository. Non condividerlo con nessuno.

Se non vuoi usare l'AI, lascia vuota la chiave e lancia lo script con
`--senza-ai`: le foto che la parte locale non riconosce con sicurezza andranno
in `da_controllare.csv`.

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
  nessun annuncio** e non tocca i CSV veri. Anche in simulazione l'AI viene
  chiamata davvero (costa pochi centesimi per 20 foto), e i risultati restano
  salvati: il lancio vero non la richiama per le stesse foto. Scrive tutto in
  `risultati/simulazione/`:
  - `inventario_001.csv`: quello che andrebbe nel caricamento;
  - `annunci_api_simulati.csv`: gli annunci che verrebbero pubblicati via API.

Guarda anche `risultati/riconoscimento.csv`, con come è stata riconosciuta ogni
foto, e `risultati/da_controllare.csv`.

### Lancio vero

```bash
caffeinate -i python3 vendi.py ~/Pictures/Dischi
```

Con premi diversi, per esempio +30% con 3-5 copie in vendita:

```bash
caffeinate -i python3 vendi.py ~/Pictures/Dischi --premio-alcune-copie 30
```

Per creare tutti gli annunci **in bozza** e controllarli su Discogs prima di
metterli in vendita:

```bash
caffeinate -i python3 vendi.py ~/Pictures/Dischi --bozza
```

Quando le hai controllate, le metti in vendita tutte insieme con
`pubblica_bozze.py` (vedi "Mettere in vendita le bozze" più sotto).

**Tempi:** lo script fa al massimo 60 richieste al minuto a Discogs, come
impone il limite dell'API. Con 10.000 dischi conta diverse ore. Puoi
interromperlo quando vuoi con **Ctrl+C**: rilanciando lo stesso comando
riparte da dove era. Le foto già riconosciute non vengono rianalizzate e gli
annunci già pubblicati non vengono mai ripubblicati.

### Mettere in vendita le bozze (`pubblica_bozze.py`)

Mette in vendita (`For Sale`), via API, **tutte le bozze create da
`vendi.py --bozza`**: quelle dei CSV di inventario (dopo che li hai caricati
su Discogs) e quelle create via API.

```bash
caffeinate -i python3 pubblica_bozze.py
```

1. Cerca nel tuo inventario Discogs le bozze create dallo script (le
   riconosce dall'`external_id`, cioè il nome della foto). Le altre bozze
   del tuo inventario non vengono toccate.
2. Ti mostra **quante bozze sta per mettere in vendita** (quante dai CSV e
   quante create via API), il totale dei prezzi, le prime 10 e il tempo
   stimato.
3. **Chiede conferma**: scrivi `s` e premi Invio per procedere. Qualsiasi
   altra risposta annulla senza toccare nulla.
4. Le mette in vendita una per una e alla fine dice quante ci sono riuscite
   e quali no, con il motivo.

Cose da sapere:

- Prezzo e gradi sono quelli che l'annuncio ha **in quel momento su
  Discogs**: se in bozza hai cambiato qualcosa a mano, resta la tua modifica.
- Le bozze che hai già messo in vendita o cancellato a mano vengono saltate,
  come le righe dei CSV non ancora caricati su Discogs.
- Una riga del CSV con `quantity` 3 diventa su Discogs 3 annunci: vengono
  contati e messi in vendita tutti e 3.
- Puoi interromperlo con **Ctrl+C** e rilanciarlo: riparte dalle bozze
  rimaste, senza doppioni. Lo stesso vale per quelle non riuscite.
- Va al ritmo di 60 richieste al minuto: 1.000 bozze richiedono circa 18
  minuti.
- Aggiorna `annunci_pubblicati_api.csv` (colonna `status`). I CSV di
  inventario invece non cambiano: restano quelli che hai caricato.

### Regola del prezzo

Vale per **tutti** i dischi. Lo script usa, per ogni release, i dati del
marketplace Discogs: copie in vendita, prezzo più basso, want/have.

**1. Base** = **prezzo più basso attualmente in vendita**, ma **mai sotto il
prezzo suggerito** da Discogs per il grado del disco, che fa da soglia minima.
Se non ci sono copie in vendita, la base è il prezzo suggerito.

**2. Premio scarsità**, in base al numero di copie in vendita:

| Copie in vendita | Premio |
| --- | --- |
| 0 | prezzo suggerito per il grado **+100%** |
| 1-2 | base **+50%** |
| 3-5 | base **+25%** |
| oltre 5 | nessun premio |

**3. Premio richiesta:** se il rapporto **want/have** (quanti lo cercano /
quanti lo hanno) è **sopra 1**, **+10%**.

**I premi si sommano**, e non c'è un tetto massimo:

> prezzo = base × (1 + premio scarsità + premio richiesta)

Esempi:

| Situazione | Calcolo | Prezzo |
| --- | --- | --- |
| suggerito 24,20; più basso 50,00; 2 copie; want/have 3 | 50,00 × (1 + 50% + 10%) | 80,00 |
| suggerito 64,10; nessuna copia; want/have 6 | 64,10 × (1 + 100% + 10%) | 134,61 |
| suggerito 32,10; più basso 40,00; 4 copie; want/have 0,05 | 40,00 × (1 + 25%) | 50,00 |
| suggerito 13,10; più basso 8,00; 40 copie | 13,10 (soglia minima) | 13,10 |

**Valute:** tutti i prezzi sono nella **valuta del tuo account venditore**,
che lo script legge da Discogs all'avvio. I prezzi suggeriti arrivano già in
quella valuta. Il prezzo più basso in vendita viene chiesto a Discogs
convertito nella stessa valuta, quindi è Discogs a fare la conversione.

**Il calcolo è sempre visibile:** la colonna `calcolo_prezzo` nei file dei
risultati riporta suggerito, prezzo più basso, base, copie in vendita,
want/have, premi applicati e conto finale. Per esempio:

```
suggerito NM 24,20; più basso in vendita 50,00; base = più basso in vendita 50,00;
2 copie in vendita (1-2) +50%; want/have 300/100 = 3,00 > 1 +10%;
prezzo = 50,00 × (1 + 60%) = 80,00 EUR
```

La colonna si trova in `inventario_foto.csv`, `annunci_pubblicati_api.csv` e
`collezionistici.csv`. Non la aggiungo ai file `inventario_NNN.csv` da caricare
su Discogs, che devono contenere solo le colonne previste da Discogs.

**Tutte le percentuali e le soglie sono configurabili:**

| Opzione | Default | Cosa regola |
| --- | --- | --- |
| `--premio-zero-copie` | 100 | premio % sul suggerito con 0 copie in vendita |
| `--copie-poche` | 2 | fino a quante copie sono "poche" |
| `--premio-poche-copie` | 50 | premio % con poche copie |
| `--copie-alcune` | 5 | fino a quante copie sono "alcune" |
| `--premio-alcune-copie` | 25 | premio % con alcune copie |
| `--soglia-want-have` | 1 | rapporto want/have oltre il quale scatta il premio richiesta |
| `--premio-richiesta` | 10 | premio richiesta % |

Attenzione: il prezzo più basso in vendita è quello di una copia qualsiasi, in
qualunque grado. Per un disco in grado basso la base può quindi risultare alta.
Controlla la colonna `calcolo_prezzo` prima di caricare il CSV.

**Tempi:** servono 2 richieste per ogni release diversa (dati della release e
statistiche del marketplace), oltre a quella del prezzo suggerito, sempre entro
il limite di 60 al minuto. Tutti i dati restano in cache: ogni release viene
chiesta una volta sola, anche tra un'esecuzione e l'altra.

### Dischi collezionistici (`collezionistici.csv`)

Oltre al prezzo, lo script calcola un **punteggio collezionistico**, che serve
solo a segnalarti i dischi di valore: **non cambia il prezzo**.

| Dato | Punti |
| --- | --- |
| want/have ≥ 3 / ≥ 1,5 / ≥ 0,8 | +3 / +2 / +1 |
| nessuna copia in vendita / 1-3 copie | +2 / +1 |
| prezzo più basso in vendita sopra la soglia (default 50) | +1 |
| Test Pressing (dai formati nel database locale) | +3 |
| Numbered | +2 |
| Limited Edition, Promo (anche "White Label"), First Press, vinile colorato | +1 ciascuno |
| prezzo suggerito sopra la soglia (default 50) | +2 |

- Want/have e copie in vendita contano qui solo se almeno 20 persone cercano
  il disco.
- Con **punteggio ≥ 4** il disco è elencato in
  `risultati/collezionistici.csv`, ordinato per punteggio, con i motivi, il
  prezzo e il calcolo del prezzo.
- Soglie: `--soglia-prezzo 80`, `--soglia-collezionistico 5`.

### Costi dell'AI e tetto di spesa

- **Solo quando serve:** l'AI viene chiamata solo per le foto che la parte
  locale non riconosce con sicurezza. Ogni foto costa una o due chiamate:
  lettura ed eventuale scelta.
- **Foto ridotte:** prima dell'invio le foto vengono ridotte a 1568 pixel sul
  lato lungo e compresse in JPEG.
- **Cache:** il risultato dell'AI per ogni foto viene salvato e **non viene mai
  richiesto di nuovo**, nemmeno con `--riprova` o se lo script si interrompe.
  Si rianalizza solo una foto sostituita con uno scatto nuovo.
- **Costo per disco:** registrato in `risultati/riconoscimento.csv` (colonna
  `costo_ai_eur`); a fine esecuzione vedi la spesa dell'esecuzione e quella
  totale.
- **Tetto di spesa totale** (default **50 €**, sommando tutte le esecuzioni).
  Prima di ogni chiamata lo script controlla che il costo massimo previsto
  stia sotto il tetto. Se non ci sta, **si ferma e lo segnala**. Le foto già
  riconosciute vengono comunque messe in vendita; per continuare rilancia con
  un tetto più alto:

```bash
caffeinate -i python3 vendi.py ~/Pictures/Dischi --ai-tetto 80
```

- **Stima:** con il modello di default, `claude-haiku-4-5` (il più economico:
  1 $ per milione di token in ingresso, 5 $ in uscita), circa **0,5-1
  centesimo a foto** che ha bisogno dell'AI. Se servisse per tutte le 10.000
  foto, sarebbero circa 50-100 €; di solito meno, perché molte si riconoscono
  in locale. La stima è calcolata dai prezzi, non misurata sulle tue foto:
  guarda la spesa reale dopo la prova con `--limite 20`.
- **Il tetto conta 1 $ = 1 €** (Anthropic fattura in dollari), quindi la spesa
  reale in euro è un po' più bassa del tetto.
- **Modello più preciso:** `--ai-modello claude-sonnet-5` costa circa il
  doppio, `claude-opus-5` circa 5 volte.

### I risultati (cartella `risultati/`)

| File | Cosa contiene |
| --- | --- |
| `inventario_001.csv`, `inventario_002.csv`… | Dischi trovati in locale, al massimo 1.000 dischi per file (le copie contano), da caricare su Discogs |
| `inventario_foto.csv` | Per ogni riga dei CSV di inventario: tutte le foto (copie) che contiene, il prezzo e il **calcolo del prezzo** |
| `collezionistici.csv` | Dischi collezionistici, ordinati per punteggio, con motivi, prezzo suggerito, prezzo più basso in vendita, prezzo finale e calcolo |
| `riconoscimento.csv` | Per ogni foto: esito, metodo (es. `locale-barcode`, `ai-scelta+locale`), disco trovato, sicurezza e motivo della scelta AI, costo AI in euro |
| `annunci_pubblicati_api.csv` | Annunci pubblicati via API, uno per foto, con calcolo del prezzo e link |
| `da_controllare.csv` | Foto da sistemare a mano: nome della foto, cartella, motivo, dettagli letti e candidati |

I CSV di inventario hanno le colonne `release_id`, `price`, `media_condition`,
`sleeve_condition`, `quantity`, `external_id` e `status`: `FOR_SALE`, oppure
`DRAFT` se hai lanciato lo script con `--bozza` (sono i due valori indicati
dalla guida di Discogs per il caricamento CSV). Anche `inventario_foto.csv` e
`annunci_pubblicati_api.csv` hanno una colonna `status`, così vedi quali
annunci sono in bozza.

- Lo stato di una riga resta quello con cui è stata scritta la prima volta:
  lanciare più tardi lo script con o senza `--bozza` non cambia le righe (né
  gli annunci) già creati, solo quelli nuovi.

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

- **non trovato né nel database locale né su Discogs**: nemmeno con l'AI si è
  trovato un disco reale coerente con la foto. La colonna `dettagli` dice cosa
  hanno letto l'OCR e l'AI e perché è stato scartato, per esempio "nessun
  candidato coerente con la foto" o "l'AI non ha trovato il disco tra i
  candidati".
- **più release possibili**: capita solo con `--senza-ai`. Più stampe
  compatibili che non si sono potute distinguere; i candidati sono ordinati per
  punteggio.
- **nessun prezzo suggerito da Discogs**.
- **pubblicazione non confermata**: lo script si è interrotto proprio durante
  la pubblicazione e non è riuscito a verificare se l'annuncio esiste.
  Controlla su Discogs cercando l'`external_id` (es. `IMG_1234`).
- **Discogs ha rifiutato l'annuncio**, con il messaggio di Discogs.

Consiglio: in `riconoscimento.csv` guarda le righe con `sicurezza_ai` **bassa**.
Sono dischi identificati, ma di cui l'AI ha scelto la stampa più probabile.

Se sostituisci una foto finita da controllare con uno scatto migliore (stesso
nome), al prossimo lancio viene rianalizzata da sola. Per rifare la parte
locale su tutte le foto da controllare (i risultati AI già pagati vengono
riusati):

```bash
caffeinate -i python3 vendi.py ~/Pictures/Dischi --riprova
```

### Opzioni di `vendi.py`

| Opzione | Cosa fa |
| --- | --- |
| `--premio-zero-copie`, `--copie-poche`, `--premio-poche-copie`, `--copie-alcune`, `--premio-alcune-copie`, `--soglia-want-have`, `--premio-richiesta` | Regola del prezzo, vedi la tabella nella sezione "Regola del prezzo" |
| `--soglia-prezzo 80` | Per `collezionistici.csv`: prezzo oltre il quale un disco conta come di valore (default 50, valuta del tuo account) |
| `--soglia-collezionistico 5` | Per `collezionistici.csv`: punteggio minimo (default 4) |
| `--limite N` | Elabora solo le prime N foto |
| `--bozza` | Crea gli annunci in bozza (`Draft`) invece che in vendita (`For Sale`), sia nel CSV di inventario sia via API |
| `--simula` | Non pubblica annunci e non tocca i CSV veri; scrive in `risultati/simulazione/` |
| `--riprova` | Rianalizza le foto finite da controllare |
| `--ai-tetto 80` | Spesa AI massima in euro, sommando tutte le esecuzioni (default 50); raggiunta, lo script si ferma |
| `--ai-modello NOME` | `claude-haiku-4-5` (default), `claude-sonnet-5` o `claude-opus-5` |
| `--senza-ai` | Non usa l'AI: solo riconoscimento locale gratuito |
| `--uscita PERCORSO` | Cartella dei risultati (default `risultati/`) |
| `--db PERCORSO` | Database creato da `discogs_dump.py` (default `data/discogs.sqlite`) |

### Dove sta lo stato

I progressi (foto riconosciute, risultati dell'AI e relativo costo, prezzi ottenuti, dati collezionistici, righe CSV, annunci creati e bozze messe in vendita) sono in
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
