# JARVIS — Cervello di riserva senza internet (PROPOSTA, non in produzione)

> Idea approvata da Matteo il 18 nov 2026 come proposta da tenere in memoria.
> **Stato: NON in produzione. Nessuna riga di codice scritta.** Serve il sì di Alessandro.

## Oggi
Senza rete JARVIS risponde solo «Siamo senza rete, Sir. Appena torna il campo sono di nuovo operativo.»
(`Untitled Project/Jarvis 2.swift`, ramo `claude/build-23`, ~riga 2138). Funzionano solo le frasi già in cache.

## L'idea
1. JARVIS capisce da solo che la rete manca (o che il cervello su Supabase non risponde) e passa al
   **cervello dentro l'iPhone** (Apple Intelligence, framework `FoundationModels`).
2. Ascolto: riconoscimento vocale Apple sul dispositivo (italiano, senza rete).
3. Risponde con la sua personalità (maggiordomo, «Signore», frasi brevi) e usa ciò che c'è sul telefono:
   ora/data, calendario e promemoria, salute (Vitals), ricordi salvati, apertura sezioni, musica scaricata.
4. Voce: frasi ElevenLabs già in cache, altrimenti voce Apple (come oggi quando ElevenLabs non risponde).
5. Al ritorno della rete ripassa a Claude e gli consegna lo scambio fatto offline, così il cervello sa cosa è successo.

## Limiti
- Molto meno intelligente di Claude: domande semplici e comandi, niente ragionamenti lunghi.
- Fermo tutto ciò che vuole internet: foto, posta, ricerche, GitHub, serate.
- Solo iPhone 15 Pro o successivi, Apple Intelligence attivo, iOS 26+ (`if #available`): l'app resta compatibile con iOS 17.6.
- Watch: no (Apple non lo offre su watchOS).
- Mac («Designed for iPad»): da verificare con il workflow Compila del repo JARVIS.

## Bonus «domande semplici gratis anche con la rete»
Proposto **spento**: nel dossier Alessandro vuole l'intelligenza intatta (ha rifiutato anche «meno Opus").
Al massimo un interruttore nelle Impostazioni, spento di default.

## Da decidere prima di scrivere codice
1. Sì di Alessandro (è la sua app).
2. Grafica della «modalità locale» (scritta nella riga di stato, reattore di altro colore, …): la sceglie lui
   su un mockup provabile con 2–3 varianti.
3. Ramo: `claude/build-23` («il solito»), sopra la 13.1.

## Altre cose in lista (dalla stessa chat)
- **Protezione del cervello** (in attesa, nessun rischio imminente): 1) tentativi limitati + allarme push;
  2) una chiave per dispositivo, revocabile da SISTEMI; 3) Face ID sulle azioni pericolose; 4) registro accessi.
  Più avanti: App Attest.
- Repo `Matteocosta1/jarvis` pubblico solo per la build: da richiudere (lo fa Matteo).
