import Foundation
import Observation
import SwiftData
import UIKit

/// Il "motore" dell'app: tiene il collegamento a Discogs e fa tutto quello che fanno vendi.py,
/// conferma_disco.py, cancella_bozze.py e verifica_inventario.py. Le schermate chiamano solo questo.
@MainActor
@Observable
final class Seller {
    let client: DiscogsClient
    var username = ""
    var currency = "EUR"
    /// La valuta impostata sull'account Discogs (quella in cui Discogs legge i prezzi degli annunci).
    var discogsCurrency = "EUR"
    /// Settings › Valuta: vuota = quella di Discogs.
    static let currencies = ["EUR", "USD", "GBP", "CHF", "SEK", "JPY", "CAD", "AUD", "NZD", "MXN", "BRL", "ZAR"]
    private(set) var credentials: DiscogsCredentials? = CredentialStore.load()
    var isLoggedIn: Bool { credentials != nil }
    var rules: PriceRules = UserDefaults.standard.data(forKey: "rules").flatMap { try? JSONDecoder().decode(PriceRules.self, from: $0) } ?? PriceRules() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: "rules") }
    }
    var working = 0                      // dischi in riconoscimento adesso
    /// Le schede Discogs già lette (per il riquadro in alto e il lettore): release id -> scheda.
    var schede: [Int: Release] = [:]
    /// V59: il prezzo si calcola appena il disco è riconosciuto, prima di Vendi o Bozza.
    var prezzoInCorso: Set<UUID> = []
    var prezzoMancante: Set<UUID> = []
    var lastError: String?

    private let queue = SerialQueue()

    init() {
        let client = DiscogsClient()
        self.client = client
    }

    // MARK: - Account

    func connect(_ credentials: DiscogsCredentials) async {
        CredentialStore.save(credentials)
        self.credentials = credentials
        client.credentials = credentials
        await refreshAccount()
    }

    func refreshAccount() async {
        guard isLoggedIn else { return }
        do {
            let me = try await client.identity()
            username = me.username
            discogsCurrency = try await client.user(me.username).currAbbr ?? "EUR"
            let chosen = UserDefaults.standard.string(forKey: "valuta") ?? ""
            currency = chosen.isEmpty ? discogsCurrency : chosen
        } catch { lastError = error.localizedDescription }
    }

    /// Settings › Valuta. "" = usa quella dell'account Discogs.
    func setCurrency(_ code: String) {
        UserDefaults.standard.set(code, forKey: "valuta")
        currency = code.isEmpty ? discogsCurrency : code
    }

    func logout() {
        CredentialStore.delete()
        credentials = nil
        client.credentials = nil
        username = ""
    }

    // MARK: - 1. Sessione: scatto o video -> riconoscimento -> sì / no -> vendita

    /// Uno scatto o i fotogrammi di un video. Il disco compare subito ("sto guardando…"); se nelle foto
    /// ci sono più dischi, ne nascono altri. Restituisce il disco appena creato.
    @discardableResult
    func shoot(_ images: [UIImage], video: Bool, place: String, media: Grade, sleeve: Grade,
               context: ModelContext) -> Disc {
        let files = save(images, kind: video ? .fotogramma : .foto)
        let disc = Disc(lot: place, photoFiles: files.map(\.name), media: media, sleeve: sleeve)
        disc.photoKinds = files.map(\.kind)
        disc.box = place
        context.insert(disc)
        try? context.save()
        working += 1
        Task { await queue.run { await self.recognize(disc, images: images, video: video, context: context) } }
        return disc
    }

    /// "Altra foto": aggiunge uno scatto a un disco non riconosciuto e riprova.
    func addPhoto(_ image: UIImage, to disc: Disc, context: ModelContext) {
        let files = save([image], kind: .foto)
        disc.photoFiles += files.map(\.name)
        disc.photoKinds += files.map(\.kind)
        disc.status = .inLavorazione
        disc.reason = ""
        working += 1
        let images = photos(of: disc)
        Task { await queue.run { await self.recognize(disc, images: images, video: false, context: context) } }
    }

    private func save(_ images: [UIImage], kind: PhotoKind) -> [(name: String, kind: String)] {
        images.compactMap { image in
            let name = "\(UUID().uuidString).jpg"
            guard let data = image.jpegData(compressionQuality: 0.85),
                  (try? data.write(to: AppFolders.photos.appendingPathComponent(name))) != nil else { return nil }
            return (name, kind.rawValue)
        }
    }

    func photos(of disc: Disc) -> [UIImage] {
        disc.photoFiles.compactMap { UIImage(contentsOfFile: AppFolders.photos.appendingPathComponent($0).path) }
    }

    private func recognize(_ disc: Disc, images: [UIImage], video: Bool, context: ModelContext) async {
        defer {
            working -= 1
            try? context.save()
        }
        Suoni.guardo()
        let signedIn = await Backend.shared.accessToken() != nil
        let recognizer = Recognizer(client: client, ai: signedIn ? AIService() : nil)
        let outcome = await recognizer.scan(images, video: video)
        let share = outcome.found.isEmpty ? outcome.aiCost : outcome.aiCost / Double(outcome.found.count)
        disc.aiCost += share
        guard let first = outcome.found.first else {
            disc.status = .daControllare
            disc.reason = outcome.note
            Suoni.errore()
            announce([])
            return
        }
        // Il primo disco va in quello già creato; gli altri (video con più dischi) diventano dischi nuovi,
        // con le foto in cui si vedono.
        var discs: [Disc] = []
        for (n, found) in outcome.found.enumerated() {
            let target: Disc
            if n == 0 {
                target = disc
            } else {
                target = Disc(lot: disc.lot, photoFiles: found.images.compactMap { disc.photoFiles[safe: $0] },
                              media: disc.media, sleeve: disc.sleeve)
                target.photoKinds = found.images.compactMap { disc.photoKinds[safe: $0] }
                target.box = disc.box
                target.aiCost = share
                context.insert(target)
            }
            propose(found, to: target)
            discs.append(target)
        }
        if outcome.found.count > 1 {                // il primo tiene solo le sue foto
            disc.photoFiles = first.images.compactMap { disc.photoFiles[safe: $0] }
            disc.photoKinds = first.images.compactMap { disc.photoKinds[safe: $0] }
        }
        if discs.contains(where: { $0.status == .daConfermare }) { Suoni.riconosciuto() } else { Suoni.errore() }
        announce(discs)
    }

    /// La voce parte appena finito il suono di "riconosciuto", per non accavallarsi.
    private func announce(_ discs: [Disc]) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            Voice.shared.say(found: discs)
        }
    }

    private func propose(_ found: Recognizer.Found, to disc: Disc) {
        disc.method = found.method
        disc.details = found.read
        disc.candidates = found.candidates
        if let best = found.candidates.first {
            disc.releaseID = best.id
            disc.releaseTitle = best.title
            disc.status = .daConfermare
            disc.reason = ""
            Task { await loadVersions(disc) }
            Task { await anteprimaPrezzo(disc) }             // V59: il prezzo subito, prima di decidere
        } else {
            disc.status = .daControllare
            disc.reason = found.read.isEmpty ? "Non trovato su Discogs" : "Letto \"\(found.read)\", ma non trovato su Discogs"
        }
    }

    /// VERSIONI: dalla release proposta si risale all'album (master) e si prendono TUTTE le sue stampe in vinile.
    /// I candidati diventano: la proposta per prima, poi le altre stampe. Se l'album ha una stampa sola
    /// (o la release non ha un master) resta solo la proposta, e il tasto "Versioni" non compare.
    func loadVersions(_ disc: Disc) async {
        guard let rid = disc.releaseID, let best = disc.candidates.first(where: { $0.id == rid }) else { return }
        guard let master = (try? await client.release(rid, currency: currency))?.masterId,
              let versions = try? await client.masterVersions(master) else {
            if disc.releaseID == rid { disc.candidates = [best] }
            return
        }
        let artist = best.title.components(separatedBy: " - ").first ?? ""
        let others: [Candidate] = versions
            .filter { $0.id != rid }
            .filter { v in (v.majorFormats ?? ["Vinyl"]).contains("Vinyl") || (v.format ?? "").contains("Vinyl") }
            .map { v in
                let label = [v.label, v.catno].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                let extra = [label, v.country ?? "", v.released ?? "", v.format ?? ""].filter { !$0.isEmpty }
                let name = artist.isEmpty ? (v.title ?? "") : "\(artist) - \(v.title ?? "")"
                return Candidate(id: v.id, title: extra.isEmpty ? name : "\(name) (\(extra.joined(separator: ", ")))",
                                 coverURL: v.thumb)
            }
        guard disc.releaseID == rid else { return }      // nel frattempo ha scelto un'altra stampa
        disc.candidates = [best] + others
    }

    /// SÌ, È QUESTO: si legge la release (si può vendere?) e si calcola il prezzo. Non pubblica: decide il venditore.
    func accept(_ disc: Disc) async {
        guard let rid = disc.releaseID else { return }
        guard let release = try? await client.release(rid, currency: currency) else {
            lastError = "Discogs non risponde: riprova tra un attimo"
            return
        }
        disc.releaseTitle = release.description
        if release.blockedFromSale == true {
            disc.status = .bloccato
            disc.reason = "Discogs non permette di vendere questa release"
            return
        }
        teach(disc, releaseID: rid, title: release.description)
        await price(disc)
    }

    /// Insegna alla memoria condivisa: questo disco confermato è questa release (Vendi o Bozza passano da qui).
    private func teach(_ disc: Disc, releaseID: Int, title: String) {
        let photo = disc.photoKinds.first == PhotoKind.foto.rawValue ? photos(of: disc).first : nil
        // la lettura originale dell'AI (anche se poi l'utente ha scelto un'altra stampa: è proprio la correzione utile)
        let read = disc.details.hasPrefix("barcode") || disc.details.hasPrefix("memoria") ? nil : disc.details
        let cover = disc.coverURL?.absoluteString
        Task.detached(priority: .utility) {
            let impronta = photo.flatMap(Memoria.impronta)
            await Memoria.impara(impronta: impronta, lettura: read, release: releaseID, titolo: title, copertina: cover)
        }
    }

    /// CERCA A MANO: quello che l'utente legge sul disco (catalogo, barcode, artista, titolo…) -> le release trovate
    /// diventano le proposte da scegliere. false se Discogs non trova niente.
    func searchManual(_ disc: Disc, text: String) async -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return false }
        let tries = Self.manualTries(t)
        var found: [Candidate] = []
        for params in tries {
            guard let res = try? await client.search(params) else { continue }
            for c in Recognizer.candidates(Array(res.prefix(15)), limit: 15) where !found.contains(where: { $0.id == c.id }) {
                found.append(c)
            }
            if found.count >= 15 { break }
        }
        guard !found.isEmpty else {
            lastError = "Nessun disco trovato su Discogs per \"\(t)\""
            return false
        }
        disc.candidates = found
        return true
    }

    /// Le ricerche da provare su Discogs per un testo scritto a mano, in ordine.
    nonisolated static func manualTries(_ t: String) -> [[String: String]] {
        let digits = t.filter(\.isNumber)
        var tries: [[String: String]] = []
        if digits.count >= 10, digits.count == t.filter({ !$0.isWhitespace && $0 != "-" }).count {
            tries.append(["barcode": digits])                      // solo cifre, lungo: è un barcode
        }
        if !t.contains(" ") { tries.append(["catno": t]) }          // una parola sola: probabilmente il catalogo
        tries.append(["q": t])                                       // tutto insieme: artista, titolo, etichetta, anno…
        return tries
    }

    /// NO, È QUEST'ALTRO: una delle alternative proposte.
    func pick(_ disc: Disc, candidate: Candidate) async {
        disc.releaseID = candidate.id
        disc.releaseTitle = candidate.title
        disc.method = "scelto"
        await accept(disc)
    }

    /// Numero della release scritto a mano.
    func assign(_ disc: Disc, releaseID: Int) async {
        disc.releaseID = releaseID
        disc.method = "manuale"
        if !disc.candidates.contains(where: { $0.id == releaseID }) {
            disc.candidates.insert(Candidate(id: releaseID, title: "Release \(releaseID)"), at: 0)
        }
        await accept(disc)
    }

    /// La scheda Discogs di una release (una volta sola: poi resta qui; le richieste passano dalla cache).
    func scheda(_ id: Int) async -> Release? {
        if let r = schede[id] { return r }
        guard let r = try? await client.release(id, currency: currency) else { return nil }
        schede[id] = r
        return r
    }

    /// V59: appena riconosciuto, il prezzo con la regola di sempre, senza cambiare stato: il venditore lo vede
    /// sulla scheda e poi decide Vendi o Bozza. Vendi / Bozza lo ricalcolano (stesse risposte, già in cache).
    func anteprimaPrezzo(_ disc: Disc) async {
        guard let rid = disc.releaseID, disc.status == .daConfermare else { return }
        prezzoInCorso.insert(disc.id)
        prezzoMancante.remove(disc.id)
        defer { prezzoInCorso.remove(disc.id) }
        do {
            let suggestions = try await client.priceSuggestions(rid)
            guard let suggested = suggestions[disc.media.discogs]?.value, let release = await scheda(rid) else {
                prezzoMancante.insert(disc.id)
                return
            }
            let stats = try await client.stats(rid, currency: currency)
            let market = MarketData(want: release.community?.want ?? 0, have: release.community?.have ?? 0,
                                    numForSale: stats.numForSale ?? 0, lowestPrice: stats.lowestPrice?.value,
                                    lowestCurrency: stats.lowestPrice?.currency ?? currency, formats: release.formatsText)
            let (p, calc) = PriceEngine.compute(suggested: suggested, market: market, grade: disc.media,
                                                currency: currency, rules: rules)
            guard disc.releaseID == rid, disc.status == .daConfermare else { return }   // nel frattempo ha deciso
            disc.price = NSDecimalNumber(decimal: p).doubleValue
            disc.priceCalculation = calc
        } catch {
            prezzoMancante.insert(disc.id)
        }
    }

    /// Prezzo con la regola di sempre.
    func price(_ disc: Disc) async {
        guard let rid = disc.releaseID else { return }
        do {
            let suggestions = try await client.priceSuggestions(rid)
            guard let suggested = suggestions[disc.media.discogs]?.value else {
                disc.status = .daControllare
                disc.reason = "Discogs non suggerisce un prezzo per il grado \(disc.media.rawValue)"
                return
            }
            let release = try await client.release(rid, currency: currency)
            let stats = try await client.stats(rid, currency: currency)
            let market = MarketData(want: release.community?.want ?? 0, have: release.community?.have ?? 0,
                                    numForSale: stats.numForSale ?? 0, lowestPrice: stats.lowestPrice?.value,
                                    lowestCurrency: stats.lowestPrice?.currency ?? currency, formats: release.formatsText)
            let (p, calc) = PriceEngine.compute(suggested: suggested, market: market, grade: disc.media,
                                                currency: currency, rules: rules)
            disc.price = NSDecimalNumber(decimal: p).doubleValue
            disc.priceCalculation = calc
            disc.status = .pronto
            disc.reason = ""
        } catch {
            disc.status = .daControllare
            disc.reason = "Prezzo non calcolato: \(error.localizedDescription)"
        }
    }

    /// IN VENDITA / BOZZA: l'annuncio va su Discogs (in bozza resta invisibile ai compratori).
    func sell(_ disc: Disc, draft: Bool = false) async {
        await publish(disc, status: draft ? "Draft" : "For Sale")
    }

    /// DOPO: resta pronto in Revisione, sparisce dalla sessione.
    func park(_ disc: Disc) { disc.parked = true }

    /// CESTINO: se è su Discogs lo toglie anche da lì, poi il disco sparisce dall'app.
    func deleteDisc(_ disc: Disc) async {
        if let lid = disc.listingID {
            do { try await client.deleteListing(lid) } catch {
                lastError = "Non sono riuscito a toglierlo da Discogs: \(error.localizedDescription)"
                return
            }
            disc.listingID = nil
        }
        Suoni.errore()
        discard(disc)
    }

    /// RIFAI: il disco sparisce (foto comprese), come se non fosse mai stato fotografato.
    /// Resta solo come "tolto" nel database: cancellarlo mentre è sullo schermo farebbe chiudere l'app.
    func discard(_ disc: Disc) {
        dropPhotos(disc)
        disc.status = .tolto
        disc.reason = "Rifatto"
    }

    /// Cancella le foto del disco dal telefono (la scheda poi mostra la copertina di Discogs).
    func dropPhotos(_ disc: Disc) {
        for f in disc.photoFiles { try? FileManager.default.removeItem(at: AppFolders.photos.appendingPathComponent(f)) }
        disc.photoFiles = []
        disc.photoKinds = []
    }

    // MARK: - All'avvio

    /// Pulizia e ripresa, a ogni apertura dell'app:
    /// - i dischi rimasti su "Sto guardando…" (app chiusa a metà) si riconoscono di nuovo;
    /// - le foto dei dischi già su Discogs, venduti o tolti si cancellano, e anche i file che nessun disco usa più.
    func startup(context: ModelContext) {
        guard let all = try? context.fetch(FetchDescriptor<Disc>()) else { return }
        var used = Set<String>()
        for d in all {
            switch d.status {
            case .inVendita, .bozza, .tolto:
                dropPhotos(d)
            case .inLavorazione:
                let images = photos(of: d)
                if images.isEmpty {
                    d.status = .daControllare
                    d.reason = "Riconoscimento interrotto: fai un'altra foto"
                } else {
                    working += 1
                    let video = d.photoKinds.first == PhotoKind.fotogramma.rawValue
                    Task { await queue.run { await self.recognize(d, images: images, video: video, context: context) } }
                }
            default:
                break
            }
            used.formUnion(d.photoFiles)
        }
        let folder = AppFolders.photos
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !used.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        try? context.save()
    }

    func publish(_ disc: Disc, status: String = "For Sale") async {
        guard let rid = disc.releaseID, let price = disc.price, disc.listingID == nil else { return }
        do {
            disc.listingID = try await client.createListing(releaseID: rid, condition: disc.media, sleeve: disc.sleeve,
                                                            price: price, externalID: disc.externalID,
                                                            location: disc.box, status: status,
                                                            comments: description(for: disc), allowOffers: disc.allowOffers)
            disc.status = status == "Draft" ? .bozza : .inVendita
            dropPhotos(disc)                 // è su Discogs: la foto non serve più, libera spazio
        } catch DiscogsError.uncertain(let m) {
            lastError = "Esito incerto per \(disc.releaseTitle): \(m). Premi Verifica prima di riprovare."
        } catch {
            disc.status = .daControllare
            disc.reason = "Discogs ha rifiutato l'annuncio: \(error.localizedDescription)"
        }
    }

    /// La descrizione dell'annuncio: quella scritta nella scheda, altrimenti quella automatica (Console › Descrizione).
    func description(for disc: Disc) -> String {
        let manual = disc.comments.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return manual }
        return ListingText.build(media: disc.media.discogs, sleeve: disc.sleeve.discogs, tags: disc.noteTags, note: disc.noteText)
    }

    /// SCHEDA ANNUNCIO: modifica un annuncio già su Discogs (prezzo, condizioni, posizione, descrizione, offerte, stato).
    /// Restituisce l'annuncio come lo vede Discogs dopo la modifica, e allinea il disco dell'app.
    func updateListing(_ id: Int, changes: [String: Any], discs: [Disc]) async throws -> Listing {
        try await client.editListing(id, changes: changes)
        let after = try await client.listing(id)
        for d in discs where d.listingID == id || (after.externalId != nil && d.externalID == after.externalId) {
            d.listingID = id
            if let p = after.price?.value { d.price = p }
            if let c = after.condition, let g = Grade.from(discogs: c) { d.mediaRaw = g.rawValue }
            if let c = after.sleeveCondition, let g = Grade.from(discogs: c) { d.sleeveRaw = g.rawValue }
            if let l = after.location { d.box = l }
            if let c = after.comments { d.comments = c }
            if let a = after.allowOffers { d.allowOffers = a }
            d.status = after.status == "Draft" ? .bozza : .inVendita
        }
        return after
    }

    /// PUBBLICA PRONTI: tutti i dischi pronti in vendita.
    func publishReady(_ discs: [Disc]) async {
        for d in discs where d.status == .pronto { await publish(d) }
    }

    /// TOGLI: esce dall'inventario (e da Discogs, se era già online).
    func remove(_ disc: Disc) async {
        if let lid = disc.listingID {
            do { try await client.deleteListing(lid) } catch { lastError = error.localizedDescription; return }
        }
        disc.listingID = nil
        disc.status = .tolto
    }

    /// CONFERMA su una bozza: l'annuncio torna In vendita.
    func draftToSale(listingID: Int) async throws {
        try await client.editListing(listingID, changes: ["status": "For Sale"])
        let after = try await client.listing(listingID)
        if after.status != "For Sale" { throw DiscogsError.http(0, "Discogs non l'ha messo in vendita (stato: \(after.status))") }
    }

    // MARK: - 3. Magazzino

    /// Inventario vero su Discogs, nell'ordine della pagina Discogs. Allinea lo stato dei dischi dell'app.
    func syncInventory(discs: [Disc]) async throws -> [Listing] {
        let forSale = try await client.inventory(username: username, status: "For Sale")
        let drafts = try await client.inventory(username: username, status: "Draft")
        let byExternal = Dictionary((forSale + drafts).compactMap { l in l.externalId.map { ($0, l) } },
                                    uniquingKeysWith: { a, _ in a })
        for d in discs where d.listingID != nil || d.status == .inVendita || d.status == .bozza {
            if let l = byExternal[d.externalID] {
                d.listingID = l.id
                d.status = l.status == "Draft" ? .bozza : .inVendita
            } else if d.status == .inVendita || d.status == .bozza {
                d.status = .tolto           // venduto o cancellato: lo dicono gli Ordini
            }
        }
        return forSale + drafts
    }

    /// Cancella UNA bozza su Discogs (solo se è davvero una bozza: gli annunci online non si toccano).
    func deleteDraft(_ listingID: Int, discs: [Disc]) async throws {
        guard (try? await client.listing(listingID))?.status == "Draft" else {
            throw DiscogsError.http(0, "L'annuncio \(listingID) non è più una bozza: non l'ho cancellato")
        }
        try await client.deleteListing(listingID)
        for d in discs where d.listingID == listingID {
            d.listingID = nil
            d.status = .tolto
        }
    }

    /// Toglie da Discogs un annuncio, in vendita o in bozza (non uno già venduto). Lo chiede il Magazzino.
    func deleteListing(_ listingID: Int, discs: [Disc]) async throws {
        let status = (try? await client.listing(listingID))?.status
        guard status == "Draft" || status == "For Sale" else {
            throw DiscogsError.http(0, "L'annuncio \(listingID) non è più in vendita né in bozza: non l'ho toccato")
        }
        try await client.deleteListing(listingID)
        for d in discs where d.listingID == listingID {
            d.listingID = nil
            d.status = .tolto
        }
    }

    /// POSIZIONE A CHI NON CE L'HA: scrive `place` nel campo privato "location" degli annunci che ce l'hanno vuoto.
    /// Gli annunci che hanno già una posizione non si toccano; degli altri cambia solo la posizione.
    func fillMissingLocation(_ listings: [Listing], place: String, discs: [Disc]) async -> (done: Int, failed: Int) {
        var done = 0, failed = 0
        let empty = listings.filter { ($0.location ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                                      && ($0.status == "For Sale" || $0.status == "Draft") }
        for l in empty {
            do {
                try await client.editListing(l.id, changes: ["location": place])
                done += 1
                for d in discs where d.listingID == l.id || (l.externalId != nil && d.externalID == l.externalId) {
                    if d.box.trimmingCharacters(in: .whitespaces).isEmpty { d.box = place }
                }
            } catch { failed += 1 }
        }
        return (done, failed)
    }

    /// Cancella TUTTE le bozze su Discogs (gli annunci In vendita non si toccano). Restituisce quante.
    func deleteAllDrafts() async throws -> Int {
        var done = 0
        for l in try await client.inventory(username: username, status: "Draft") {
            guard (try? await client.listing(l.id))?.status == "Draft" else { continue }
            try await client.deleteListing(l.id)
            done += 1
        }
        return done
    }

    func apiUsedLastMinute() async -> Int { await client.limiter.usedLastMinute() }
}

/// Esegue un lavoro alla volta, nell'ordine di arrivo (i dischi si riconoscono uno dopo l'altro).
actor SerialQueue {
    private var tail: Task<Void, Never>?

    func run(_ job: @escaping @Sendable () async -> Void) async {
        let previous = tail
        let task = Task { await previous?.value; await job() }
        tail = task
        await task.value
    }
}
