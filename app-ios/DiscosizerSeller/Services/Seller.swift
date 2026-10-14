import Foundation
import Observation
import SwiftData
import UIKit

/// Il "motore" dell'app: tiene il collegamento a Discogs e fa tutto quello che fanno vendi.py,
/// conferma_disco.py, cancella_bozze.py e verifica_inventario.py. Le schermate chiamano solo questo.
@MainActor
@Observable
final class Seller {
    let client = DiscogsClient()
    let store: CoverStore
    var username = ""
    var currency = "EUR"
    private(set) var credentials: DiscogsCredentials? = CredentialStore.load()
    var isLoggedIn: Bool { credentials != nil }
    var mode: RecognitionMode = UserDefaults.standard.string(forKey: "mode").flatMap(RecognitionMode.init) ?? .superVeloce {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }
    var rules: PriceRules = UserDefaults.standard.data(forKey: "rules").flatMap { try? JSONDecoder().decode(PriceRules.self, from: $0) } ?? PriceRules() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: "rules") }
    }
    var working = 0                      // dischi in riconoscimento adesso
    var lastError: String?
    /// Tempi: secondi a disco dell'ultimo lotto (per misurare la velocità, come lo script).
    var secondsPerDisc: [Double] = []

    private let queue = SerialQueue()

    init() {
        store = CoverStore(client: client)
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

    // MARK: - 1. Sessione: foto -> riconoscimento -> prezzo

    /// Salva le foto, crea il disco e lo mette in coda (un disco alla volta: limite Discogs).
    func addDisc(front: UIImage, back: UIImage, lot: String, media: Grade, sleeve: Grade, context: ModelContext) {
        let files = [front, back].compactMap { img -> String? in
            let name = "\(UUID().uuidString).jpg"
            guard let data = img.jpegData(compressionQuality: 0.85) else { return nil }
            try? data.write(to: AppFolders.photos.appendingPathComponent(name))
            return name
        }
        let disc = Disc(lot: lot, photoFiles: files, media: media, sleeve: sleeve)
        context.insert(disc)
        try? context.save()
        working += 1
        Task { await queue.run { await self.process(disc, context: context) } }
    }

    func photos(of disc: Disc) -> [UIImage] {
        disc.photoFiles.compactMap { UIImage(contentsOfFile: AppFolders.photos.appendingPathComponent($0).path) }
    }

    private func process(_ disc: Disc, context: ModelContext) async {
        let started = Date()
        defer {
            working -= 1
            secondsPerDisc.append(Date().timeIntervalSince(started))
            try? context.save()
        }
        let engine = RecognitionEngine(client: client, store: store, mode: mode,
                                       ai: mode.usesAI && Backend.shared.isConfigured ? AIService() : nil)
        let result = await engine.recognize(photos: photos(of: disc))
        disc.details = result.details.joined(separator: "; ")
        disc.method = result.method
        disc.aiCost += result.aiCost
        disc.candidates = result.candidates
        if let release = result.release {
            disc.releaseID = release.id
            disc.releaseTitle = release.description
            disc.coverFile = await store.mainCover(of: release.id)?.lastPathComponent
        }
        switch result.outcome {
        case .blocked:
            disc.status = .bloccato
            disc.reason = result.reason
        case .toCheck:
            disc.status = .daControllare
            disc.reason = result.reason
        case .found:
            await price(disc, verifiedByCode: result.byCode)
        }
    }

    /// Prezzo con la regola di sempre. Un disco riconosciuto SENZA codice che vale molto (collezionistico
    /// o sopra la soglia di controllo) non va in vendita senza un'occhiata.
    func price(_ disc: Disc, verifiedByCode: Bool) async {
        guard let rid = disc.releaseID else { return }
        do {
            let suggestions = try await client.priceSuggestions(rid)
            guard let suggested = suggestions[disc.media.discogs]?.value else {
                disc.status = .daControllare
                disc.reason = "Nessun prezzo suggerito da Discogs per \(disc.media.rawValue)"
                return
            }
            let release = try await client.release(rid, currency: currency)
            let stats = try await client.stats(rid, currency: currency)
            let market = MarketData(want: release.community?.want ?? 0, have: release.community?.have ?? 0,
                                    numForSale: stats.numForSale ?? 0, lowestPrice: stats.lowestPrice?.value,
                                    lowestCurrency: stats.lowestPrice?.currency ?? currency, formats: release.formatsText)
            let (p, calc) = PriceEngine.compute(suggested: suggested, market: market, grade: disc.media,
                                                currency: currency, rules: rules)
            let priceValue = NSDecimalNumber(decimal: p).doubleValue
            disc.price = priceValue
            disc.priceCalculation = calc
            let collector = PriceEngine.collectorScore(market, suggested: suggested, rules: rules)
            let risky = collector.score >= rules.collectorScore || priceValue > rules.reviewAbove
            if risky && !verifiedByCode {
                disc.status = .daControllare
                disc.reason = "Disco di valore riconosciuto senza codice: \(collector.reasons.joined(separator: ", "))"
            } else {
                disc.status = .pronto
                disc.reason = ""
            }
        } catch {
            disc.status = .daControllare
            disc.reason = "Prezzo non calcolato: \(error.localizedDescription)"
        }
    }

    // MARK: - 2. Revisione: i tasti della scheda

    /// CONFERMA: un click e il disco va in vendita (release proposta, prezzo, pubblicazione).
    func confirm(_ disc: Disc, release releaseID: Int? = nil) async {
        guard let rid = releaseID ?? disc.releaseID else { return }
        if rid != disc.releaseID {
            guard let release = try? await client.release(rid) else {
                lastError = "Release \(rid) non letta da Discogs: riprova"
                return
            }
            disc.releaseID = rid
            disc.releaseTitle = release.description
            disc.coverFile = await store.mainCover(of: rid)?.lastPathComponent
        }
        disc.method = "manuale"
        await price(disc, verifiedByCode: true)        // ha deciso una persona: niente controlli automatici
        if disc.status == .pronto { await publish(disc) }
    }

    /// È QUESTO: sceglie una delle alternative proposte (e pubblica, come Conferma).
    func choose(_ disc: Disc, candidate: Candidate) async { await confirm(disc, release: candidate.id) }

    /// ALTRA RELEASE: numero della release scritto a mano.
    func assign(_ disc: Disc, releaseID: Int) async { await confirm(disc, release: releaseID) }

    func publish(_ disc: Disc) async {
        guard let rid = disc.releaseID, let price = disc.price, disc.listingID == nil else { return }
        do {
            disc.listingID = try await client.createListing(releaseID: rid, condition: disc.media, sleeve: disc.sleeve,
                                                            price: price, externalID: disc.externalID)
            disc.status = .inVendita
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
