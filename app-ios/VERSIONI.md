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
| V5 | 16 ott 2026 | Alessandro | Dopo Conferma: "Vendi" e "Bozza" (via "Dopo", si decide subito), Elimina rosso in fondo. Titolo del disco proposto cliccabile: apre la release su Discogs (anche in Revisione e nelle Altre versioni, col tasto ↗). Magazzino: si eliminano anche i dischi in vendita (scorri, tieni premuto o Seleziona), con avviso netto se sono online. |
| V6 | 16 ott 2026 | Alessandro | La pagina "Sessione" si chiama "Foto", con il simbolo della macchina fotografica nella barra in basso. |
| V7 | 16 ott 2026 | Alessandro | Revisione: una sola lista, niente più schede "In vendita" / "Da decidere". Ci sono solo i dischi da sistemare (più quelli confermati col prezzo ma non ancora pubblicati); in vendita e bozze stanno nel Magazzino. Il tasto diventa "Pubblica N". |
| V7 annullata | 16 ott 2026 | Alessandro | Tolta la V7: la Revisione torna com era nella V6 (schede "In vendita" e "Da decidere", tasto "Pubblica pronti · N"). Resta attiva la V6. |
| V8 | 16 ott 2026 | Alessandro | Magazzino: niente linguette, solo i dischi online; in cima Online · Bozze (tocco = va in Revisione) · Euro. Revisione: una scheda sola, Bozze, con un solo tipo di bozza (le bozze su Discogs + i dischi fotografati non ancora caricati, che restano qui finché non li sistemi); i dischi in vendita non ci sono più; barra verde "Pubblica N" con conferma. |
| V9 | 16 ott 2026 | Alessandro | Dopo lo scatto, accanto a Conferma c è anche "Bozza": conferma il disco, calcola il prezzo e lo salva come bozza su Discogs, senza metterlo online; lo ritrovi in Revisione › Bozze. "Altre versioni" va sotto e si chiama "Versioni". La pagina Revisione si chiama "Bozze" (titolo e barra in basso, nuova icona), senza scheda interna; in Foto il contatore "in revisione" diventa "bozze". |
| V10 | 16 ott 2026 | Alessandro | Dopo lo scatto il tasto "Versioni" compare solo se ci sono davvero altre stampe trovate. Magazzino: tolto il simbolo › accanto a "Bozze" (resta toccabile); il totale torna con il simbolo € e due decimali (es. 1.234,50 €). |
| V11 | 16 ott 2026 | Alessandro | "Versioni" cerca davvero su Discogs tutte le stampe in vinile dello stesso album (dalla release proposta si risale al master e se ne leggono le versioni): il tasto compare solo se ci sono altre stampe, e la lista le mostra tutte. Magazzino: il totale in euro sta su una riga sola, simbolo € compreso (se serve il carattere si rimpicciolisce), con "Euro" sotto come le altre pastiglie. |
| V12 | 16 ott 2026 | Alessandro | Magazzino: tornano le tre pastiglie affiancate Online · Bozze · Euro (nella V11 la pastiglia Euro si prendeva tutto lo spazio e le altre due sparivano). Euro sempre su una riga col simbolo €. |
| V13 | 16 ott 2026 | Alessandro | Foto: in "Oggi" resta solo il numero "fotografati", grande e da solo (Discogs e bozze tolti: quei totali sono nel Magazzino). |
| V14 | 16 ott 2026 | Alessandro | Foto: tolta la sezione "Oggi", l ultima è la Fotocamera. Di nuovo due pagine separate: Revisione (i dischi che aspettano una decisione dopo la foto) e Bozze (le bozze su Discogs, con Vendi, Elimina e "Pubblica N"); da Revisione, "Bozza" sposta il disco in Bozze. Barra in basso: Foto, Revisione, Bozze, Magazzino, Ordini; la Console si apre dall ingranaggio in alto a destra in Foto (iPhone mostra al massimo 5 voci). |
| V15 | 16 ott 2026 | Alessandro | Revisione e Bozze in UNA sola voce in basso ("Revisione") con due linguette in alto: Revisione (i dischi da decidere dopo la foto) e Bozze (le bozze su Discogs). Stessa logica della V14: "Bozza" sposta il disco nella linguetta Bozze. Barra in basso di nuovo a 5: Foto, Revisione, Magazzino, Ordini, Console (tolto l ingranaggio in Foto). In Magazzino, "Bozze" apre Revisione sulla linguetta Bozze. | Titolo della pagina sempre "Revisione", anche sulla linguetta Bozze.
| V16 | 16 ott 2026 | Alessandro | Magazzino: ogni disco mostra la sua posizione anche se caricato fuori dall app ("senza posizione" in rosso se manca). Nel menu ⋯ nuova voce "Posizione a chi non ce l ha (N)": scrive la posizione (proposta "Scatola 1") su Discogs solo negli annunci che non ce l hanno; gli altri non si toccano, e cambia solo la posizione. |
| V17 | 16 ott 2026 | Alessandro | Magazzino: sotto ogni disco, accanto a Online e alla posizione, anche la condizione (es. "V NM · C VG+": vinile e copertina). Totale in euro in formato italiano con il punto delle migliaia: 1.234,50 €. |
| V18 | 16 ott 2026 | Alessandro | Magazzino più leggibile: sotto ogni disco una riga sola con le condizioni in sigla (es. "NM / VG+", vinile / copertina) e la posizione per intero ("Scatola 1"); tolta la scritta "Online". Euro in formato italiano fisso (1.234,50 €): il punto compare da 1.000 € in su. |
| V19 | 16 ott 2026 | Alessandro | Euro: il punto delle migliaia ora c è davvero (2.345,50 €): il formato italiano di iOS non lo metteva sotto i 10.000, ora la cifra è scritta a mano. Sotto ogni disco torna "Online", più piccolo, con le condizioni in sigla (NM / VG+) e la posizione per intero; se non ci sta su una riga la posizione va sotto, mai tagliata. |
| V20 | 16 ott 2026 | Alessandro | Magazzino: la riga sotto ogni disco è uguale per tutti e sempre su una riga (Online · NM / VG+ · posizione); se manca la posizione c è un trattino grigio "—" al posto della scritta rossa. |
| V21 | 16 ott 2026 | Alessandro | Nuova icona dell app: al posto di "VH" il nome intero, VINYL sopra e HUSTLER sotto, con le stesse lettere del marchio (stile Discosizer), verde su nero col bagliore. |
| V22 | 17 ott 2026 | Alessandro | Fotocamera a qualità foto piena del telefono: risoluzione massima del modello, elaborazione Apple al massimo (Deep Fusion/HDR), messa a fuoco da vicino e, sugli iPhone con più obiettivi, passaggio automatico alla macro quando avvicini il disco. Durante il REC passa a qualità video e poi torna. Il costo per foto non cambia (all AI va sempre la stessa misura ridotta). |
| V23 | 17 ott 2026 | Alessandro | Dopo lo scatto i tasti sono uno sotto l altro: Vendi (al posto di Conferma: conferma, calcola il prezzo e mette subito online), Bozza, Versioni (solo se ci sono altre stampe), Elimina. La seconda pagina in basso si chiama "Bozze": niente più Revisione né linguette; in cima i dischi ancora da sistemare (non riconosciuti), sotto le bozze su Discogs, e "Pubblica N" per metterle online tutte insieme. |
| V24 | 17 ott 2026 | Alessandro | Fotocamera: dopo lo scatto i tasti (Vendi, Bozza, Versioni, Elimina) sono più bassi e la fascia dei risultati più alta, così si vedono tutti e quattro uno sotto l altro; se serve la scheda scorre in verticale, Elimina si raggiunge sempre. |
| V25 | 17 ott 2026 | Alessandro | La voce di Vinyl Hustler: parla con la voce creata su ElevenLabs (Voice ID 37FWDeENZrUWBEHOcBcO), tramite la nuova funzione "voce" su Supabase (chiave ELEVENLABS_API_KEY solo sul server, separata da quella di JARVIS). Le frasi già dette restano sul telefono (seconda volta istantanea e gratis); senza rete parla la voce Apple. In Console: interruttore "Voce Vinyl Hustler (ElevenLabs)". |
| V26 | 18 ott 2026 | Alessandro | Pronta per TestFlight: versione 1.0, e dichiarato che l app non usa crittografia speciale (così Apple non chiede la conformità all export a ogni caricamento). |
| V27 | 18 ott 2026 | Alessandro | Memoria condivisa dei dischi (tabella disc_memory + funzione "memoria" su Supabase). Ogni disco confermato con Vendi o Bozza insegna all app: impronta della foto (64 bit) e lettura dell AI -> release giusta, con il numero di conferme. Allo scatto successivo, di chiunque: se l impronta coincide il disco è riconosciuto subito senza AI (gratis); se l AI legge qualcosa già confermato (anche storpiato) va dritto alla release giusta senza cercare su Discogs. Niente foto salvate, solo testo. |
| V28 | 18 ott 2026 | Alessandro | Voce ElevenLabs in streaming: la funzione "voce" passa l audio (PCM 24 kHz) mentre ElevenLabs lo genera, e l app parla dopo circa 0,2 secondi invece di aspettare la frase intera. Finita la frase la salva come WAV sul telefono (la volta dopo è istantanea). Se lo streaming non parte torna alla frase intera in mp3, poi alla voce Apple. Stesso costo, solo più veloce. |
