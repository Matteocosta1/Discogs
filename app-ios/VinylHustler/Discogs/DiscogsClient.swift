import Foundation

enum DiscogsError: LocalizedError {
    case notLoggedIn
    case http(Int, String)
    /// La pubblicazione potrebbe essere avvenuta (rete caduta dopo l'invio): mai ripetere alla cieca.
    case uncertain(String)
    case noResponse(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Non sei collegato a Discogs"
        case .http(let code, let msg): "Discogs \(code): \(msg)"
        case .uncertain(let m): "Esito incerto: \(m) (controlla su Discogs prima di riprovare)"
        case .noResponse(let p): "Nessuna risposta da Discogs per \(p)"
        }
    }
}

/// Una richiesta al secondo, sempre: Discogs ne concede 60 al minuto (per IP). Come DiscogsAPI di vendi.py.
actor RateLimiter {
    static let minInterval: TimeInterval = 1.05
    private var next = Date.distantPast
    private(set) var recent: [Date] = []      // per il contatore "API x/60" della Console

    func waitTurn() async {
        // Il posto in coda si prenota PRIMA di aspettare: due chiamate insieme non partono mai insieme.
        let slot = max(next, Date())
        next = slot.addingTimeInterval(Self.minInterval)
        let delay = slot.timeIntervalSinceNow
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        recent.append(Date())
        recent.removeAll { $0 < Date().addingTimeInterval(-60) }
    }

    /// Se Discogs dice che restano poche richieste, rallenta.
    func respect(remaining: Int?) {
        if let remaining, remaining <= 3 { next = max(next, Date().addingTimeInterval(15)) }
    }

    func usedLastMinute() -> Int {
        recent.filter { $0 > Date().addingTimeInterval(-60) }.count
    }
}

/// Le risposte del catalogo (release, master, prezzi suggeriti, statistiche, ricerche) valgono 10 minuti:
/// riconoscere, mostrare le versioni e calcolare il prezzo dello stesso disco chiede la release una volta sola.
actor ResponseCache {
    private var items: [URL: (Date, Data)] = [:]
    private let ttl: TimeInterval = 600

    static func cacheable(_ path: String) -> Bool {
        ["/releases/", "/masters/", "/marketplace/price_suggestions/", "/marketplace/stats/", "/database/search"]
            .contains { path.hasPrefix($0) }
    }

    func get(_ url: URL) -> Data? {
        guard let item = items[url], Date().timeIntervalSince(item.0) < ttl else { return nil }
        return item.1
    }

    func put(_ url: URL, _ data: Data) {
        if items.count > 500 { items = items.filter { Date().timeIntervalSince($0.value.0) < ttl } }
        items[url] = (Date(), data)
    }
}

/// Client delle API Discogs (porta di DiscogsAPI in vendi.py).
final class DiscogsClient: @unchecked Sendable {
    static let base = URL(string: "https://api.discogs.com")!
    let limiter = RateLimiter()
    var credentials: DiscogsCredentials?

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(credentials: DiscogsCredentials? = CredentialStore.load()) {
        self.credentials = credentials
    }

    // MARK: - Richiesta generica

    func request<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:],
                               body: [String: Any]? = nil) async throws -> T {
        let data = try await raw(method, path, query: query, body: body)
        return try decoder.decode(T.self, from: data)
    }

    func raw(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> Data {
        guard let credentials else { throw DiscogsError.notLoggedIn }
        var comps = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        // Dati del catalogo già chiesti da poco: si riusano, senza consumare una delle 60 richieste al minuto.
        let cacheable = method == "GET" && ResponseCache.cacheable(path)
        if cacheable, let hit = await cache.get(comps.url!) { return hit }
        let data = try await send(method, comps.url!, body: body, credentials: credentials, path: path)
        if cacheable { await cache.put(comps.url!, data) }
        return data
    }

    private let cache = ResponseCache()

    private func send(_ method: String, _ url: URL, body: [String: Any]?, credentials: DiscogsCredentials,
                      path: String) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(credentials.authorizationHeader(), forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for attempt in 0..<6 {
            await limiter.waitTurn()
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let http = response as! HTTPURLResponse
                await limiter.respect(remaining: Int(http.value(forHTTPHeaderField: "X-Discogs-Ratelimit-Remaining") ?? ""))
                switch http.statusCode {
                case 200..<300:
                    return data
                case 429:   // troppe richieste: non è stato creato nulla, si riprova dopo un minuto
                    try await Task.sleep(for: .seconds(60))
                case 500...:
                    if method == "POST" { throw DiscogsError.uncertain("errore del server \(http.statusCode)") }
                    try await Task.sleep(for: .seconds(5 * Double(attempt + 1)))
                default:
                    let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                    throw DiscogsError.http(http.statusCode, message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
                }
            } catch let error as URLError {
                if method == "POST" { throw DiscogsError.uncertain(error.localizedDescription) }
                try await Task.sleep(for: .seconds(5 * Double(attempt + 1)))
            }
        }
        throw DiscogsError.noResponse(path)
    }

    // MARK: - Account

    func identity() async throws -> Identity { try await request("GET", "/oauth/identity") }
    func user(_ username: String) async throws -> UserProfile { try await request("GET", "/users/\(username)") }

    // MARK: - Database

    /// Ricerca nel database Discogs. Solo vinili (format=Vinyl), come ALLOWED_FORMATS dello script.
    func search(_ params: [String: String]) async throws -> [SearchResult] {
        var q = params
        q["type"] = "release"
        q["format"] = "Vinyl"
        q["per_page"] = "25"
        let res: SearchResponse = try await request("GET", "/database/search", query: q)
        return res.results
    }

    func release(_ id: Int, currency: String? = nil) async throws -> Release {
        try await request("GET", "/releases/\(id)", query: currency.map { ["curr_abbr": $0] } ?? [:])
    }

    /// Tutte le stampe in vinile di un album (master), fino a 100.
    func masterVersions(_ masterID: Int) async throws -> [MasterVersion] {
        let page: MasterVersionsPage = try await request("GET", "/masters/\(masterID)/versions",
                                                         query: ["per_page": "100", "format": "Vinyl"])
        return page.versions
    }

    /// Prezzi suggeriti per grado: chiavi "Mint (M)", "Near Mint (NM or M-)", ...
    func priceSuggestions(_ id: Int) async throws -> [String: Money] {
        try await request("GET", "/marketplace/price_suggestions/\(id)")
    }

    func stats(_ id: Int, currency: String) async throws -> MarketplaceStats {
        try await request("GET", "/marketplace/stats/\(id)", query: ["curr_abbr": currency])
    }

    // MARK: - Annunci

    func createListing(releaseID: Int, condition: Grade, sleeve: Grade, price: Double,
                       externalID: String, location: String = "", status: String = "For Sale") async throws -> Int {
        // location: campo privato dell'annuncio (lo vede solo il venditore): dove sta il disco ("Scatola 12").
        let res: CreatedListing = try await request("POST", "/marketplace/listings", body: [
            "release_id": releaseID, "condition": condition.discogs, "sleeve_condition": sleeve.discogs,
            "price": price, "status": status, "external_id": externalID, "location": location,
        ])
        return res.listingId
    }

    func listing(_ id: Int) async throws -> Listing { try await request("GET", "/marketplace/listings/\(id)") }

    /// Modifica di un annuncio: si reinviano TUTTI i campi attuali (altrimenti Discogs azzera quelli mancanti),
    /// cambiando solo quelli in `changes` (come listing_edit_body dello script).
    func editListing(_ id: Int, changes: [String: Any]) async throws {
        let current = try await listing(id)
        var body: [String: Any] = [
            "release_id": current.release.id, "status": current.status,
            "price": current.price?.value ?? 0,
        ]
        if let c = current.condition { body["condition"] = c }
        if let s = current.sleeveCondition { body["sleeve_condition"] = s }
        if let c = current.comments { body["comments"] = c }
        if let e = current.externalId { body["external_id"] = e }
        if let l = current.location { body["location"] = l }
        body.merge(changes) { _, new in new }
        _ = try await raw("POST", "/marketplace/listings/\(id)", body: body)
    }

    func deleteListing(_ id: Int) async throws {
        _ = try await raw("DELETE", "/marketplace/listings/\(id)")
    }

    /// Inventario nell'ordine della pagina Discogs (dal più recente).
    func inventory(username: String, status: String) async throws -> [Listing] {
        var all: [Listing] = []
        var page = 1
        while true {
            let res: InventoryPage = try await request("GET", "/users/\(username)/inventory", query: [
                "status": status, "page": String(page), "per_page": "100", "sort": "listed", "sort_order": "desc",
            ])
            all += res.listings
            if page >= res.pagination.pages { return all }
            page += 1
        }
    }

    func orders(page: Int = 1) async throws -> OrdersPage {
        try await request("GET", "/marketplace/orders", query: [
            "page": String(page), "per_page": "50", "sort": "id", "sort_order": "desc",
        ])
    }

    /// Scarica un'immagine di Discogs (conta nel limite, come le altre richieste).
    func download(_ url: String) async throws -> Data {
        guard let u = URL(string: url), let credentials else { throw DiscogsError.notLoggedIn }
        var req = URLRequest(url: u, timeoutInterval: 30)
        req.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(credentials.authorizationHeader(), forHTTPHeaderField: "Authorization")
        await limiter.waitTurn()
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }
}
