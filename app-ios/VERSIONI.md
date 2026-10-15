# Vinyl Hustler — versioni

Ogni modifica all'app riceve un numero (V1, V2, V3…) e viene salvata su GitHub come ramo
`claude/vh-vN`, così si può tornare a qualsiasi versione o togliere una sola modifica sbagliata
tenendo tutte le altre.

## Come si usa (per Alessandro e Matteo)

- **"Togli la V4"** → si annulla solo la modifica V4; V2, V3 e le successive restano.
- **"Torna alla V3"** → l'app torna esattamente com'era alla V3 (le versioni dopo restano salvate, si possono riprendere).
- **"Rimetti la V4"** → si riprende una modifica tolta.
- Dopo ogni cambio: in Xcode **Integrate › Pull**, poi **▶** sul telefono.

## Regole per Claude

1. Ogni modifica chiesta = una nuova versione: aggiorna questa tabella (numero, data, chi, cosa) nello stesso commit,
   e pubblica anche il ramo `claude/vh-vN` (oltre a `claude/ciao-ttimyc`, il ramo che si usa in Xcode).
2. "Togli la VN" = `git revert` dei commit di quella versione (mai riscrivere la storia, mai force push).
3. "Torna alla VN" = nuovo commit che riporta i file allo stato del ramo `claude/vh-vN`.
4. Comunica sempre il numero di versione appena creata.

## Elenco

| Versione | Data | Chi | Cosa |
|---|---|---|---|
| V1 | 15 ott 2026, sera | Alessandro | Versione stabile: fotocamera, riconoscimento Haiku→Sonnet, voce Apple, suoni JARVIS e apertura, grafica Discosizer, cestino su ogni disco, Magazzino con bozze eliminabili, Ordini a schede. |
| V2 | 15 ott 2026 | Alessandro | Sessione: titoli come su Discogs (Posizione (privata), Condizione, Fotocamera), via le icone di Vinile/Copertina, testi sotto più corti e a righe, tolto il testo sotto i contenitori; "Oggi" mostra anche gli ultimi 10 annunci già su Discogs (come il Magazzino), i nuovi scatti sopra. | (correzione: errore di compilazione in SessionView)
| V3 | 16 ott 2026 | Alessandro | Sessione: niente testi sotto le sezioni, al loro posto la (i) con spiegazioni dettagliate ed esempi (Posizione, Condizione, Fotocamera); tasto fotocamera solo col simbolo; "Oggi" solo i numeri (fotografati, Discogs, in revisione). Magazzino: solo Online e Bozze (via "Tutti"), tocchi un disco e si apre su Discogs. |
| V4 | 16 ott 2026 | Alessandro | Disco riconosciuto: via la domanda "È questo?"; tasti "Conferma" e "Altre versioni" (prima "Sì, è questo" / "No"); "Elimina" rosso e largo in fondo a ogni scheda (via il cestino in alto a destra), anche in Revisione. |
