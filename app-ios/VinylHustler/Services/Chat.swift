import Foundation
import Supabase

/// V68 — CHAT tra gli utenti di Vinyl Hustler (come nel mock-up approvato, proposta 17).
/// Sul server (Supabase, progetto Vinyl Hustler): chat_messaggi, chat_contatti, chat_blocchi, chat_segnalazioni.
/// Ognuno vede solo i suoi messaggi; nessuno può scrivere a chi l'ha bloccato; le parole offensive le copre il server.
/// I messaggi si rileggono ogni pochi secondi mentre la Chat è aperta (ogni 30 s altrimenti).

struct DiscoChat: Codable, Hashable {
    var titolo: String
    var cond: String
    var posto: String
    var prezzo: Double
    var valuta: String
    var copertina: String?
}

struct MsgChat: Codable, Identifiable, Hashable {
    let id: Int
    let da: UUID
    let a: UUID
    let testo: String?
    let disco: DiscoChat?
    let tipo: String?
    var risposta: String?
    let creato: Date
    var letto: Date?
}

struct UtenteChat: Decodable, Identifiable, Hashable {
    let id: UUID
    let nome: String?
}

/// Una conversazione nell'elenco: l'altra persona e l'ultimo messaggio.
struct ConvChat: Identifiable {
    let id: UUID
    let ultimo: MsgChat
    let nonLetti: Int
    let richiesta: Bool
}

@MainActor @Observable
final class ChatStore {
    static let shared = ChatStore()

    private(set) var io: UUID?
    private(set) var messaggi: [MsgChat] = []
    private(set) var nomi: [UUID: String] = [:]
    private(set) var contatti: Set<UUID> = []
    private(set) var bloccati: Set<UUID> = []
    /// false = manca l'accesso con Apple (la chat passa dal server dell'app).
    private(set) var accesso = true
    private(set) var nomeOccupato = false
    var errore: String?
    /// La sezione Chat è quella guardata: si rilegge più spesso.
    var visibile = false

    private var client: SupabaseClient? { Backend.shared.client }
    private var giro: Task<Void, Never>?
    /// V73: giri fatti scaricando solo i messaggi nuovi, e se al prossimo giro si rilegge tutto.
    private var giriDaCompleta = 0
    private var completaSubito = true
    private var nomeRegistrato = ""

    var nonLetti: Int {
        guard let io else { return 0 }
        return messaggi.filter { $0.a == io && $0.letto == nil && !bloccati.contains($0.da) }.count
    }

    func nome(_ id: UUID) -> String { nomi[id] ?? "utente" }

    /// Le conversazioni, la più recente in alto (senza i bloccati).
    var conversazioni: [ConvChat] {
        guard let io else { return [] }
        var ultimi: [UUID: MsgChat] = [:]
        var mieScritte: Set<UUID> = []
        var nuovi: [UUID: Int] = [:]
        for m in messaggi {
            let altro = m.da == io ? m.a : m.da
            if m.da == io { mieScritte.insert(m.a) }
            if m.a == io && m.letto == nil { nuovi[altro, default: 0] += 1 }
            if let u = ultimi[altro], u.creato > m.creato { continue }
            ultimi[altro] = m
        }
        return ultimi
            .filter { !bloccati.contains($0.key) }
            .map { ConvChat(id: $0.key, ultimo: $0.value, nonLetti: nuovi[$0.key] ?? 0,
                            richiesta: !contatti.contains($0.key) && !mieScritte.contains($0.key)) }
            .sorted { $0.ultimo.creato > $1.ultimo.creato }
    }

    func messaggi(con altro: UUID) -> [MsgChat] {
        messaggi.filter { $0.da == altro || $0.a == altro }.sorted { $0.creato < $1.creato }
    }

    /// Parte (una volta): registra il nome Discogs e rilegge i messaggi a intervalli.
    func avvia(nome: String) {
        guard giro == nil else { return }
        giro = Task { @MainActor in
            while !Task.isCancelled {
                await carica(nome: nome)
                try? await Task.sleep(for: .seconds(visibile ? 4 : 30))
            }
        }
    }

    /// Dopo l'accesso con Apple: riparte subito.
    func riparti(nome: String) {
        completaSubito = true                               // aprendo la Chat si rilegge tutto
        giro?.cancel()
        giro = nil
        avvia(nome: nome)
    }

    func carica(nome: String) async {
        guard let client else { accesso = false; return }
        guard let utente = try? await client.auth.session.user else { accesso = false; return }
        accesso = true
        io = utente.id
        do {
            if nomeRegistrato != nome, !nome.isEmpty {
                let esito: String? = try await client.rpc("chat_registra", params: ["nome": nome]).execute().value
                nomeOccupato = esito == "occupato"
                nomeRegistrato = nome
            }
            let prima = nonLetti
            // V73: di solito si scaricano solo i messaggi nuovi; ogni 8 giri (circa 30 s con la Chat aperta), aprendo
            // la Chat o la prima volta si rilegge tutto (risposte alle schede, letti, contatti e blocchi)
            if completaSubito || giriDaCompleta >= 7 || messaggi.isEmpty {
                let ultimi: [MsgChat] = try await client.from("chat_messaggi").select()
                    .order("creato", ascending: false).limit(500).execute().value
                messaggi = ultimi.reversed()
                struct Contatto: Decodable { let contatto: UUID }
                struct Blocco: Decodable { let bloccato: UUID }
                let c: [Contatto] = try await client.from("chat_contatti").select("contatto").execute().value
                let b: [Blocco] = try await client.from("chat_blocchi").select("bloccato").execute().value
                contatti = Set(c.map(\.contatto))
                bloccati = Set(b.map(\.bloccato))
                giriDaCompleta = 0
                completaSubito = false
            } else {
                let ultimoID = messaggi.map(\.id).max() ?? 0
                let nuovi: [MsgChat] = try await client.from("chat_messaggi").select()
                    .gt("id", value: ultimoID).order("id", ascending: true).limit(200).execute().value
                let gia = Set(messaggi.map(\.id))
                messaggi.append(contentsOf: nuovi.filter { !gia.contains($0.id) })
                giriDaCompleta += 1
            }
            await caricaNomi()
            if nonLetti > prima { Suoni.schedaPronta() }
            errore = nil
        } catch {
            if error.isCancellation { return }
            errore = "Chat non aggiornata: " + error.localizedDescription
        }
    }

    private func caricaNomi() async {
        guard let client, let io else { return }
        var ids = Set(contatti)
        for m in messaggi { ids.insert(m.da == io ? m.a : m.da) }
        let mancano = ids.filter { nomi[$0] == nil }
        guard !mancano.isEmpty else { return }
        struct P: Encodable { let ids: [UUID] }
        if let lista: [UtenteChat] = try? await client.rpc("chat_nomi", params: P(ids: Array(mancano))).execute().value {
            for u in lista { nomi[u.id] = u.nome ?? "utente" }
        }
    }

    func cerca(_ q: String) async -> [UtenteChat] {
        guard let client, q.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        let lista: [UtenteChat] = (try? await client.rpc("chat_cerca", params: ["q": q]).execute().value) ?? []
        for u in lista { nomi[u.id] = u.nome ?? "utente" }
        return lista
    }

    func manda(a: UUID, testo: String? = nil, disco: DiscoChat? = nil, tipo: String? = nil) async -> Bool {
        guard let client else { return false }
        struct Nuovo: Encodable { let a: UUID; let testo: String?; let disco: DiscoChat?; let tipo: String? }
        do {
            let m: MsgChat = try await client.from("chat_messaggi")
                .insert(Nuovo(a: a, testo: testo, disco: disco, tipo: tipo), returning: .representation)
                .select().single().execute().value
            messaggi.append(m)
            return true
        } catch {
            errore = "Non inviato: " + error.localizedDescription
            return false
        }
    }

    func segnaLetti(_ chi: UUID) async {
        guard let client, let io, messaggi.contains(where: { $0.da == chi && $0.a == io && $0.letto == nil }) else { return }
        _ = try? await client.rpc("chat_letti", params: ["chi": chi]).execute()
        let ora = Date()
        for i in messaggi.indices where messaggi[i].da == chi && messaggi[i].a == io && messaggi[i].letto == nil {
            messaggi[i].letto = ora
        }
    }

    func rispondi(_ m: MsgChat, _ valore: String) async {
        guard let client else { return }
        struct P: Encodable { let messaggio: Int; let valore: String }
        _ = try? await client.rpc("chat_rispondi", params: P(messaggio: m.id, valore: valore)).execute()
        if let i = messaggi.firstIndex(where: { $0.id == m.id }) { messaggi[i].risposta = valore }
    }

    func aggiungi(_ chi: UUID) async {
        guard let client, let io else { return }
        struct C: Encodable { let proprietario: UUID; let contatto: UUID }
        _ = try? await client.from("chat_contatti").upsert(C(proprietario: io, contatto: chi), ignoreDuplicates: true).execute()
        contatti.insert(chi)
    }

    func blocca(_ chi: UUID) async {
        guard let client, let io else { return }
        struct B: Encodable { let chi: UUID; let bloccato: UUID }
        _ = try? await client.from("chat_blocchi").upsert(B(chi: io, bloccato: chi), ignoreDuplicates: true).execute()
        bloccati.insert(chi)
    }

    func sblocca(_ chi: UUID) async {
        guard let client, let io else { return }
        _ = try? await client.from("chat_blocchi").delete().eq("chi", value: io).eq("bloccato", value: chi).execute()
        bloccati.remove(chi)
    }

    func segnala(_ chi: UUID) async -> Bool {
        guard let client else { return false }
        struct S: Encodable { let segnalato: UUID; let motivo: String }
        do {
            _ = try await client.from("chat_segnalazioni").insert(S(segnalato: chi, motivo: "Segnalato dall'app")).execute()
            return true
        } catch { return false }
    }
}
