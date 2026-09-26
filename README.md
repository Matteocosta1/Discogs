# Discogs: database locale e messa in vendita

Due script:

- **`discogs_dump.py`**: scarica il dump mensile delle release di Discogs e lo
  importa in un database SQLite locale (`data/discogs.sqlite`), con indici su
  barcode e numero di catalogo.
- **`vendi.py`**: riconosce i dischi dalle foto, chiede a Discogs il prezzo
  suggerito, aggiunge il ricarico e prepara la vendita. I dischi trovati nel
  database locale finiscono nei CSV di caricamento dell'inventario. Quelli
  trovati solo via API vengono pubblicati direttamente via API.

Il database, il token (`.env`) e i risultati sono nel `.gitignore`, quindi non
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

> **Se avevi già creato il database con la versione precedente:** ora il
> database ha anche l'indice dei numeri di catalogo, che serve a `vendi.py`.
> Lo stesso comando `aggiorna` se ne accorge da solo, riscarica il dump e lo
> reimporta. Serve una volta sola.

### 3. Cerca una release

```bash
cd ~/Discogs
python3 discogs_dump.py cerca 5099902987125           # per barcode
python3 discogs_dump.py cerca --catno "SHVL 804"      # per numero di catalogo
python3 discogs_dump.py info                          # quale dump c'è nel database
```

Spazi e trattini vengono ignorati, quindi `5 099902 98712 5` funziona uguale.

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

Una cartella per grado, con esattamente questi nomi: `M`, `NM`, `VG+`, `VG`,
`G+`, `G`. Per ora il grado della cartella vale sia per il disco sia per la
copertina.

In ogni cartella metti **una foto del retro per disco**, numerata in modo
progressivo. Il numero è lo stesso che scrivi sulla busta del disco. Se un
disco è difficile, aggiungi una **seconda foto facoltativa** con lo stesso nome
più `_2`: viene usata solo se la prima non basta.

```
Dischi/
  NM/
    0001.jpg
    0002.jpg
  VG+/
    0003.jpg
    0004.jpg
    0004_2.jpg      ← seconda foto facoltativa del disco 0004
  VG/
    0005.heic       ← vanno bene anche le foto HEIC dell'iPhone
```

- I numeri non devono ripetersi tra cartelle diverse. Se succede, lo script si
  ferma subito e ti dice quali sono.
- Anche una cartella con un nome che non è un grado blocca l'avvio.
- Il numero della foto (senza estensione) diventa l'`external_id`
  dell'annuncio. È un campo privato su Discogs: quando un disco si vende, ti
  dice quale busta prendere.

### Cosa fa, disco per disco

1. **Barcode** letto in locale (zxing-cpp) e cercato nel database.
2. Se non basta, **OCR** in locale, con il riconoscimento testo di macOS.
   Estrae i possibili numeri di catalogo e li cerca nel database. Una release
   trovata per catno viene accettata solo se anche il **nome dell'etichetta**
   compare nella foto, per evitare abbinamenti sbagliati.
3. Se la prima foto non basta e c'è la `_2`, ripete i passi 1 e 2 con la
   seconda foto.
4. Se il disco **non è nel database locale**, lo cerca su Discogs via API:
   prima per barcode, poi per numero di catalogo.
5. **Prezzo suggerito** da Discogs per il grado della cartella, più il ricarico
   (12% di default). Una chiamata restituisce i prezzi di tutti i gradi di una
   release, quindi le altre copie della stessa release riusano il prezzo senza
   nuove chiamate.
6. **Uscita:**
   - trovato **in locale** → riga nel CSV di inventario, con al massimo 1.000
     dischi per file;
   - trovato **solo via API** → annuncio creato direttamente via API
     (`For Sale`).

Nessun modello AI e nessun servizio a pagamento: barcode e OCR sono librerie
gratuite che girano sul Mac, e l'API di Discogs è gratuita con il token
personale.

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

- `--limite 20`: elabora solo i primi 20 dischi, in ordine di numero.
- `--simula`: riconosce i dischi e chiede i prezzi davvero, ma **non pubblica
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
riparte da dove era. I dischi già fatti non vengono rianalizzati e gli annunci
già pubblicati non vengono mai ripubblicati.

### I risultati (cartella `risultati/`)

| File | Cosa contiene |
| --- | --- |
| `inventario_001.csv`, `inventario_002.csv`… | Dischi trovati in locale, al massimo 1.000 per file, da caricare su Discogs |
| `annunci_pubblicati_api.csv` | Annunci pubblicati via API, con link |
| `da_controllare.csv` | Dischi da sistemare a mano: nome della foto, motivo e candidati |

I CSV di inventario hanno le colonne `release_id`, `price`, `media_condition`,
`sleeve_condition`, `status` (`For Sale`) ed `external_id`.

- Un disco scritto in un file **resta sempre in quel file**, e i dischi delle
  esecuzioni successive vanno in file nuovi.
- Quindi i file che hai già caricato non cambiano: carica solo quelli nuovi.

Si caricano dalla pagina di caricamento dell'inventario di Discogs
([discogs.com/sell/upload](https://www.discogs.com/sell/upload)).

> **Al primo caricamento prova con un file piccolo** (per esempio quello
> prodotto con `--limite 20`). I nomi delle colonne seguono la documentazione
> di Discogs ma non ho potuto provarli con un caricamento reale. Se Discogs
> segnala una colonna non valida, dimmelo e la correggo.

Motivi possibili in `da_controllare.csv`:

- **non trovato né nel database locale né su Discogs**: le colonne `dettagli`
  e `candidati` dicono cosa è stato letto. Per esempio un catno trovato nel
  database ma senza che l'etichetta si leggesse nella foto.
- **più release possibili**: stesso barcode per più stampe che non si sono
  potute distinguere. Nella colonna `candidati` trovi i link: scegli quella
  giusta su Discogs.
- **nessun prezzo suggerito da Discogs**.
- **pubblicazione non confermata**: lo script si è interrotto proprio durante
  la pubblicazione e non è riuscito a verificare se l'annuncio esiste.
  Controlla su Discogs cercando l'`external_id`.
- **Discogs ha rifiutato l'annuncio**, con il messaggio di Discogs.

Hai aggiunto una foto `_2` a un disco finito da controllare? Al prossimo lancio
viene rianalizzato da solo. Per rianalizzare tutti i dischi da controllare:

```bash
caffeinate -i python3 vendi.py ~/Pictures/Dischi --riprova
```

### Opzioni di `vendi.py`

| Opzione | Cosa fa |
| --- | --- |
| `--ricarico 15` | Ricarico in % sul prezzo suggerito (default 12) |
| `--limite N` | Elabora solo i primi N dischi |
| `--simula` | Non pubblica annunci e non tocca i CSV veri; scrive in `risultati/simulazione/` |
| `--riprova` | Rianalizza i dischi finiti da controllare |
| `--uscita PERCORSO` | Cartella dei risultati (default `risultati/`) |
| `--db PERCORSO` | Database creato da `discogs_dump.py` (default `data/discogs.sqlite`) |

### Dove sta lo stato

I progressi (dischi riconosciuti, prezzi ottenuti, annunci creati) sono in
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
- `meta`: data del dump, versione dello schema, data di importazione.
