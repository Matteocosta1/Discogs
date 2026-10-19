# Security audit scope: Vinyl Hustler

- **Audited by:** Claude (claude-opus-5-5) · **Date:** 2026-10-19 · **Commit:** 0bcd9e7
- **Purpose and users:** app iOS per venditori di vinili: foto dei dischi, riconoscimento AI, annunci e ordini su Discogs. Oggi usata da Alessandro e Matteo.
- **Stack:** Swift/SwiftUI + SwiftData (iOS 17.6+); Supabase (Postgres, Auth con Sign in with Apple, 3 Edge Functions Deno); API Discogs, Anthropic, ElevenLabs.
- **Exposure:** non distribuita (solo i due telefoni del team); funzioni Supabase raggiungibili da internet con login.
- **Data handled:** credenziali Discogs; nomi e indirizzi dei compratori (ordini); foto dei dischi inviate all'AI.
- **Countries and sectors:** Italia/UE (GDPR per i dati dei compratori).
- **Authorisation confirmed by:** Alessandro (codice del proprio progetto), 2026-10-19
- **In scope:** app-ios/ (app + supabase). **Out of scope:** script Python nella radice, pacchetti Swift di terzi.
- **Repository:** privata. Register committed: no (lasciato locale).
- **Connectors and consent:** Supabase (sola lettura: advisor, permessi e policy).
- **Gate:** predefinito.
- **Coverage:** Ridotta: segreti, codice e dipendenze controllati solo a mano (nessuno scanner installato nel container).

## Attack surface map
- Entry points: Edge Functions ai-cover, memoria, voce (POST, JWT); URL scheme vinylhustler://oauth; attività in background ordini.
- Autenticazione: Sign in with Apple -> sessione Supabase; Discogs con token personale o OAuth 1.0a (PLAINTEXT su HTTPS).
- Autorizzazione: RLS lettura propria; scritture solo via service role; is_admin per la pronuncia.
- Dati ed esterni: Postgres (profili, consumi, memoria condivisa, pronuncia), bucket 'voce'; Discogs, Anthropic, ElevenLabs.
- AI: ai-cover (foto -> dischi, output JSON a schema), memoria condivisa alimentata dagli utenti.
- Dimensione: ~7.700 righe (Swift, TypeScript, SQL).

## Hotspots
1. Credenziali Discogs nella build. 2. Tetti di spesa delle funzioni. 3. Memoria condivisa (scritture di utenti verso tutti). 4. Richieste di rete con credenziali.
