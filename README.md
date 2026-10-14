# Discogs: database locale e messa in vendita

Gli script:

- **`discogs_dump.py`**: scarica il dump mensile delle release di Discogs e lo
  importa in un database SQLite locale (`data/discogs.sqlite`), con indici su
  barcode, numero di catalogo e parole di artista e titolo.
- **`rinomina_foto.py`**: rinomina le foto nuove con data e ora di scatto
  (`20261013_154233_IMG_2087.HEIC`), così due telefoni non producono mai due
  foto con lo stesso nome.
- **`raggruppa_foto.py`**: divide le foto sciolte (fronte, retro, etichetta
  di più dischi) in sottocartelle `disco-001`, `disco-002`… una per disco,
  in base alle pause tra gli scatti.
- **`vendi.py`**: riconosce i dischi da una foto qualsiasi (fronte, retro o
  etichetta), senza interventi manuali, calcola il prezzo dai dati del
  marketplace Discogs e prepara la vendita. I dischi trovati nel
  database locale finiscono nei CSV di caricamento dell'inventario. Quelli
  trovati solo via API vengono pubblicati direttamente via API. Con `--bozza`
  tutti diventano bozze via API.
- **`verifica_inventario.py`**: controlla cosa è davvero online su Discogs
  (dopo aver caricato un CSV) e lo salva nello stato.
- **`pubblica_bozze.py`**: mette in vendita, in blocco e dopo la tua conferma,
  le bozze che `vendi.py --bozza` ha creato via API.
- **`riprezza.py`**: una volta al mese ricontrolla il mercato per i tuoi
  annunci in vendita e propone prezzi nuovi, **solo al rialzo**.
- **`verifica_modifica_annuncio.py`**: verifica su un solo annuncio che la
  modifica via API non azzeri commenti, external_id e gli altri campi.

**Flusso consigliato per ogni lotto:**

1. `python3 rinomina_foto.py ~/Pictures/Dischi` (foto nuove con nomi unici), oppure, se fotografi
   più lati di ogni disco, `python3 raggruppa_foto.py ~/Desktop/scatti --grado VG+ --destinazione
   ~/Pictures/Dischi` (una sottocartella per disco);
2. `caffeinate -i python3 vendi.py ~/Pictures/Dischi` (CSV + annunci API);
3. carica i nuovi `risultati/inventario_NNN.csv` su Discogs;
4. `python3 verifica_inventario.py` (cosa è davvero online, righe scartate).

Ogni script che modifica lo stato ne fa prima una copia in `data/backup/`.

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
  `VG`, `G+`, `G`. Il grado della cartella vale sia per il disco sia per la
  copertina;
- **disco e copertina con gradi diversi:** chiama la cartella
  `DISCO_COPERTINA`, es. `M_NM` (disco Mint, copertina Near Mint), `VG+_VG`,
  `NM_VG+`. Nel CSV e negli annunci API `media_condition` è il primo grado e
  `sleeve_condition` il secondo. Il **prezzo** resta calcolato sul grado del
  **disco**. Maiuscole e minuscole non contano (`m_nm` va bene); ogni parte
  deve essere uno dei sei gradi, altrimenti (es. `M_XX`, `M_NM_VG`) lo script
  si ferma con l'elenco dei nomi ammessi. Vale anche per le sottocartelle per
  disco (`lotto-02/M_NM/disco-001/…`) e per `raggruppa_foto.py --grado M_NM`;
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
  M_NM/
    IMG_1238.HEIC   ← disco Mint, copertina Near Mint
```

- **L'external_id è il nome della foto senza estensione** (es. `IMG_1234`). È
  un campo privato su Discogs: quando un disco si vende, ti dice quale foto
  corrisponde.
- **Copie:** le foto riconosciute come la **stessa release con lo stesso
  grado** (di disco e di copertina) vengono unite in un unico annuncio, con quantità pari al numero di
  foto.
- **Controlli all'avvio.** Lo script si ferma subito se trova una cartella che
  non è un grado, o due foto con lo stesso nome in cartelle diverse (avrebbero
  lo stesso external_id: rinominane una).
- **Più foto dello stesso disco:** mettile in una sottocartella del grado
  (vedi "Più foto per disco: una sottocartella per disco" più sotto).

### Più foto per disco: una sottocartella per disco

Una foto da sola spesso non basta (il fronte ha artista e titolo, il retro il
barcode, l'etichetta il catalogo). Dentro una cartella di grado, **una
sottocartella (qualsiasi nome) è UN disco**: tutte le sue foto sono lo stesso
disco, quantità 1.

```
lotto-02/
  VG+/
    disco-001/
      fronte.jpg
      retro.jpg
      etichetta.jpg
    disco-002/
      IMG_2104.HEIC
      IMG_2105.HEIC
      copie-2          ← file vuoto: 2 copie identiche di questo disco
    IMG_2110.HEIC      ← foto sciolta: funziona come prima (una foto = un disco)
```

- **Riconoscimento sul disco, non sulla foto.** Barcode e OCR si leggono su
  tutte le foto della sottocartella e gli indizi si uniscono: un barcode o un
  catalogo esatto trovato in **una qualsiasi** foto basta. Se serve l'AI, parte
  **una sola chiamata** con tutte le foto del disco (al massimo
  `--ai-max-foto`, default 4, ridotte come sempre), con il prompt che spiega
  che sono lati diversi dello stesso vinile; lo stesso per il secondo
  tentativo. Il costo di tutte le immagini è stimato e contato nel tetto.
- **Foto in contrasto.** Se in foto diverse della stessa sottocartella ci sono
  codici che portano a release diverse e incompatibili (es. il barcode di un
  disco e il catalogo di un altro), il disco va in `da_controllare.csv` con
  motivo "foto della cartella in contrasto", che elenca foto, codice e release
  (senza spendere per l'AI).
- **Tutte le protezioni restano:** solo vinile, verifica finale del
  riconoscimento, compilation, soglia di controllo, collezionistici, release
  bloccate.
- **external_id** del disco = `<nome sottocartella>-<impronta breve del
  contenuto delle foto>`, es. `disco-001-3f2a9c1e`: due lotti con
  `disco-001` non si scontrano mai. Nei risultati (`da_controllare.csv`,
  `non_vendibili.csv`, `collezionistici.csv`, `riconoscimento.csv`) il disco
  compare come `VG+/disco-001 (3 foto)`; nel CSV di inventario con il suo
  external_id.
- **Copie.** Il modo sicuro è un file vuoto `copie-2` (o `copie-3`…) nella
  sottocartella. Via API (es. con `--bozza`) si crea un annuncio per copia:
  `disco-002-…`, `disco-002-…-copia2`.
- **Due sottocartelle con la stessa release e lo stesso grado** si fermano in
  `da_controllare.csv` (motivo "stesso disco"): dalle foto non si capisce se
  sono due copie o lo stesso disco fotografato due volte (lotto-05: disco-013
  e disco-019). Se è lo stesso disco togli dal lotto la cartella in più e
  rilancia; se sono copie diverse rilancia con
  `--copie-diverse disco-013,disco-019`.
- **`--togli disco-019-847f678b`** (anche più nomi separati da virgola, o solo
  l'inizio del nome se univoco): toglie un disco già finito in una riga CSV
  NON ancora caricata. La riga viene tolta dal suo `inventario_NNN.csv` (la
  versione di prima resta in `risultati/archivio/`), il disco non si elabora
  più, e le altre copie della riga tornano da elaborare al prossimo lancio, in
  un file CSV nuovo, senza rifare il riconoscimento. Si rifiuta su righe già
  viste online e su annunci via API: lì si corregge su Discogs.
- **Stessa foto due volte** (in due sottocartelle, o una foto aggiunta a un
  disco già elaborato): lo script si ferma prima di elaborare, come per i nomi
  ripetuti. Non aggiungere né togliere foto a un disco già messo in vendita.
- Il controllo sugli scatti ravvicinati ("Fronte e retro dello stesso disco")
  **non** si applica alle sottocartelle: lì le foto sono già dello stesso disco.
- Nel riepilogo finale: dischi elaborati, foto totali, e quanti dischi sono
  stati riconosciuti al primo colpo (senza AI), con l'AI, con il secondo
  tentativo.

**Creare le sottocartelle in automatico: `raggruppa_foto.py`.** Fotografa i
dischi uno dopo l'altro (fronte, retro, etichetta), con una pausa tra un disco
e il successivo, e metti tutte le foto in una cartella. Poi:

```bash
python3 raggruppa_foto.py ~/Desktop/scatti --grado VG+ --destinazione ~/Desktop/lotto-02 --simula
python3 raggruppa_foto.py ~/Desktop/scatti --grado VG+ --destinazione ~/Desktop/lotto-02
```

- Ordina le foto per data di scatto (**solo** EXIF `DateTimeOriginal`, anche
  HEIC); un nuovo disco inizia quando tra due scatti consecutivi passano più di
  `--pausa` secondi (default 20).
- Se una foto non ha la data di scatto (es. passata da WhatsApp) **si ferma** e
  la nomina, senza spostare niente: niente date di modifica inventate.
- Prima mostra l'anteprima (`disco-001: 3 foto, 12:04:10-12:04:31 (…)`) e i
  gruppi sospetti: più di 4 foto (forse due dischi) o 1 sola foto. Poi chiede
  conferma e **sposta** (non copia) le foto in
  `<destinazione>/<grado>/disco-NNN`; la numerazione continua dopo le
  sottocartelle `disco-NNN` già presenti. Con `--simula` mostra solo
  l'anteprima.
- `--grado` accetta anche `DISCO_COPERTINA`: `--grado M_NM` crea
  `<destinazione>/M_NM/disco-NNN`.
- Controlla sempre i gruppi sospetti prima di lanciare `vendi.py`.

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

**Secondo tentativo con un modello più forte.** Se dopo il modello principale
(`claude-haiku-4-5`) una foto resta non trovata o con più release possibili,
lo script riprova una volta con `claude-sonnet-5-5` (`--ai-modello-secondo`),
con lo stesso tetto di spesa e le stesse protezioni. Il risultato resta in
cache come il primo: non si paga mai due volte. `--senza-secondo-tentativo`
lo disattiva.

**Solo vinile.** Il disco fotografato è sempre un vinile. In tutta la
cascata (barcode, catalogo, artista e titolo, AI, secondo tentativo) i
candidati sono solo release che hanno **Vinyl** tra i formati, nel dump locale
o su Discogs: le release solo CD, Cassette, File, DVD… vengono scartate prima
di qualsiasi scelta (era il caso di Francisco – Music Business, abbinato alla
versione CD 568083 invece che all'LP 572658). Una release con più formati
(es. Vinyl + CD) va bene perché contiene Vinyl. Anche all'AI viene detto che
è sempre un vinile. Per allargare in futuro: `--formati-ammessi "Vinyl,CD"`.

**Regola di sicurezza: l'AI non può inventare.**
- La release scelta deve sempre esistere nel database o su Discogs: l'AI può
  solo scegliere tra i candidati trovati dallo script.
- Artista e titolo della release devono combaciare con quelli letti o
  riconosciuti nella foto.
- Tutto ciò che non passa questi controlli va in `da_controllare.csv`.

**Scalette e compilation.** Il disco si riconosce dalle scritte
**principali**: artista e titolo in grande su copertina o etichetta, il numero
di catalogo del disco, il barcode.
- Le righe di una scaletta (`A1 …`, `C2. Artista - Brano`) e i riferimenti come
  `From the album 'Mirage' BJQD/15 [1973]` **non sono il disco**: parlano degli
  album da cui vengono i brani. Lo script non usa mai i loro numeri di catalogo,
  e anche all'AI viene detto di non usarli come artista, titolo o catno.
- Se la scaletta ha artisti diversi tra loro, il disco è probabilmente una
  **compilation**: va cercato con artista e titolo dell'intestazione.

**Verifica finale dei riconoscimenti senza codice.** Quando il disco è stato
riconosciuto dall'**AI** o per **artista e titolo** (`locale-testo`), e non
da un barcode o da un numero di catalogo esatto, la release scelta viene
controllata ancora una volta:
- l'artista della release deve comparire tra le **scritte principali** lette
  nella foto (non importano maiuscole, accenti, trattini). Un artista scritto
  in un altro alfabeto (es. cirillico) non si può confrontare e non passa;
- `Various` è ammesso solo se la foto mostra una **compilation** (lo dice
  l'AI, c'è scritto, o la scaletta ha almeno 3 artisti diversi);
- artista e titolo della release non devono essere una **riga della
  scaletta**, né il titolo un "From the album" citato nella foto;
- il riconoscimento **non può basarsi su una sola parola**.

Se un controllo non passa, il disco **non va né nel CSV né via API**: finisce
in `da_controllare.csv`, con la release proposta e il motivo.

**Rete di sicurezza sui prezzi.** Un disco riconosciuto senza barcode o
catalogo esatto (AI o `locale-testo`) che risulta **collezionistico**, oppure
con prezzo finale **sopra la soglia di controllo** (default 100, nella valuta
del tuo account, da cambiare con `--soglia-controllo`), non va in vendita: va in
`da_controllare.csv` con il prezzo calcolato, per essere verificato a mano.
I dischi riconosciuti con barcode o catalogo esatto vanno in vendita come
prima, qualunque sia il prezzo.

In `da_controllare.csv` finisce solo ciò che nemmeno così si riesce a
identificare.

**Quando nella parte locale escono più release possibili** (per esempio lo
stesso album stampato in più paesi), lo script dà un punteggio a ciascuna con
gli altri dati letti nella foto: artista e titolo (fino a 1), catno (+0,30),
etichetta (+0,15), anno (+0,10), paese (+0,05). La considera sicura solo con
almeno 0,15 punti di distacco dalla seconda; altrimenti decide l'AI.

**Poi, come prima:**
- **Raggruppa** le foto con la stessa release e lo stesso grado.
- **Controlla che la release si possa vendere.** Discogs blocca dal
  marketplace alcune release (white label, bootleg, release non ufficiali): il
  CSV le scarta ("release is blocked from the marketplace") e l'API le
  rifiuta. Prima del prezzo lo script chiede a Discogs la release
  (`GET /releases/{id}`, campo `blocked_from_sale`):
  - **bloccata** → niente prezzo, niente statistiche di mercato, niente
    annuncio: va in `non_vendibili.csv`. Resta salvata nello stato
    (`non_vendibile`): ai giri successivi viene saltata senza richieste a
    Discogs. Con `--rielabora` viene ricontrollata;
  - **impossibile verificare** (rete, errore di Discogs, campo assente nella
    risposta) → **non** va in vendita: finisce in `da_controllare.csv` con
    motivo "impossibile verificare se è vendibile" e viene ricontrollata al
    lancio successivo;
  - **vendibile** → si prosegue come prima. La stessa risposta serve anche per
    want/have, quindi non costa richieste in più.
  - L'esito resta in cache per release: una sola richiesta per release, nel
    rispetto del limite di 60 richieste al minuto.
  - Se nel database locale la release ha il formato **Unofficial Release**,
    lo script lo segnala già nel riconoscimento ("probabilmente non
    vendibile"), ma decide sempre la risposta di Discogs.
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

- **Discogs ignora `DRAFT` nei CSV**: una riga caricata con status DRAFT va
  subito in vendita. Per questo con `--bozza` **nessun disco va nel CSV**:
  tutti diventano bozze vere **via API**, un annuncio per foto (l'API non ha
  il campo quantità). Senza `--bozza` il CSV resta come sempre, con `FOR_SALE`.
  Nessun CSV contiene più `DRAFT`.
- Con migliaia di bozze serve tempo: una richiesta per foto, al massimo 60 al
  minuto.

Quando le hai controllate, le metti in vendita tutte insieme con
`pubblica_bozze.py` (vedi "Mettere in vendita le bozze" più sotto).

### Dopo il caricamento del CSV: `verifica_inventario.py`

Per lo script "riga nel CSV" non vuol dire "online": il CSV potrebbe non
essere mai stato caricato, o Discogs potrebbe aver scartato delle righe (per
esempio le release bloccate). Dopo ogni caricamento lancia:

```bash
python3 verifica_inventario.py
```

1. Fa un backup dello stato e scarica **tutto il tuo inventario** Discogs,
   tutte le pagine: in vendita, bozze e, se Discogs li restituisce, scaduti.
2. **Legge i tuoi ordini** (tutte le pagine, tutti gli stati). L'inventario
   **non mostra i dischi venduti**: senza gli ordini un disco venduto sembrerebbe
   uguale a uno rimosso a mano o mai caricato. Un annuncio che compare in un
   ordine **non annullato** è venduto. Il collegamento è l'**id dell'annuncio**
   di ogni articolo dell'ordine (e l'external_id, se Discogs lo restituisce).
3. Per ogni riga dei CSV e ogni annuncio API salva nello stato com'è:

   | Stato | Cosa vuol dire | Si può liberare? |
   | --- | --- | --- |
   | in vendita / in bozza | online su Discogs | no |
   | **venduto** | un suo annuncio è in un ordine non annullato; resta venduto per sempre | **mai** |
   | **forse venduto** | la release è in un ordine, ma questo annuncio non è mai stato visto online | no (controlla a mano) |
   | **bloccata da Discogs** | la release è bloccata dal marketplace: Discogs l'ha scartata | no (non servirebbe) |
   | non online | mai visto su Discogs: CSV mai caricato o riga scartata | sì |
   | bozza cancellata | era una bozza e non c'è più (una bozza non si vende) | sì |
   | rimosso a mano | era in vendita e non è in nessun ordine | sì |
   | sparito | era in vendita e non c'è più, ma gli ordini non si sono potuti leggere | no |

4. Corregge lo status delle righe caricate come DRAFT: su Discogs sono in
   vendita.
5. Stampa il riepilogo — **in vendita / in bozza / venduti / bloccati da
   Discogs / non online per altri motivi** (rimossi a mano, CSV mai caricati…)
   — con il dettaglio per file CSV. Lo stesso, riga per riga, è in
   `risultati/verifica_inventario.csv` (colonne `gruppo`, `online`,
   `liberabile`).

Le righe liberabili si possono **liberare**: le loro foto tornano elaborabili
al prossimo `vendi.py`, senza rifare il riconoscimento e senza pagare di nuovo
l'AI.

```bash
python3 verifica_inventario.py --libera                  # tutte le liberabili
python3 verifica_inventario.py --libera-solo IMG_2087    # solo questa (ripetibile)
```

- Mostra le righe che sta per liberare e chiede conferma (`s`).
- **Non libera mai un disco venduto** (né forse venduto, né sparito), né una
  release bloccata da Discogs. Con `--libera-solo` ti dice perché una riga
  indicata non si libera.
- **Se gli ordini non si leggono** (rete, errore di Discogs, o articoli senza id
  dell'annuncio) `--libera` e `--libera-solo` **non partono**: senza ordini non
  si distingue un venduto. Lo stesso vale per `vendi.py --rielabora`, che in quel
  caso non tocca nessuna riga CSV né annuncio.
- **Non cancella mai un file CSV**: un file rimasto senza righe va in
  `risultati/archivio/inventario_NNN_ANNULLATO.csv` (non caricarlo), uno che
  perde solo alcune righe viene prima copiato in archivio
  (`inventario_NNN_PRIMA_<data>.csv`) e poi riscritto.
- Se l'inventario non si legge (rete, errore di Discogs) si ferma senza
  modificare niente.

### Nomi delle foto: `rinomina_foto.py`

Il nome della foto è l'`external_id`. Con due telefoni, o quando il
contatore dell'iPhone ricomincia, due foto diverse possono chiamarsi entrambe
`IMG_2087`. `vendi.py` ora se ne accorge: salva un'**impronta del contenuto**
(SHA-256) di ogni foto e, **prima di elaborare qualsiasi foto**, si ferma e
mostra i conflitti se trova:

- un nome già usato da una foto **diversa**;
- la **stessa foto con due nomi** (andrebbe in vendita due volte).

La stessa foto spostata in un'altra cartella invece viene riconosciuta come la
stessa: niente da rifare, nessun costo AI.

Per evitare i conflitti, rinomina ogni lotto nuovo prima di `vendi.py`:

```bash
python3 rinomina_foto.py ~/Pictures/Dischi
```

- Nuovo nome: `AAAAMMGG_HHMMSS_<nome originale>`, con la **data di scatto
  EXIF** (anche dalle HEIC). Se manca (foto passate da WhatsApp o simili) usa
  la data del file e lo segnala.
- Mostra l'anteprima e rinomina solo dopo conferma (`s`).
- **Non tocca mai le foto già presenti nello stato**: il loro nome è
  l'external_id di annunci già creati.

### Fronte e retro dello stesso disco

Le foto della stessa release con lo stesso grado sono copie dello stesso
disco. Ma se hai fotografato fronte e retro di **un** disco diventerebbero
"x2". Quando un gruppo ha 2 o più foto, lo script legge la **data di scatto
EXIF**: se due foto sono state scattate a meno di **90 secondi**
(`--secondi-stesso-disco`), tutto il gruppo va in `da_controllare.csv` con
"probabilmente lo stesso disco fotografato più volte". Togli la foto in più e
rilancia: il disco va in vendita.

- La data usata è **solo** `DateTimeOriginal` (la data di scatto), e lo
  script stampa per ogni foto del gruppo quale data ha usato. **Nessun'altra
  data**: il tag `DateTime` è la data di modifica, che le app di messaggistica
  riscrivono uguale per tutte le foto (da qui gli "scatti a 0 secondi" del
  primo lotto), e la data del file con AirDrop è uguale per tutte.
- Senza `DateTimeOriginal` le foto si contano come copie diverse e lo script
  stampa l'avviso "data di scatto mancante".
- Se fotografi davvero più copie dello stesso disco una dopo l'altra, usa
  `--copie-consecutive`.

**Stesso artista e titolo, release diverse.** Se nello stesso giro due o più
foto finiscono su release **diverse** con lo stesso artista e titolo (confronto
tollerante a maiuscole, accenti, punteggiatura), quasi sempre sono lo stesso
disco fotografato più volte e riconosciuto in due modi (es. LP e CD). Vanno
tutte in `da_controllare.csv` con motivo "stesso artista e titolo su release
diverse (es. LP e CD)", prima di qualsiasi richiesta a Discogs. Togli la foto
in più e rilancia. Attenzione: vale anche per due stampe diverse dello stesso
album che possiedi davvero (es. originale e ristampa): in quel caso mettile in
vendita in due giri separati.

**Ripetere un test sulle stesse foto (`--rielabora`).** Di norma le foto già
elaborate non vengono rianalizzate. Per rifare tutto da capo sulle foto della
cartella indicata (riconoscimento, AI compresa, prezzo e annuncio):

```bash
caffeinate -i python3 vendi.py ~/Pictures/Dischi --limite 9 --bozza --rielabora
```

- Funziona **solo insieme a `--bozza`**: senza, lo script si rifiuta di
  partire. Così gli annunci ricreati sono sempre bozze, mai doppioni in vendita.
- Non si può usare con `--simula`, perché cambia lo stato vero.
- **Prima di tutto legge il tuo inventario e i tuoi ordini Discogs.** Una foto
  il cui external_id è online (in vendita, in bozza), venduto, o che era in
  vendita e potrebbe essere stato venduto viene **saltata**: un CSV caricato è
  in vendita anche se diceva DRAFT. Se inventario o ordini non si leggono,
  nessuna riga CSV né annuncio viene toccato e lo script lo dice: si
  rielaborano solo le foto mai messe in vendita.
- Le righe CSV e gli annunci di quelle foto vengono tolti dallo stato (una
  copia resta nella tabella `rielaborati`) e ricreati come bozze. I file CSV
  non vengono mai cancellati: vanno in `risultati/archivio/` (vedi sotto) e i
  file nuovi non riprendono mai il nome di uno vecchio.
- L'AI viene **pagata di nuovo** per ogni foto (usa il nuovo prompt); la spesa
  delle esecuzioni precedenti resta contata nel tetto.
- Per rifare una foto che è già una bozza su Discogs, cancella prima la bozza
  da Discogs: a quel punto risulta "bozza cancellata" e si può rielaborare.

**Tempi:** lo script fa al massimo 60 richieste al minuto a Discogs, come
impone il limite dell'API. Con 10.000 dischi conta diverse ore. Puoi
interromperlo quando vuoi con **Ctrl+C**: rilanciando lo stesso comando
riparte da dove era. Le foto già riconosciute non vengono rianalizzate e gli
annunci già pubblicati non vengono mai ripubblicati.

### Mettere in vendita le bozze (`pubblica_bozze.py`)

Mette in vendita (`For Sale`), via API, **tutte le bozze create da
`vendi.py --bozza`**. Le bozze esistono solo via API: le righe dei CSV
caricati sono già in vendita (Discogs ignora DRAFT nei CSV).

```bash
caffeinate -i python3 pubblica_bozze.py
```

1. Cerca nel tuo inventario Discogs le bozze create dallo script (le
   riconosce dall'`external_id`, cioè il nome della foto). Le altre bozze
   del tuo inventario non vengono toccate.
2. Ti mostra **quante bozze sta per mettere in vendita**, il totale dei
   prezzi, le prime 10 e il tempo stimato.
3. **Chiede conferma**: scrivi `s` e premi Invio per procedere. Qualsiasi
   altra risposta annulla senza toccare nulla.
4. Le mette in vendita una per una e alla fine dice quante ci sono riuscite
   e quali no, con il motivo.

Cose da sapere:

- Prezzo e gradi sono quelli che l'annuncio ha **in quel momento su
  Discogs**: se in bozza hai cambiato qualcosa a mano, resta la tua modifica.
- Le bozze che hai già messo in vendita o cancellato a mano vengono saltate.
- Le bozze vecchie rimaste su Discogs dopo un `vendi.py --rielabora` (stesso
  external_id, ma create prima della rielaborazione) **non vengono messe in
  vendita**: lo script te le elenca con il link, da cancellare a mano.
- Puoi interromperlo con **Ctrl+C** e rilanciarlo: riparte dalle bozze
  rimaste, senza doppioni. Lo stesso vale per quelle non riuscite.
- Va al ritmo di 60 richieste al minuto: 1.000 bozze richiedono circa 18
  minuti.
- Aggiorna `annunci_pubblicati_api.csv` (colonna `status`). I CSV di
  inventario invece non cambiano: restano quelli che hai caricato.

### Riprezzamento mensile (`riprezza.py`)

Una volta al mese ricontrolla il mercato per i tuoi annunci **In vendita** e
propone un prezzo nuovo **solo se è più alto** di quello attuale. Non abbassa
**mai** un prezzo.

Prima lancialo **senza `--applica`**: propone e basta, non cambia niente.

```bash
caffeinate -i python3 riprezza.py
```

Guarda il riepilogo e `risultati/riprezzamento_AAAAMMGG.csv`. Se ti va bene,
rilancialo con `--applica`: mostra lo stesso riepilogo, chiede conferma (`s`)
e solo dopo aggiorna i prezzi.

```bash
caffeinate -i python3 riprezza.py --applica
```

**Come calcola.** Usa la **stessa regola di `vendi.py`**, tre corsie comprese
(base, minimo suggerito per il grado dell'annuncio, premi scarsità e richiesta
a scalini, griglia 2,50; vedi "Tre corsie di prezzo"), con dati di mercato aggiornati (quelli salvati più
vecchi di `--cache-prezzi-giorni`, default 30, si richiedono di nuovo).

**I tuoi annunci non contano come concorrenza.** Le statistiche di Discogs
contano anche le tue copie: senza correzione l'aumento si alimenterebbe da
solo (sei l'unico a 30 €, "1 copia, più basso 30 €", +50% → 45 €, il mese dopo
67,50 €…). Quindi:

- **copie della concorrenza** = copie in vendita meno le tue (tutte le
  condizioni);
- se il prezzo più basso è uguale o maggiore di un tuo prezzo per quella
  release (il più basso potresti essere tu), **non lo usa**: base = suggerito;
- con **0 copie della concorrenza** applica la regola "0 copie" sul suggerito,
  come alla prima pubblicazione.

**Esito di ogni annuncio** (colonna `esito`):

| Esito | Quando | Cosa succede con `--applica` |
| --- | --- | --- |
| **da alzare** | il prezzo nuovo supera l'attuale di almeno un gradino (2,50) | viene alzato |
| **invariato** | il prezzo nuovo è uguale, più basso o più alto di meno di 2,50 | niente (mai abbassato) |
| **da controllare** | aumento oltre `--rialzo-massimo` (default 50%) o prezzo nuovo sopra `--soglia-controllo` (default 100) | niente: controlla a mano |
| **sei il più economico** | il più basso in vendita potresti essere tu, ma ci sono altri venditori: chiedono di più e il tuo prezzo è probabilmente sotto mercato | niente: apri il link `link_vendite_release` (pagina di vendita della release) e decidi a mano |
| **dati non disponibili** | Discogs non ha dato i dati di mercato o il prezzo suggerito | niente |

**Dischi in crescita.** A ogni giro salva want e have di ogni release, con la
data (tabella `want_storico` dello stato). Se i want sono cresciuti più di
`--crescita-want` (default 30%) dal controllo precedente, il disco è segnato
**in crescita** nel CSV e nel riepilogo, anche se il prezzo resta invariato.

**Il CSV** `risultati/riprezzamento_AAAAMMGG.csv` ha: listing_id, external_id,
artista – titolo, grado, prezzo attuale, prezzo proposto, aumento in %,
esito, motivo, in crescita, want/have, creato da (script o a mano), calcolo
del prezzo, link all'annuncio e alla pagina di vendita della release. Il
riepilogo dice quanti annunci sono da alzare, invariati, da controllare, "sei
il più economico" e in crescita, e di quanto aumenterebbe in totale il valore
dell'inventario.

**Come applica (`--applica`).** Per ogni annuncio da alzare: lo rilegge da
Discogs (se non è più in vendita, o hai cambiato il prezzo a mano nel
frattempo, lo salta), reinvia **tutti i suoi campi attuali** (commenti,
external_id, posizione, peso, quantità, offerte, copertina) con il solo prezzo
nuovo, lo rilegge di nuovo e **si ferma subito** se un campo diverso dal prezzo
è cambiato. Ogni modifica resta nello storico (tabella `riprezzamenti`: data,
prezzo vecchio, prezzo nuovo, calcolo). Puoi interromperlo con Ctrl+C: al
prossimo lancio con `--applica` riprende dalle modifiche rimaste, senza
ripetere quelle fatte.

**Migliaia di annunci.** Servono 2-3 richieste per release e il limite è 60 al
minuto: ogni giro controlla al massimo `--max-annunci` annunci (default 500),
**prima quelli verificati da più tempo**. Con un giro al mese si copre tutto
l'inventario a rotazione.

| Opzione | Default | Cosa fa |
| --- | --- | --- |
| `--applica` | | dopo conferma aggiorna i prezzi via API (senza: propone e basta) |
| `--solo-script` | | solo gli annunci creati da `vendi.py` (di default tutti, la colonna `creato_da` dice quali) |
| `--max-annunci` | 500 | annunci da controllare in questo giro |
| `--rialzo-massimo` | 50 | aumento % oltre il quale il prezzo va controllato a mano |
| `--soglia-controllo` | 100 | prezzo nuovo oltre il quale va controllato a mano (la stessa di `vendi.py`) |
| `--crescita-want` | 30 | crescita % dei want per segnalare un disco "in crescita" |
| `--cache-prezzi-giorni` | 30 | dati di mercato più vecchi si richiedono a Discogs |
| regola del prezzo e corsie | come `vendi.py` | `--premio-zero-copie`, `--copie-poche`, `--premio-poche-copie`, `--copie-alcune`, `--premio-alcune-copie`, `--scalini-richiesta`, `--passo-prezzo`, `--prezzo-minimo`, `--corsia-lenta-sotto`, `--corsia-calda-sopra`, `--sconto-corsia-lenta`, `--corsie-off` |

### Verificare la modifica degli annunci (`verifica_modifica_annuncio.py`)

Da lanciare **una volta**, su **un solo** annuncio In vendita che abbia
commenti ed external_id compilati, per sapere se una modifica via API che
invia solo i campi obbligatori ne azzera altri:

```bash
python3 verifica_modifica_annuncio.py NUMERO_ANNUNCIO
```

Il numero è nel link dell'annuncio (`discogs.com/sell/item/NUMERO`). Salva
l'annuncio com'è in `risultati/verifica_modifica_annuncio.json`, chiede
conferma, prova una modifica "minima" e una "completa" lasciando **lo stesso
prezzo**, e ripristina subito eventuali campi azzerati. `riprezza.py` e
`pubblica_bozze.py` usano comunque la modifica completa, che reinvia tutti i
campi.

### Regola del prezzo

È la regola delle corsie **normale** e **calda** (vedi "Tre corsie di prezzo",
sopra), e di tutti i dischi con `--corsie-off`. Lo script usa, per ogni
release, i dati del marketplace Discogs: copie in vendita, prezzo più basso,
want/have.

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

**3. Premio richiesta, a scalini**, in base al rapporto **want/have** (quanti
lo cercano / quanti lo hanno). Si applica lo scalino più alto superato:

| want/have | Premio |
| --- | --- |
| fino a 1 | nessun premio |
| oltre 1 | **+10%** |
| oltre 2 | **+25%** |
| oltre 4 | **+50%** |

Soglie e percentuali si cambiano con `--scalini-richiesta` (default
`1:10,2:25,4:50`, cioè `soglia:premio%` separati da virgole). La regola è la
stessa in `vendi.py` e in `riprezza.py`.

**I premi si sommano**, e non c'è un tetto massimo:

> prezzo = base × (1 + premio scarsità + premio richiesta)

**4. Arrotondamento a griglia (ultimo passaggio).** Il prezzo finale non ha
mai centesimi "strani": si arrotonda **sempre per eccesso** al gradino uguale
o immediatamente superiore di una griglia a passo **2,50**: 2,50 – 5,00 –
7,50 – 10,00 – 12,50 – … senza limite superiore.
- Se il prezzo è già esattamente su un gradino, resta com'è. Mai per difetto.
- **Minimo assoluto 2,50**: nessun annuncio sotto questa cifra.
- Si applica dopo base, minimo suggerito per grado e premi. Anche quando i
  dati del marketplace non sono disponibili e il prezzo è il suggerito.
- La **soglia di controllo** (`--soglia-controllo`) e il prezzo finale in
  `collezionistici.csv` usano il prezzo già arrotondato.
- Il calcolo usa i centesimi esatti (Decimal), non i numeri con la virgola
  del computer: un 10,000000001 resta 10,00 e non salta a 12,50.

| Prezzo calcolato | Prezzo finale |
| --- | --- |
| 1,80 | 2,50 |
| 2,50 | 2,50 |
| 3,00 | 5,00 |
| 6,10 | 7,50 |
| 10,40 | 12,50 |
| 29,15 | 30,00 |
| 99,99 | 100,00 |
| 100,01 | 102,50 |

Esempi completi:

| Situazione | Calcolo | Prezzo finale |
| --- | --- | --- |
| suggerito 24,20; più basso 50,00; 2 copie; want/have 3 | 50,00 × (1 + 50% + 25%) = 87,50 | 87,50 |
| suggerito 64,10; nessuna copia; want/have 6 | 64,10 × (1 + 100% + 50%) = 160,25 | 162,50 |
| suggerito 32,10; più basso 40,00; 4 copie; want/have 0,05 | 40,00 × (1 + 25%) = 50,00 | 50,00 |
| suggerito 13,10; più basso 8,00; 40 copie | 13,10 (soglia minima) | 15,00 |

Nel CSV per Discogs il prezzo esce sempre con due decimali e il punto (es.
`12.50`).

**Valute:** tutti i prezzi sono nella **valuta del tuo account venditore**,
che lo script legge da Discogs all'avvio. I prezzi suggeriti arrivano già in
quella valuta. Il prezzo più basso in vendita viene chiesto a Discogs
convertito nella stessa valuta, quindi è Discogs a fare la conversione.

**Il calcolo è sempre visibile:** la colonna `calcolo_prezzo` nei file dei
risultati riporta suggerito, prezzo più basso, base, copie in vendita,
want/have, premi applicati e conto finale. Per esempio:

```
suggerito NM 24,20; più basso in vendita 50,00; base = più basso in vendita 50,00;
2 copie in vendita (1-2) +50%; want/have 300/100 = 3,00 > 2 +25%;
prezzo = 50,00 × (1 + 75%) = 87,50 EUR → arrotondato a griglia 2,50 = 87,50 EUR
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
| `--scalini-richiesta` | 1:10,2:25,4:50 | premio richiesta a scalini: want/have oltre 1 +10%, oltre 2 +25%, oltre 4 +50% |
| `--passo-prezzo` | 2.50 | passo della griglia: il prezzo finale si arrotonda per eccesso a un suo multiplo |
| `--prezzo-minimo` | 2.50 | prezzo minimo assoluto di un annuncio |

Attenzione: il prezzo più basso in vendita è quello di una copia qualsiasi, in
qualunque grado. Per un disco in grado basso la base può quindi risultare alta.
Controlla la colonna `calcolo_prezzo` prima di caricare il CSV.

**Tempi:** servono 2 richieste per ogni release diversa (dati della release e
statistiche del marketplace), oltre a quella del prezzo suggerito, sempre entro
il limite di 60 al minuto. I dati restano in cache anche tra un'esecuzione e
l'altra, ma **scadono**: prezzi suggeriti, copie in vendita e want/have dopo
30 giorni (`--cache-prezzi-giorni`), il controllo delle release bloccate dopo
90 (`--cache-vendibilita-giorni`). Scaduti, si richiedono di nuovo a Discogs,
così un "0 copie in vendita, +100%" di due mesi fa non resta valido per sempre.

### Tre corsie di prezzo

Su 10.000 dischi il tempo è il costo maggiore. Invece di un prezzo unico, lo
script divide i dischi in **tre corsie** secondo il rapporto **want/have**
(quanti vogliono il disco diviso quanti ce l'hanno): i dischi lenti girano in
fretta, su quelli richiesti si fa margine. Vale sia alla prima pubblicazione
(`vendi.py`) sia nel riprezzamento mensile (`riprezza.py`).

| Corsia | want/have | Prezzo |
| --- | --- | --- |
| **LENTA** | sotto 1 (`--corsia-lenta-sotto`) | **5% sotto** (`--sconto-corsia-lenta`) il prezzo più basso della **concorrenza**, griglia per **difetto** |
| **NORMALE** | da 1 a 2 | regola standard invariata: base = più basso, mai sotto il suggerito, premi, griglia per eccesso |
| **CALDA** | sopra 2 (`--corsia-calda-sopra`) | regola standard, con i premi richiesta a scalini alti (+25% oltre 2, +50% oltre 4) |

**Regole della corsia lenta:**

1. **Griglia per difetto.** Dopo lo sconto il prezzo scende al gradino da
   2,50 **inferiore o uguale**: con l'arrotondamento per eccesso lo sconto
   sparirebbe e torneresti sopra la concorrenza. È l'unica corsia che
   arrotonda per difetto.
2. **Pavimento.** Mai sotto il prezzo suggerito per il grado, né sotto il
   prezzo minimo (2,50): meglio tenere il disco che regalarlo. Se il 5% sotto
   la concorrenza cadrebbe sotto il suggerito, il prezzo è il suggerito
   arrotondato alla griglia (per eccesso).
3. **Senza concorrenza non è un disco da svendere.** Se non ci sono copie
   della concorrenza, o il prezzo più basso in vendita potresti essere tu, non
   c'è un prezzo da sottoquotare: il disco segue la corsia normale.
4. **I tuoi annunci non sono concorrenza.** In `riprezza.py` lo script li
   legge dal tuo inventario; in `vendi.py` dallo stato (righe CSV e annunci API
   in vendita, esclusi quelli venduti, spariti o mai caricati secondo
   `verifica_inventario.py`).

La **rete di sicurezza** resta in tutte le corsie: un disco collezionistico, o
sopra `--soglia-controllo`, riconosciuto senza barcode o catalogo esatto va
comunque in `da_controllare.csv`. E `riprezza.py` non abbassa mai un prezzo:
se la corsia lenta propone meno del prezzo attuale, l'annuncio resta
invariato.

**Il calcolo dice sempre la corsia e perché** (colonna `calcolo_prezzo`):

| Situazione | Calcolo | Prezzo |
| --- | --- | --- |
| want/have 0,4; concorrenza a 20,00; suggerito 10,00 | corsia LENTA (want/have 0,40 < 1): 5% sotto concorrenza 20,00 = 19,00 → griglia per difetto 17,50 | 17,50 |
| want/have 0,4; concorrenza a 20,00; suggerito 18,70 | 19,00 → 17,50, sotto il suggerito 18,70: prezzo = suggerito sulla griglia | 20,00 |
| want/have 0,4; nessuna copia della concorrenza; suggerito 10,00 | corsia LENTA: nessun concorrente da sottoquotare, regola NORMALE; 0 copie +100% | 20,00 |
| want/have 1,5; più basso 20,00; 6 copie; suggerito 10,00 | corsia NORMALE: 20,00 × (1 + 10%) = 22,00 | 22,50 |
| want/have 3; più basso 20,00; 6 copie; suggerito 10,00 | corsia CALDA: 20,00 × (1 + 25%) = 25,00 | 25,00 |

| Opzione | Default | Cosa fa |
| --- | --- | --- |
| `--corsia-lenta-sotto` | 1 | want/have sotto questo valore: corsia LENTA |
| `--corsia-calda-sopra` | 2 | want/have sopra questo valore: corsia CALDA |
| `--sconto-corsia-lenta` | 5 | % sotto il prezzo più basso della concorrenza |
| `--corsie-off` | | niente corsie: regola unica per tutti, come prima |

Le stesse opzioni valgono per `vendi.py` e `riprezza.py`.

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
- **Modello più preciso:** `--ai-modello claude-sonnet-5` o `claude-sonnet-5-5`
  costano circa il doppio, `claude-opus-5` circa 5 volte. Questi modelli
  ragionano prima di rispondere: lo script lascia loro più token di risposta,
  quindi una chiamata può costare qualche centesimo in più.
- **Secondo tentativo:** solo per le foto che il primo modello non riconosce,
  con `claude-sonnet-5-5`; stessa cache e stesso tetto. Il riepilogo dice
  quante foto ha recuperato e quanto è costato.

### I risultati (cartella `risultati/`)

| File | Cosa contiene |
| --- | --- |
| `inventario_001.csv`, `inventario_002.csv`… | Dischi trovati in locale, al massimo 1.000 dischi per file (le copie contano), da caricare su Discogs; status sempre `FOR_SALE` |
| `archivio/` | File CSV annullati (`inventario_NNN_ANNULLATO.csv`, da non caricare) e copie dei file prima di una modifica (`inventario_NNN_PRIMA_<data>.csv`) |
| `verifica_inventario.csv` | Scritto da `verifica_inventario.py`: per ogni riga CSV e annuncio API, se è online su Discogs e come |
| `inventario_foto.csv` | Per ogni riga dei CSV di inventario: tutte le foto (copie) che contiene, il prezzo e il **calcolo del prezzo** |
| `non_vendibili.csv` | Dischi riconosciuti ma **bloccati dal marketplace Discogs**, che non si possono mettere in vendita: foto, grado (del disco), grado_copertina, release_id, artista e titolo, metodo di riconoscimento, link alla release, motivo |
| `collezionistici.csv` | Dischi collezionistici, ordinati per punteggio, con grado del disco e della copertina, motivi, prezzo suggerito, prezzo più basso in vendita, prezzo finale e calcolo |
| `riconoscimento.csv` | Per ogni foto: esito, metodo (es. `locale-barcode`, `ai-scelta+locale`), disco trovato, sicurezza e motivo della scelta AI, costo AI in euro |
| `annunci_pubblicati_api.csv` | Annunci pubblicati via API, uno per foto, con calcolo del prezzo e link |
| `da_controllare.csv` | Foto da sistemare a mano: nome della foto, cartella, grado (del disco), grado_copertina, motivo, release proposta (`release_id_proposto`, `disco_proposto`, `link_proposto`), metodo (`barcode`, `catno`, `locale-testo`, `ai`), prezzo calcolato, dettagli letti e candidati |

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

- **riconoscimento da verificare a mano**: il disco è stato riconosciuto
  dall'AI o per artista e titolo, ma non ha superato la verifica finale (es.
  "è una riga della scaletta", "l'artista non compare tra le scritte
  principali", "Various ma la foto non mostra una compilation", "combacia solo
  per una parola"), oppure è collezionistico o costa più della soglia di
  controllo. Trovi la release proposta con il link, il metodo e il prezzo
  calcolato: se è giusta, mettilo in vendita a mano su Discogs.
- **non trovato né nel database locale né su Discogs**: nemmeno con l'AI si è
  trovato un disco reale coerente con la foto. La colonna `dettagli` dice cosa
  hanno letto l'OCR e l'AI e perché è stato scartato, per esempio "nessun
  candidato coerente con la foto" o "l'AI non ha trovato il disco tra i
  candidati".
- **più release possibili**: capita solo con `--senza-ai`. Più stampe
  compatibili che non si sono potute distinguere; i candidati sono ordinati per
  punteggio.
- **nessun prezzo suggerito da Discogs**.
- **probabilmente lo stesso disco fotografato più volte**: due foto della
  stessa release e grado scattate a pochi secondi di distanza (vedi "Fronte e
  retro dello stesso disco"), oppure foto con lo stesso artista e titolo su
  release diverse (es. LP e CD).
- **impossibile verificare se è vendibile**: la richiesta a Discogs per sapere
  se la release è bloccata dal marketplace non è riuscita (rete, errore di
  Discogs) o la risposta non conteneva il campo `blocked_from_sale`. Il disco
  non va in vendita e viene ricontrollato al prossimo lancio. Se capita a
  tutte le foto con "campo assente", Discogs ha cambiato il nome del campo:
  dimmelo.
- **pubblicazione non confermata**: lo script si è interrotto proprio durante
  la pubblicazione e non è riuscito a verificare se l'annuncio esiste.
  Controlla su Discogs cercando l'`external_id` (es. `IMG_1234`).
- **Discogs ha rifiutato l'annuncio**, con il messaggio di Discogs.

**Il riepilogo finale** di ogni esecuzione mostra: righe nel CSV di
inventario (e copie), annunci via API, foto da controllare, foto già in
vendita, **dischi non vendibili (bloccati da Discogs)**, dischi
collezionistici, richieste API fatte e spesa AI. Se per qualche foto non è
stato possibile verificare la vendibilità, lo dice in fondo con l'ultimo errore.

Consiglio: in `riconoscimento.csv` guarda le righe con `sicurezza_ai` **bassa**.
Sono dischi identificati, ma di cui l'AI ha scelto la stampa più probabile.

Se sostituisci una foto finita da controllare con uno scatto migliore (stesso
nome), al prossimo lancio viene rianalizzata da sola. Rilanciando lo script
normalmente, le foto da verificare restano fuori dal CSV. Per rifare la parte
locale su tutte le foto da controllare (i risultati AI già pagati vengono
riusati; per far rileggere la foto all'AI usa `--rielabora`):

```bash
caffeinate -i python3 vendi.py ~/Pictures/Dischi --riprova
```

### Opzioni di `vendi.py`

| Opzione | Cosa fa |
| --- | --- |
| `--premio-zero-copie`, `--copie-poche`, `--premio-poche-copie`, `--copie-alcune`, `--premio-alcune-copie`, `--scalini-richiesta`, `--passo-prezzo`, `--prezzo-minimo` | Regola del prezzo, vedi la tabella nella sezione "Regola del prezzo" |
| `--soglia-prezzo 80` | Per `collezionistici.csv`: prezzo oltre il quale un disco conta come di valore (default 50, valuta del tuo account) |
| `--soglia-collezionistico 5` | Per `collezionistici.csv`: punteggio minimo (default 4) |
| `--soglia-controllo 150` | I dischi riconosciuti senza barcode o catalogo esatto (AI o `locale-testo`) con prezzo finale sopra questa soglia, o collezionistici, vanno in `da_controllare.csv` invece che in vendita (default 100, valuta del tuo account) |
| `--limite N` | Elabora solo i primi N dischi (foto sciolte o sottocartelle) |
| `--bozza` | Crea tutti gli annunci in bozza (`Draft`) **via API**, anche quelli che andrebbero nel CSV (Discogs ignora DRAFT nei CSV); un annuncio per foto |
| `--simula` | Non pubblica annunci e non tocca i CSV veri; scrive in `risultati/simulazione/` |
| `--riprova` | Rianalizza le foto finite da controllare |
| `--rielabora` | Ignora lo stato salvato per le foto della cartella e le rielabora da capo, AI compresa. Solo con `--bozza`, non con `--simula`; prima legge l'inventario Discogs e salta le foto online o state in vendita |
| `--ai-tetto 80` | Spesa AI massima in euro, sommando tutte le esecuzioni (default 50); raggiunta, lo script si ferma |
| `--ai-modello NOME` | `claude-haiku-4-5` (default), `claude-sonnet-5`, `claude-sonnet-5-5` o `claude-opus-5` |
| `--ai-modello-secondo NOME` | Modello del secondo tentativo sulle foto non riconosciute (default `claude-sonnet-5-5`) |
| `--senza-secondo-tentativo` | Niente secondo tentativo |
| `--ai-max-foto 4` | Disco in sottocartella: foto inviate al massimo all'AI nella stessa chiamata (default 4) |
| `--formati-ammessi Vinyl` | Formati Discogs ammessi tra i candidati, separati da virgole (default `Vinyl`: le release solo CD, Cassette, File… vengono scartate) |
| `--secondi-stesso-disco 90` | Due foto della stessa release e grado scattate a meno di tanti secondi vanno da controllare (default 90) |
| `--copie-consecutive` | Disattiva il controllo sui secondi: le foto sono sempre copie diverse |
| `--cache-prezzi-giorni 30` | Dopo quanti giorni prezzi suggeriti, copie in vendita e want/have si richiedono a Discogs (default 30) |
| `--cache-vendibilita-giorni 90` | Dopo quanti giorni si ricontrolla se una release è bloccata dal marketplace (default 90) |
| `--backup-da-tenere 20` | Copie dello stato da tenere in `data/backup/` (default 20) |
| `--scalini-richiesta 1:10,2:25,4:50` | Premio richiesta a scalini (vedi "Regola del prezzo") |
| `--corsia-lenta-sotto 1`, `--corsia-calda-sopra 2`, `--sconto-corsia-lenta 5`, `--corsie-off` | Tre corsie di prezzo (vedi "Tre corsie di prezzo") |
| `--senza-ai` | Non usa l'AI: solo riconoscimento locale gratuito |
| `--uscita PERCORSO` | Cartella dei risultati (default `risultati/`) |
| `--db PERCORSO` | Database creato da `discogs_dump.py` (default `data/discogs.sqlite`) |

### Dove sta lo stato

I progressi (foto riconosciute, risultati dell'AI e relativo costo, prezzi ottenuti, release bloccate o vendibili, dati collezionistici, righe CSV, annunci creati e bozze messe in vendita) sono in
`data/vendita_stato.sqlite`. È separato da `discogs.sqlite` perché quello viene
ricostruito da zero ogni mese, e i progressi andrebbero persi.

**Non cancellare questo file:** è quello che impedisce di pubblicare due
volte lo stesso disco. Per ripetere un test sulle stesse foto usa
`--rielabora --bozza` invece di cancellarlo.

**Backup automatico.** `vendi.py` (non in `--simula`), `verifica_inventario.py`
e `pubblica_bozze.py`, prima di modificare qualcosa, copiano lo stato in
`data/backup/vendita_stato_AAAAMMGG_HHMMSS.sqlite`. Restano le ultime 20 copie
(`--backup-da-tenere`).

**Ripristinare un backup** (se lo stato si rovina o dopo un errore):

1. assicurati che nessuno script sia in esecuzione;
2. metti da parte lo stato attuale e copia al suo posto il backup scelto,
   per esempio il più recente:

```bash
cd ~/Discogs
mv data/vendita_stato.sqlite data/vendita_stato_rovinato.sqlite
cp data/backup/vendita_stato_20261013_154233.sqlite data/vendita_stato.sqlite
```

3. lancia `python3 verifica_inventario.py`: riallinea lo stato con quello che
   è davvero online su Discogs (le modifiche fatte dopo il backup).

### Test automatici

```bash
python3 -m unittest discover tests
```

Fanno girare `vendi.py` su foto finte, con un piccolo database e con Discogs,
OCR e AI simulati (nessuna rete, nessuna spesa). Controllano i casi reali
visti nelle prove: il retro della compilation di Theo Parrish scambiato per
The Awakening - Mirage, la white label abbinata a una release russa per il solo
titolo, e la release Various data a un'etichetta Omar-S finiscono in
`da_controllare.csv`. Un match pulito come Moodymann - Picture This Sampler 3
(`THIS003`) resta nel CSV. I test coprono anche la soglia di controllo,
`--rielabora`, le release bloccate, la griglia dei prezzi e i punti della
revisione prima del primo lotto (backup, verifica dell'inventario, bozze via
API, nomi ripetuti, scadenza delle cache, stesso disco fotografato più volte,
secondo tentativo AI) in `tests/test_lotto.py`, il riprezzamento in
`tests/test_riprezza.py`, il doppio grado in `tests/test_doppio_grado.py`, le tre corsie in `tests/test_corsie.py` e i dischi
in sottocartella con `raggruppa_foto.py` in `tests/test_dischi_cartella.py`. I
test scritti per la regola unica girano con `--corsie-off`. I test con l'EXIF
vero (data di scatto, `raggruppa_foto.py`) richiedono Pillow e vengono saltati
se manca.

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
