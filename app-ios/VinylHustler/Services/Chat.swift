import Foundation
import Supabase
import UIKit

/// V68 — CHAT tra gli utenti di Vinyl Hustler (come nel mock-up approvato, proposta 17).
/// Sul server (Supabase, progetto Vinyl Hustler): chat_messaggi, chat_contatti, chat_blocchi, chat_segnalazioni.
/// Ognuno vede solo i suoi messaggi; nessuno può scrivere a chi l'ha bloccato; le parole offensive le copre il server.
/// I messaggi si rileggono ogni pochi secondi mentre la Chat è aperta (ogni 30 s altrimenti).
/// V74: nome in Chat («Nome · account Discogs»), foto private (spazio «chat-foto», 30 giorni),
/// schede Annuncio (solo dischi in vendita, si aprono su Discogs) e Parere; i dati di Discogs non si salvano
/// nel messaggio ma si rileggono da Discogs quando la scheda si vede (regole delle API di Discogs).

struct DiscoChat: Codable, Hashable {
    var titolo: String
    var cond: String
    var posto: String
    var prezzo: Double
    var valuta: String
    /// Solo nei messaggi vecchi (prima della V74): ora la copertina si rilegge da Discogs.
    var copertina: String?
    /// V74: l'annuncio su Discogs (scheda Annuncio).
    var listing: Int?
    /// V74: il disco su Discogs (pagina e copertina aggiornate).
    var release: Int?
    /// V74: "vendita" o "bozza".
    var stato: String?
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
    /// V74: percorso della foto nello spazio privato «chat-foto».
    var foto: String?
    /// V74: ora dell'ultima modifica (la mette il server): così arrivano subito anche risposte e «letto».
    var aggiornato: Date?
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
    /// V74: come gli altri ti vedono e ti trovano: «Nome · account Discogs».
    private(set) var mioNome = ""
    var errore: String?
    /// La sezione Chat è quella guardata: si rilegge più spesso.
    var visibile = false

    private var client: SupabaseClient? { Backend.shared.client }
    private var giro: Task<Void, Never>?
    /// V73: giri fatti scaricando solo i messaggi nuovi, e se al prossimo giro si rilegge tutto.
    private var giriDaCompleta = 0
    private var completaSubito = true
    private var nomeRegistrato = ""
    /// V74: l'ultima modifica già scaricata (messaggi nuovi, risposte, «letto»).
    private var ultimaModifica: Date?

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

    /// Il nome in Chat è il «Nome» di Settings (lo stesso della voce).
    static var nomeImpostato: String {
        (UserDefaults.standard.string(forKey: "userName") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parte (una volta): registra il nome in Chat e rilegge i messaggi a intervalli.
    func avvia(discogs: String) {
        guard giro == nil else { return }
        giro = Task { @MainActor in
            while !Task.isCancelled {
                await carica(discogs: discogs)
                try? await Task.sleep(for: .seconds(visibile ? 4 : 30))
            }
        }
    }

    /// Dopo l'accesso con Apple, aprendo la Chat o cambiando nome: riparte subito.
    func riparti(discogs: String) {
        completaSubito = true                               // aprendo la Chat si rilegge tutto
        giro?.cancel()
        giro = nil
        avvia(discogs: discogs)
    }

    func carica(discogs: String) async {
        guard let client else { accesso = false; return }
        guard let utente = try? await client.auth.session.user else { accesso = false; return }
        accesso = true
        io = utente.id
        do {
            let nome = Self.nomeImpostato
            let chiave = nome + "|" + discogs
            if nomeRegistrato != chiave, !discogs.isEmpty {
                let esito: String? = try await client.rpc("chat_registra", params: ["nome": nome, "discogs": discogs]).execute().value
                nomeOccupato = esito == "occupato"
                nomeRegistrato = chiave
                mioNome = nome.count >= 2 ? nome + " · " + discogs : discogs
            }
            let prima = nonLetti
            // V74: di solito si scarica solo quello che è cambiato dall'ultima volta (messaggi nuovi, risposte alle
            // schede, «letto»); ogni 15 giri (circa 1 minuto con la Chat aperta), aprendo la Chat o la prima volta
            // si rilegge tutto, con contatti e blocchi
            if completaSubito || giriDaCompleta >= 15 || messaggi.isEmpty {
                let ultimi: [MsgChat] = try await client.from("chat_messaggi").select()
                    .order("creato", ascending: false).limit(500).execute().value
                messaggi = ultimi.reversed()
                ultimaModifica = messaggi.compactMap(\.aggiornato).max()
                struct Contatto: Decodable { let contatto: UUID }
                struct Blocco: Decodable { let bloccato: UUID }
                let c: [Contatto] = try await client.from("chat_contatti").select("contatto").execute().value
                let b: [Blocco] = try await client.from("chat_blocchi").select("bloccato").execute().value
                contatti = Set(c.map(\.contatto))
                bloccati = Set(b.map(\.bloccato))
                giriDaCompleta = 0
                completaSubito = false
            } else {
                // 15 secondi di margine: un messaggio salvato proprio mentre si legge non va perso
                let da = (ultimaModifica ?? Date()).addingTimeInterval(-15)
                let cambiati: [MsgChat] = try await client.from("chat_messaggi").select()
                    .gt("aggiornato", value: ChatData.iso(da)).order("aggiornato", ascending: true).limit(200).execute().value
                for m in cambiati {
                    if let i = messaggi.firstIndex(where: { $0.id == m.id }) { messaggi[i] = m } else { messaggi.append(m) }
                }
                if let ultima = cambiati.compactMap(\.aggiornato).max() { ultimaModifica = max(ultimaModifica ?? ultima, ultima) }
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

    func manda(a: UUID, testo: String? = nil, disco: DiscoChat? = nil, tipo: String? = nil, foto: String? = nil) async -> Bool {
        guard let client else { return false }
        struct Nuovo: Encodable { let a: UUID; let testo: String?; let disco: DiscoChat?; let tipo: String?; let foto: String? }
        do {
            let m: MsgChat = try await client.from("chat_messaggi")
                .insert(Nuovo(a: a, testo: testo, disco: disco, tipo: tipo, foto: foto), returning: .representation)
                .select().single().execute().value
            if !messaggi.contains(where: { $0.id == m.id }) { messaggi.append(m) }
            return true
        } catch {
            errore = "Non inviato: " + error.localizedDescription
            return false
        }
    }

    /// V74: una foto nella chat. Si rimpicciolisce (lato lungo 1600 px, JPEG), si carica nello spazio privato
    /// «chat-foto» (<io>/<lui>/<id>.jpg: la vedono solo i due) e poi parte il messaggio.
    func mandaFoto(a: UUID, immagine: UIImage) async -> Bool {
        guard let io, let dati = FotoChat.jpeg(immagine) else { return false }
        let percorso = "\(io.uuidString.lowercased())/\(a.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        guard await FotoChat.carica(percorso, dati) else {
            errore = "Foto non inviata: riprova"
            return false
        }
        FotoChat.ricorda(percorso, UIImage(data: dati))
        return await manda(a: a, foto: percorso)
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

    func segnala(_ chi: UUID, messaggio: Int? = nil) async -> Bool {
        guard let client else { return false }
        struct S: Encodable { let segnalato: UUID; let messaggio: Int?; let motivo: String }
        do {
            _ = try await client.from("chat_segnalazioni")
                .insert(S(segnalato: chi, messaggio: messaggio, motivo: messaggio == nil ? "Segnalato dall'app" : "Foto segnalata dall'app")).execute()
            return true
        } catch { return false }
    }
}

/// V74: le foto della chat. Caricamento e lettura con l'accesso dell'utente (le regole del server lasciano
/// vedere ogni foto solo ai due della conversazione, e solo per 30 giorni).
@MainActor
enum FotoChat {
    static let giorni = 30
    private static let cache = NSCache<NSString, UIImage>()

    /// Lato lungo al massimo 1600 px, JPEG di buona qualità (sotto i 5 MB del server).
    static func jpeg(_ img: UIImage) -> Data? {
        let lato: CGFloat = 1600
        let s = img.size
        let k = min(1, lato / max(s.width, s.height, 1))
        let dim = CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
        let formato = UIGraphicsImageRendererFormat.default()
        formato.scale = 1
        let piccola = UIGraphicsImageRenderer(size: dim, format: formato).image { _ in img.draw(in: CGRect(origin: .zero, size: dim)) }
        return piccola.jpegData(compressionQuality: 0.8)
    }

    static func scaduta(_ m: MsgChat) -> Bool {
        Date().timeIntervalSince(m.creato) > Double(giorni) * 86_400
    }

    /// Quanti giorni mancano alla cancellazione.
    static func giorniRimasti(_ m: MsgChat) -> Int {
        max(0, giorni - Int(Date().timeIntervalSince(m.creato) / 86_400))
    }

    static func ricorda(_ percorso: String, _ img: UIImage?) {
        if let img { cache.setObject(img, forKey: percorso as NSString) }
    }

    static func carica(_ percorso: String, _ dati: Data) async -> Bool {
        guard let req = await richiesta("storage/v1/object/chat-foto/" + percorso, metodo: "POST") else { return false }
        var r = req
        r.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        r.setValue("false", forHTTPHeaderField: "x-upsert")
        guard let esito = try? await URLSession.shared.upload(for: r, from: dati) else { return false }
        return (200..<300).contains((esito.1 as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func immagine(_ percorso: String) async -> UIImage? {
        if let c = cache.object(forKey: percorso as NSString) { return c }
        guard let req = await richiesta("storage/v1/object/authenticated/chat-foto/" + percorso, metodo: "GET"),
              let esito = try? await URLSession.shared.data(for: req),
              (esito.1 as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: esito.0) else { return nil }
        cache.setObject(img, forKey: percorso as NSString)
        return img
    }

    private static func richiesta(_ strada: String, metodo: String) async -> URLRequest? {
        guard let base = AppConfig.supabaseURL, let token = await Backend.shared.accessToken() else { return nil }
        var req = URLRequest(url: base.appendingPathComponent(strada), timeoutInterval: 30)
        req.httpMethod = metodo
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        return req
    }
}
