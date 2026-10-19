# Registro sicurezza · Vinyl Hustler

Run R1 · commit 0bcd9e7 · 2026-10-19 · Gate: **NON SUPERATO** (1 High aperto) · Copertura: **Ridotta** (nessuno scanner: solo revisione manuale + controlli Supabase)

| ID | Gravità | Certezza | Titolo | Dove |
|---|---|---|---|---|
| SEC-001 | High | Confirmed | Token personale Discogs dentro l'app compilata | `app-ios/Config/Info.plist:8` |
| SEC-002 | Medium | Confirmed | Tetti mensili AI e voce superabili con richieste in parallelo | `app-ios/supabase/functions/ai-cover/index.ts:83` |
| SEC-003 | Medium | Confirmed | Memoria condivisa: titolo e copertina scritti da qualunque utente e mostrati a tutti | `app-ios/supabase/functions/memoria/index.ts:57` |
| SEC-004 | Low | Confirmed | download() manda le credenziali Discogs a qualunque indirizzo | `app-ios/VinylHustler/Discogs/DiscogsClient.swift:240` |
| SEC-005 | Low | Confirmed | ai-cover: corpo della richiesta e foto non validati | `app-ios/supabase/functions/ai-cover/index.ts:89` |
| SEC-006 | Info | Confirmed | Tabelle con permessi di base ancora concessi ad anon/authenticated | `app-ios/supabase/migrations/001_schema.sql:50` |
| SEC-007 | Info | Confirmed | Indirizzo del compratore copiato negli appunti condivisi | `app-ios/VinylHustler/Features/4_Ordini/OrdersView.swift:408` |

## SEC-001 · High · Token personale Discogs dentro l'app compilata
- **OWASP/CWE:** A07:2025 · CWE-798
- **Prova:** Secrets.xcconfig (sul Mac) riempie DISCOGS_PERSONAL_TOKEN e l'Info.plist lo copia in chiaro dentro ogni build, Debug e Release.
- **Impatto:** Chiunque riceva un file dell'app (TestFlight, ad hoc) può leggere il token e controllare l'account venditore Discogs: annunci, prezzi, ordini, indirizzi dei compratori. Oggi l'app è solo sui due telefoni del team: diventa Critical appena si distribuisce.
- **Correzione:** Togliere la chiave DISCOGS_PERSONAL_TOKEN dall'Info.plist delle build Release (o del tutto) e usare solo 'Accedi con Discogs' (OAuth) o il token incollato a mano, salvato nel Portachiavi.
- **Posizioni:** `app-ios/Config/Info.plist:8`, `app-ios/VinylHustler/App/VinylHustlerApp.swift:99`

## SEC-002 · Medium · Tetti mensili AI e voce superabili con richieste in parallelo
- **OWASP/CWE:** A06:2025 · CWE-362
- **Prova:** Il consumo si legge prima e si somma solo dopo la chiamata ad Anthropic/ElevenLabs: N richieste partite insieme vedono tutte lo stesso consumo vecchio.
- **Impatto:** Un utente con l'app può spendere oltre il tetto (crediti Anthropic ed ElevenLabs di Matteo) mandando molte richieste insieme.
- **Correzione:** Una funzione SQL che controlla e prenota il budget in un solo passo (update ... where consumo + stima <= tetto returning), chiamata prima del fornitore; più un limite di richieste al minuto per utente.
- **Posizioni:** `app-ios/supabase/functions/ai-cover/index.ts:83`, `app-ios/supabase/functions/voce/index.ts:95`

## SEC-003 · Medium · Memoria condivisa: titolo e copertina scritti da qualunque utente e mostrati a tutti
- **OWASP/CWE:** A08:2025 · CWE-345 · LLM04
- **Prova:** learn accetta release_id, title e cover (URL qualsiasi) dal telefono; lookup li restituisce agli altri utenti, che caricano l'immagine da quell'URL.
- **Impatto:** Con l'app distribuita, chiunque può 'insegnare' dischi sbagliati, titoli offensivi o copertine da un server suo (vede IP e orari di chi apre la scheda). Oggi gli utenti sono 2.
- **Correzione:** Sul server ricavare titolo e copertina dalla release Discogs (o accettare solo URL https di i.discogs.com / st.discogs.com) e fidarsi di un abbinamento solo dopo 2+ conferme di persone diverse.
- **Posizioni:** `app-ios/supabase/functions/memoria/index.ts:57`

## SEC-004 · Low · download() manda le credenziali Discogs a qualunque indirizzo
- **OWASP/CWE:** A01:2025 · CWE-201
- **Prova:** La funzione mette l'intestazione Authorization su qualsiasi URL ricevuto. Oggi nessuno la chiama.
- **Impatto:** Se in futuro le si passa un URL non di Discogs (es. una copertina dalla memoria condivisa), il token dell'utente finisce a quel server.
- **Correzione:** Toglierla, oppure mandare l'intestazione solo se l'host è api.discogs.com / *.discogs.com.
- **Posizioni:** `app-ios/VinylHustler/Discogs/DiscogsClient.swift:240`

## SEC-005 · Low · ai-cover: corpo della richiesta e foto non validati
- **OWASP/CWE:** A10:2025 · CWE-20
- **Prova:** req.json() senza catch (errore 500 con corpo non valido); le foto non sono controllate come stringhe base64 né per dimensione.
- **Impatto:** Richieste malformate producono errori 500 e chiamate inutili al fornitore; nessuna fuga di dati.
- **Correzione:** req.json().catch(() => ({})), accettare solo stringhe base64 sotto ~5 MB ciascuna.
- **Posizioni:** `app-ios/supabase/functions/ai-cover/index.ts:89`

## SEC-006 · Info · Tabelle con permessi di base ancora concessi ad anon/authenticated
- **OWASP/CWE:** A02:2025 · CWE-732
- **Prova:** RLS è attiva ovunque e blocca le scritture (solo policy di lettura propria), ma i GRANT predefiniti restano.
- **Impatto:** Nessun rischio oggi; se un giorno si disattiva RLS per errore, le tabelle diventano scrivibili.
- **Correzione:** revoke insert, update, delete on all tables in schema public from anon, authenticated; (e select da anon).
- **Posizioni:** `app-ios/supabase/migrations/001_schema.sql:50`

## SEC-007 · Info · Indirizzo del compratore copiato negli appunti condivisi
- **OWASP/CWE:** A04:2025 · CWE-200
- **Prova:** Gli appunti si sincronizzano sugli altri dispositivi Apple e restano finché non si copia altro.
- **Impatto:** Dati personali del compratore leggibili da altre app/dispositivi più a lungo del necessario.
- **Correzione:** UIPasteboard.general.setItems([[UTType.plainText.identifier: address]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
- **Posizioni:** `app-ios/VinylHustler/Features/4_Ordini/OrdersView.swift:408`

## Controllato e a posto
- Nessun segreto nella storia di Git (chiavi Anthropic, ElevenLabs, service role, token Discogs): ricerca su tutti i commit.
- Repository privata; Secrets.xcconfig, .env e supabase/.env in .gitignore.
- Chiavi Anthropic ed ElevenLabs solo nei secret di Supabase; nell'app solo URL e chiave pubblica (fatta per stare nell'app).
- Funzioni Supabase: verify_jwt attivo e utente controllato in ognuna; pronuncia modificabile solo dagli amministratori.
- Database: RLS attiva su tutte le 7 tabelle, nessuna policy di scrittura per l'app; funzioni SQL non chiamabili da anon/authenticated; bucket 'voce' privato.
- Credenziali Discogs dell'utente nel Portachiavi, non in chiaro.
- Advisor di sicurezza Supabase: solo avvisi INFO (tabelle senza policy, voluto).

## Triage dismissals
Nessuna.
