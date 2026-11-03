# Vinyl Hustler (Discogs) — regole per Claude

App iOS in `app-ios/` (progetto `VinylHustler.xcodeproj`) + gli script Python dello stesso repo. Backend su Supabase. Ci lavorano Alessandro e Matteo: Matteo può proporre idee anche quando Alessandro non c'è.

- **Ramo di Xcode:** `claude/ciao-ttimyc` (il ramo principale del repo).
- Ogni modifica si numera **V1, V2, V3…** (oggi siamo a V69) e Alessandro deve sapere ogni volta cosa è cambiato, così si può togliere una sola versione sbagliata.
- L'app sul telefono di Alessandro deve essere identica a quella sul telefono di Matteo.

## Come si lavora con Alessandro (valido per ogni sessione)

**Prima di fare**
- Prima di modificare il codice: spiegare in parole semplici cosa si vuole fare e aspettare il suo sì. Per una correzione semplice si fa solo quella, senza aggiungere altro.
- Ogni scelta tecnica o di struttura (come dividere sezioni, schermate, file) va chiesta e approvata prima. L'app vera deve essere identica al mockup approvato.
- Mai togliere voci, sezioni, passi o funzioni senza chiederlo. Se un'istruzione si può capire in più modi, chiedere invece di interpretare.
- Design, layout, grafica e suoni li cambia solo lui, su sua richiesta. Le proposte si possono fare, ma non si applicano da sole.
- Proporre sempre la soluzione migliore e più funzionale, non la scorciatoia più veloce. Se una cosa non si può fare (es. limite di Apple), dirlo subito e chiaramente.

**Git e build**
- Lavorare sempre sul ramo su cui è già Xcode (indicato sotto): niente ramo nuovo per ogni build. A lui basta Integrate › Pull.
- Version e Build li gestisce Claude nel progetto (lui non li tocca in Xcode), ma il numero di build non si alza da soli: prima chiedergli se carica la build e che numero vuole.
- Ogni build va su TestFlight col suo metodo di sempre (Pull + Archive + TestFlight), mai solo col cavo da Xcode. Non proporre metodi diversi senza chiedere.
- Tenere traccia delle build (cosa contengono, quale funzionava) è compito di Claude, non suo.

**Prima di dire "pronta"** — qui (claude.ai/code, Linux) Xcode non c'è, quindi:
1. Ricontrollare a mano ogni file toccato:
   - import espliciti in ogni file: in particolare `import Combine` dove si usano `@Published` / `ObservableObject`;
   - nomi ambigui tra framework (es. `MusicPlayer`);
   - codice del thread principale chiamato da closure/blocchi che non girano sul main actor;
   - tipi scritti in modo esplicito nelle liste di tuple.
2. Zero errori **e zero warning**: anche gli avvisi di Xcode vanno tolti.
3. Lanciare il controllo di compilazione su GitHub: fare il push con **`[compila]`** nel messaggio del commit, poi leggere il risultato del workflow **Compila** (scheda Actions del repo). Consegnare solo se è verde. Ogni controllo consuma minuti Mac di GitHub (circa 200 al mese gratis): usarlo solo quando una build è davvero da consegnare.
4. Mai dire "risolto" se il risultato non è esattamente quello che vuole lui: dire chiaro cosa è fatto, cosa no e cosa va verificato sul telefono.

**Nell'app**
- Animazioni a 120 Hz (ProMotion), fatte bene ma funzionali: zero animazioni inutili.
- Continuità: tutte le sezioni si aprono, si presentano e si chiudono allo stesso modo.
- Titoli di sezioni, schede ed etichette di una sola parola chiara. Diciture leggibili, senza ripetere le stesse parole ovunque. I numeri e i conti stanno scritti a schermo.
- Mockup sempre realistici (funzionamento e animazioni provabili nel mockup) e ottimizzati per ogni dispositivo.

**Skill in `.claude/skills`**
- Si usano per controllare e per segnalare problemi. I loro risultati sono proposte da mostrare ad Alessandro: non si applicano modifiche al codice, e mai al design, senza il suo sì.
