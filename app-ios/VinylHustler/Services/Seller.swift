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
    private(set) var credentials: DiscogsCredentials? = CredentialStore.load()
    var isLoggedIn: Bool { credentials != nil }
    var rules: PriceRules = UserDefaults.standard.data(forKey: "rules").flatMap { try? JSONDecoder().decode(PriceRules.self, from: $0) } ?? PriceRules() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: "rules") }
    }
    var working = 0                      // dischi in riconoscimento adesso
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
            currency = try await client.user(me.username).currAbbr ?? "EUR"
        } catch { lastError = error.localizedDescription }
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
        let signedIn = await Backend.shared.accessToken() != nil
        let recognizer = Recognizer(client: client, ai: signedIn ? AIService() : nil)
        let outcome = await recognizer.scan(images, video: video)
        let share = outcome.found.isEmpty ? outcome.aiCost : outcome.aiCost / Double(outcome.found.count)
        disc.aiCost += share
        guard let first = outcome.found.first else {
            disc.status = .daControllare
            disc.reason = outcome.note
            Voice.shared.say(found: [])
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
        Voice.shared.say(found: discs)
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
        } else {
            disc.status = .daControllare
            disc.reason = found.read.isEmpty ? "Non trovato su Discogs" : "Letto \"\(found.read)\", ma non trovato su Discogs"
        }
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
        await price(disc)
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

    /// RIFAI: il disco sparisce (foto comprese), come se non fosse mai stato fotografato.
    /// Resta solo come "tolto" nel database: cancellarlo mentre è sullo schermo farebbe chiudere l'app.
    func discard(_ disc: Disc) {
        for f in disc.photoFiles { try? FileManager.default.removeItem(at: AppFolders.photos.appendingPathComponent(f)) }
        disc.photoFiles = []
        disc.photoKinds = []
        disc.status = .tolto
        disc.reason = "Rifatto"
    }

    func publish(_ disc: Disc, status: String = "For Sale") async {
        guard let rid = disc.releaseID, let price = disc.price, disc.listingID == nil else { return }
        do {
            disc.listingID = try await client.createListing(releaseID: rid, condition: disc.media, sleeve: disc.sleeve,
                                                            price: price, externalID: disc.externalID,
                                                            location: disc.box, status: status)
            disc.status = status == "Draft" ? .bozza : .inVendita
        } catch DiscogsError.uncertain(let m) {
            lastError = "Esito incerto per \(disc.releaseTitle): \(m). Premi Verifica prima di riprovare."
        } catch {
            disc.status = .daControllare
            disc.reason = "Discogs ha rifiutato l'annuncio: \(error.localizedDescription)"
        }
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
