# Discogs → SQLite

`discogs_dump.py` scarica l'ultimo dump mensile delle **release** di Discogs
([data.discogs.com](https://data.discogs.com/)) e lo importa in un database
SQLite locale con un indice sul **barcode**. Puoi rilanciarlo ogni mese per
aggiornare il database.

- Usa solo Python 3 (nessuna libreria da installare).
- Il database finisce in `data/discogs.sqlite`, che è nel `.gitignore` e quindi
  non viene mai salvato nella repository.
- Se il database contiene già l'ultimo dump, lo script non fa nulla.
- Se il dump è nuovo, lo script crea un database nuovo e sostituisce quello
  vecchio solo a fine importazione. Fino ad allora quello vecchio resta usabile.
- Un download interrotto riprende da dove si era fermato: basta rilanciare lo
  stesso comando.

> **Spazio e tempo:** il dump compresso pesa più di 10 GB e il database finale
> qualche decina di GB. Tieni liberi almeno 50 GB. L'importazione richiede
> qualche ora. A fine lavoro il file scaricato viene cancellato (con
> `--keep-dump` lo tieni).

## Comandi sul Mac (Terminale)

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

### 3. Cerca una release per barcode

```bash
cd ~/Discogs
python3 discogs_dump.py cerca 5099902987125
```

Spazi e trattini nel barcode vengono ignorati, quindi `5 099902 98712 5`
funziona uguale.

### 4. Controlla quale dump c'è nel database

```bash
cd ~/Discogs
python3 discogs_dump.py info
```

## Se il download automatico non funziona

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

## Opzioni utili

| Opzione | Cosa fa |
| --- | --- |
| `aggiorna --force` | Reimporta anche se il database è già aggiornato |
| `aggiorna --keep-dump` | Non cancella il file `.xml.gz` scaricato |
| `aggiorna --file PERCORSO` | Usa un dump già scaricato |
| `--db PERCORSO` (prima del comando) | Usa un altro file di database, es. `python3 discogs_dump.py --db ~/discogs.sqlite aggiorna` |

## Struttura del database

- `releases`: una riga per release, con `id`, `title`, `artists`, `labels`,
  `catno`, `formats`, `country`, `released`, `year`, `genres`, `styles`,
  `master_id`, `status` e `data_quality`.
- `barcodes`: `release_id`, `barcode` (valore originale) e `barcode_norm`
  (solo lettere e cifre, **indicizzato**). Una release può avere più barcode.
- `meta`: la data del dump importato e quando è stato importato.

Esempio di query diretta:

```bash
sqlite3 ~/Discogs/data/discogs.sqlite \
  "SELECT r.id, r.artists, r.title FROM barcodes b JOIN releases r ON r.id = b.release_id WHERE b.barcode_norm = '5099902987125';"
```
