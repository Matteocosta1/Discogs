import Foundation
import Observation
import SwiftUI
import UIKit
import WebKit

// PROGRAMMINO «CARRELLO DISCOGS» (ramo claude/carrello-discogs) — SPENTO.
//
// Il carrello dell'app e il carrello di Discogs lavorano in parallelo, sullo stesso account:
//   · «Aggiungi al carrello» su una copia: va nel nostro carrello e il programmino, in una pagina Discogs nascosta dentro
//     l'app (con l'accesso dell'utente, lo stesso delle pagine Discogs aperte nell'app), apre QUELLA copia e preme «Add to Cart»;
//   · tolta dal nostro carrello: il programmino la toglie anche dal carrello Discogs («Remove»);
//   · aprendo il Carrello (e tornando nell'app, al massimo ogni 30 minuti) legge il carrello Discogs e allinea il nostro:
//     tolta su Discogs → tolta anche qui; comprata da me → negli ACQUISTI; comprata da un altro → «Venduta».
//   · ogni azione si scrive nel REGISTRO del Carrello; se qualcosa non riesce lo dice e non riprova all'infinito.
//
// REGOLA: si accende SOLO con il permesso scritto di Discogs (le regole delle loro API vietano i sistemi automatici
// sulle loro pagine senza permesso). Finché `acceso` è falso non parte nessuna pagina, nessun tocco, nessuna lettura:
// l'app è identica alla V92. Gli indirizzi e i tasti della pagina Discogs vanno verificati sul sito vero il giorno in cui
// si accende (qui non si può: provarli adesso sarebbe già usarlo).

@MainActor
@Observable
final class CarrelloDiscogs {
    static let shared = CarrelloDiscogs()

    /// L'interruttore: falso finché Discogs non dà il permesso scritto.
    nonisolated static let acceso = false

    /// Ogni quanto, al massimo, si riallinea tornando nell'app.
    private static let ogniQuanto: TimeInterval = 30 * 60

    enum Stato: Equatable {
        case fermo
        case lavoro(String)
        case serveAccesso
    }

    struct Riga: Codable, Identifiable, Hashable {
        var id = UUID()
        var quando: Date
        var testo: String
        var ok: Bool
    }

    private(set) var stato: Stato = .fermo
    private(set) var registro: [Riga] = CarrelloDiscogs.leggiRegistro()
    private(set) var ultimoAllineo: Date?
    /// Le copie che il programmino sta mettendo o togliendo adesso (per «Aggiungo al carrello Discogs…»).
    private(set) var inCorso: Set<Int> = []
    /// I dischi (release) per cui sta scegliendo la copia da mettere nei due carrelli.
    private(set) var dischiInCorso: Set<Int> = []

    private let robot = RobotDiscogs()
    private var coda: Task<Void, Never>?

    private init() {}

    // MARK: Le azioni

    /// La copia è entrata nel nostro carrello: la mette nel carrello Discogs.
    func aggiungi(_ copia: Int, nome: String) {
        guard Self.acceso else { return }
        inCorso.insert(copia)
        inFila { [weak self] in
            guard let self else { return }
            defer { self.inCorso.remove(copia) }
            self.stato = .lavoro("Metto nel carrello Discogs…")
            do {
                let esito = try await self.robot.aggiungi(copia)
                Carrello.shared.segnaNelCarrelloDiscogs(copia, true)
                self.scrivi(esito == .gia ? "Era già nel carrello Discogs: \(nome)" : "Messa nel carrello Discogs: \(nome)", ok: true)
            } catch let e as RobotDiscogs.Errore {
                self.fallito(e, "Non sono riuscito a metterla nel carrello Discogs: \(nome)")
            } catch {
                self.scrivi("Non sono riuscito a metterla nel carrello Discogs: \(nome)", ok: false)
            }
            self.stato = self.stato == .serveAccesso ? .serveAccesso : .fermo
        }
    }

    /// Aggiunto un disco (non una copia): il carrello Discogs vuole una copia precisa. Il programmino legge le copie in vendita
    /// di quel disco, sceglie la migliore per qualità-prezzo, la mette nel nostro carrello (con prezzo, condizioni e venditore)
    /// e nel carrello Discogs.
    func aggiungiDisco(_ release: Int, nome: String, valuta: String) {
        guard Self.acceso else { return }
        dischiInCorso.insert(release)
        inFila { [weak self] in
            guard let self else { return }
            defer { self.dischiInCorso.remove(release) }
            self.stato = .lavoro("Scelgo la copia migliore…")
            do {
                let copie = try await self.robot.copieInVendita(release)
                guard let scelta = Self.migliore(copie) else {
                    self.scrivi("Nessuna copia in vendita da mettere nel carrello: \(nome)", ok: false)
                    self.stato = .fermo
                    return
                }
                let c = try await DiscogsClient().copia(scelta.id, currency: valuta)   // i dati esatti della copia (API ufficiale)
                Carrello.shared.mettiCopia(c, valuta: valuta)
                let esito = try await self.robot.aggiungi(scelta.id)
                Carrello.shared.segnaNelCarrelloDiscogs(scelta.id, true)
                self.scrivi("\(esito == .gia ? "Era già nel carrello Discogs" : "Messa nei due carrelli") la copia migliore per qualità-prezzo: \(nome) · \(scelta.descrizione)", ok: true)
            } catch let e as RobotDiscogs.Errore {
                self.fallito(e, "Non sono riuscito a mettere nel carrello: \(nome)")
            } catch {
                self.scrivi("Non sono riuscito a mettere nel carrello: \(nome)", ok: false)
            }
            self.stato = self.stato == .serveAccesso ? .serveAccesso : .fermo
        }
    }

    /// Qualità-prezzo: il prezzo diviso il valore delle condizioni (disco 75%, copertina 25%); vince il più basso.
    /// Così una copia quasi nuova vince su una rovinata se costa poco di più, e a parità di condizioni vince la più economica.
    static func migliore(_ copie: [RobotDiscogs.CopiaPagina]) -> RobotDiscogs.CopiaPagina? {
        copie.filter { $0.prezzo > 0 }.min { $0.punteggio < $1.punteggio }
    }

    /// La copia è uscita dal nostro carrello: la toglie dal carrello Discogs.
    func togli(_ copia: Int, nome: String) {
        guard Self.acceso else { return }
        inFila { [weak self] in
            guard let self else { return }
            self.stato = .lavoro("Tolgo dal carrello Discogs…")
            do {
                let esito = try await self.robot.togli(copia)
                self.scrivi(esito == .gia ? "Non era nel carrello Discogs: \(nome)" : "Tolta dal carrello Discogs: \(nome)", ok: true)
            } catch let e as RobotDiscogs.Errore {
                self.fallito(e, "Non sono riuscito a toglierla dal carrello Discogs: \(nome)")
            } catch {
                self.scrivi("Non sono riuscito a toglierla dal carrello Discogs: \(nome)", ok: false)
            }
            self.stato = self.stato == .serveAccesso ? .serveAccesso : .fermo
        }
    }

    /// Tornando nell'app: si riallinea, ma al massimo ogni 30 minuti.
    func allineaSeServe(client: DiscogsClient) {
        guard Self.acceso, ultimoAllineo.map({ Date().timeIntervalSince($0) > Self.ogniQuanto }) ?? true else { return }
        Task { await allinea(client: client) }
    }

    /// Discogs → app: legge il carrello Discogs (e gli acquisti) e allinea il nostro.
    func allinea(client: DiscogsClient) async {
        guard Self.acceso else { return }
        await withCheckedContinuation { (fine: CheckedContinuation<Void, Never>) in
            inFila { [weak self] in
                defer { fine.resume() }
                guard let self else { return }
                await self.allineaOra(client: client)
            }
        }
    }

    private func allineaOra(client: DiscogsClient) async {
        let mie = Carrello.shared.voci.filter { $0.copia != nil && $0.nelCarrelloDiscogs == true }
        ultimoAllineo = Date()
        stato = .lavoro("Allineo con il carrello Discogs…")
        defer { if stato != .serveAccesso { stato = .fermo } }
        let suDiscogs: Set<Int>
        do {
            suDiscogs = try await robot.leggiCarrello()
        } catch let e as RobotDiscogs.Errore {
            fallito(e, "Non sono riuscito a leggere il carrello Discogs")
            return
        } catch {
            scrivi("Non sono riuscito a leggere il carrello Discogs", ok: false)
            return
        }
        // Discogs → app: le copie messe nel carrello Discogs dal sito o dall'app Discogs entrano anche nel nostro
        let nostre = Set(Carrello.shared.voci.compactMap(\.copia))
        for copia in suDiscogs.subtracting(nostre) {
            guard let c = try? await client.copia(copia, currency: Carrello.shared.voci.first?.valuta ?? "EUR", bassa: true), c.inVendita else { continue }
            Carrello.shared.mettiCopia(c, valuta: c.price?.currency ?? "EUR")
            Carrello.shared.segnaNelCarrelloDiscogs(copia, true)
            let nome = (c.release.description ?? "").replacingOccurrences(of: #"\s*\([^()]*\)\s*$"#, with: "", options: .regularExpression)
            scrivi("Aggiunta su Discogs: \(nome) · aggiunta anche qui", ok: true)
        }
        // gli acquisti servono solo se qualcosa è sparito dal carrello Discogs
        var comprate: Set<Int>?
        for v in mie {
            guard let copia = v.copia else { continue }
            let ancoraLa = suDiscogs.contains(copia)
            let inVendita = await ancoraInVendita(copia, valuta: v.valuta, client: client)
            if ancoraLa {
                if inVendita == false {                     // nel carrello Discogs ma non si può più comprare
                    Carrello.shared.esceDalCarrello(copia, comprata: false)
                    scrivi("Venduta a un altro: \(v.nome) · tolta dal carrello", ok: true)
                }
                continue
            }
            if comprate == nil { comprate = (try? await robot.leggiAcquisti()) ?? [] }
            if comprate?.contains(copia) == true {
                Carrello.shared.esceDalCarrello(copia, comprata: true)
                scrivi("Comprata: \(v.nome) · negli acquisti", ok: true)
            } else if inVendita == false {
                Carrello.shared.esceDalCarrello(copia, comprata: false)
                scrivi("Venduta a un altro: \(v.nome) · tolta dal carrello", ok: true)
            } else if inVendita == true {
                Carrello.shared.esceDalCarrello(copia, comprata: false)
                scrivi("Tolta su Discogs: \(v.nome) · tolta anche qui", ok: true)
            }
            // inVendita == nil: Discogs non ha risposto, si decide la prossima volta
        }
    }

    /// La copia è ancora in vendita? (API ufficiale: /marketplace/listings/{id}). nil = nessuna risposta.
    private func ancoraInVendita(_ copia: Int, valuta: String, client: DiscogsClient) async -> Bool? {
        do {
            return try await client.copia(copia, currency: valuta, bassa: true).inVendita
        } catch DiscogsError.http(let codice, _) where codice == 404 {
            return false
        } catch {
            return nil
        }
    }

    /// Dopo l'accesso a Discogs (pagina aperta dall'utente) si può riprendere.
    func accessoFatto() {
        if stato == .serveAccesso { stato = .fermo }
    }

    // MARK: Fila e registro

    /// Una cosa alla volta, nell'ordine in cui arrivano.
    private func inFila(_ lavoro: @escaping @MainActor () async -> Void) {
        let prima = coda
        coda = Task { @MainActor in
            await prima?.value
            await lavoro()
        }
    }

    private func fallito(_ e: RobotDiscogs.Errore, _ testo: String) {
        if e == .serveAccesso {
            stato = .serveAccesso
            scrivi("Serve l'accesso a Discogs: \(testo.lowercased())", ok: false)
        } else {
            scrivi("\(testo) (\(e.descrizione))", ok: false)
        }
    }

    private func scrivi(_ testo: String, ok: Bool) {
        registro.insert(Riga(quando: Date(), testo: testo, ok: ok), at: 0)
        if registro.count > 50 { registro.removeLast(registro.count - 50) }
        if let d = try? JSONEncoder().encode(registro) { UserDefaults.standard.set(d, forKey: "vh.registroCarrelloDiscogs") }
    }

    private static func leggiRegistro() -> [Riga] {
        guard let d = UserDefaults.standard.data(forKey: "vh.registroCarrelloDiscogs") else { return [] }
        return (try? JSONDecoder().decode([Riga].self, from: d)) ?? []
    }
}

// MARK: - Il robot: una pagina Discogs nascosta

/// Una pagina Discogs nascosta dentro l'app, con l'accesso dell'utente (lo stesso archivio delle pagine Discogs visibili):
/// apre un indirizzo, aspetta che sia caricato, preme o legge. Una pagina alla volta, con calma (3 secondi fra una e l'altra),
/// al massimo due tentativi, poi si ferma e lo dice.
@MainActor
final class RobotDiscogs: NSObject, WKNavigationDelegate {
    enum Errore: Error, Equatable {
        case serveAccesso
        case tastoNonTrovato
        case paginaNonCaricata
        case tempoScaduto

        var descrizione: String {
            switch self {
            case .serveAccesso: "serve l'accesso a Discogs"
            case .tastoNonTrovato: "il tasto non c'è sulla pagina"
            case .paginaNonCaricata: "la pagina non si è caricata"
            case .tempoScaduto: "Discogs non ha risposto in tempo"
            }
        }
    }

    enum Esito { case fatto, gia }

    /// Una copia letta dalla pagina For Sale del disco.
    struct CopiaPagina: Decodable {
        var id: Int
        var prezzo: Double
        var media: String
        var sleeve: String

        /// Il valore delle condizioni, da Mint (1) a Poor.
        static func valore(_ grado: String) -> Double {
            let g = grado.lowercased()
            if g.hasPrefix("mint") { return 1 }
            if g.hasPrefix("near mint") { return 0.95 }
            if g.hasPrefix("very good plus") { return 0.8 }
            if g.hasPrefix("very good") { return 0.6 }
            if g.hasPrefix("good plus") { return 0.4 }
            if g.hasPrefix("good") { return 0.25 }
            if g.hasPrefix("fair") { return 0.15 }
            return 0.1
        }
        /// Prezzo diviso qualità (disco 75%, copertina 25%; senza copertina conta solo il disco): più basso = conviene di più.
        var punteggio: Double {
            let q = sleeve.isEmpty ? Self.valore(media) : Self.valore(media) * 0.75 + Self.valore(sleeve) * 0.25
            return prezzo / max(0.05, q)
        }
        var descrizione: String { [media, sleeve].filter { !$0.isEmpty }.joined(separator: " / ") }
    }

    // Indirizzi del sito (da verificare il giorno in cui si accende)
    private static let base = "https://www.discogs.com"
    private static func pagina(_ copia: Int) -> URL { URL(string: "\(base)/sell/item/\(copia)")! }
    private static let carrello = URL(string: "\(base)/sell/cart")!
    private static let acquisti = URL(string: "\(base)/sell/purchases")!

    private var web: WKWebView?
    private var attesa: CheckedContinuation<Void, Error>?
    /// Il caricamento in attesa (il tempo scaduto vale solo per il suo, non per la pagina dopo).
    private var giroAttesa = UUID()
    private var ultimaPagina = Date.distantPast

    // MARK: Le tre azioni

    func aggiungi(_ copia: Int) async throws -> Esito {
        try await tentativi {
            try await self.apri(Self.pagina(copia))
            let r = try await self.esegui(Self.jsAggiungi) as? String ?? "manca"
            if r == "gia" { return .gia }
            guard r == "premuto" else { throw Errore.tastoNonTrovato }
            try await Task.sleep(for: .seconds(2))           // Discogs registra il tocco
            // controllo: ora la copia è nel carrello Discogs?
            let dentro = try await self.idsNelCarrello().contains(copia)
            guard dentro else { throw Errore.tastoNonTrovato }
            return .fatto
        }
    }

    func togli(_ copia: Int) async throws -> Esito {
        try await tentativi {
            try await self.apri(Self.carrello)
            let r = try await self.esegui(Self.jsTogli(copia)) as? String ?? "manca"
            if r == "assente" { return .gia }
            guard r == "premuto" else { throw Errore.tastoNonTrovato }
            try await Task.sleep(for: .seconds(2))
            let ancora = try await self.idsNelCarrello().contains(copia)
            guard !ancora else { throw Errore.tastoNonTrovato }
            return .fatto
        }
    }

    /// Le copie in vendita di un disco (la pagina For Sale, la prima: le copie dalla più economica).
    func copieInVendita(_ release: Int) async throws -> [CopiaPagina] {
        try await tentativi {
            try await self.apri(URL(string: "\(Self.base)/sell/release/\(release)?sort=price%2Casc")!)
            let testo = try await self.esegui(Self.jsCopieInVendita) as? String ?? "[]"
            return (try? JSONDecoder().decode([CopiaPagina].self, from: Data(testo.utf8))) ?? []
        }
    }

    func leggiCarrello() async throws -> Set<Int> {
        try await tentativi { try await self.idsNelCarrello() }
    }

    /// Le copie comprate di recente (pagina degli acquisti dell'utente).
    func leggiAcquisti() async throws -> Set<Int> {
        try await tentativi {
            try await self.apri(Self.acquisti)
            return try await self.ids()
        }
    }

    // MARK: Pagina, script, tentativi

    private func idsNelCarrello() async throws -> Set<Int> {
        try await apri(Self.carrello)
        return try await ids()
    }

    private func ids() async throws -> Set<Int> {
        let testo = try await esegui(Self.jsCopie) as? String ?? "[]"
        let numeri = (try? JSONDecoder().decode([String].self, from: Data(testo.utf8))) ?? []
        return Set(numeri.compactMap(Int.init))
    }

    /// Al massimo due tentativi; l'accesso mancante non si riprova (serve la persona).
    private func tentativi<T>(_ lavoro: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await lavoro()
        } catch Errore.serveAccesso {
            throw Errore.serveAccesso
        } catch {
            try await Task.sleep(for: .seconds(3))
            return try await lavoro()
        }
    }

    private func apri(_ url: URL) async throws {
        // con calma: almeno 3 secondi fra una pagina e l'altra
        let pausa = 3 - Date().timeIntervalSince(ultimaPagina)
        if pausa > 0 { try await Task.sleep(for: .seconds(pausa)) }
        ultimaPagina = Date()
        let w = pronta()
        let giro = UUID()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            attesa?.resume(throwing: Errore.paginaNonCaricata)
            attesa = c
            giroAttesa = giro
            w.load(URLRequest(url: url, timeoutInterval: 20))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                if self?.giroAttesa == giro { self?.chiudiAttesa(Errore.tempoScaduto) }
            }
        }
        // rimandati alla pagina di accesso: serve l'accesso della persona
        if w.url?.path.contains("/login") == true { throw Errore.serveAccesso }
        try await Task.sleep(for: .milliseconds(800))       // la pagina finisce di disegnarsi
    }

    private func esegui(_ js: String) async throws -> Any? {
        try await pronta().evaluateJavaScript(js)
    }

    /// La pagina nascosta: 1×1, trasparente, dentro la finestra dell'app (così il sito gira come in una pagina vera).
    private func pronta() -> WKWebView {
        if let web { return web }
        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = .default()                  // lo stesso accesso delle pagine Discogs aperte nell'app
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: conf)
        w.alpha = 0.01
        w.isUserInteractionEnabled = false
        w.navigationDelegate = self
        let finestra = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        finestra?.addSubview(w)
        web = w
        return w
    }

    private func chiudiAttesa(_ errore: Error?) {
        guard let c = attesa else { return }
        attesa = nil
        if let errore { c.resume(throwing: errore) } else { c.resume() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { chiudiAttesa(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { chiudiAttesa(Errore.paginaNonCaricata) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { chiudiAttesa(Errore.paginaNonCaricata) }
    }

    // MARK: Gli script (cercano i tasti per la scritta, non per il disegno della pagina)

    /// «Add to Cart» sulla pagina della copia. Risposte: "premuto", "gia" (già nel carrello), "manca".
    private static let jsAggiungi = """
    (function () {
      var t = function (e) { return ((e.innerText || e.value || '') + '').trim().toLowerCase(); };
      var tasti = Array.prototype.slice.call(document.querySelectorAll('button, a, input[type=submit]'));
      if (tasti.some(function (e) { var x = t(e); return x === 'in cart' || x === 'in your cart' || x.indexOf('view cart') === 0; })) return 'gia';
      var b = tasti.filter(function (e) { return /^add to cart\\b/.test(t(e)); })[0];
      if (!b) return 'manca';
      b.click();
      return 'premuto';
    })();
    """

    /// «Remove» sulla riga della copia nel carrello. Risposte: "premuto", "assente", "manca".
    private static func jsTogli(_ copia: Int) -> String {
        """
        (function () {
          var a = document.querySelector('a[href*="/sell/item/\(copia)"]');
          if (!a) return 'assente';
          var riga = a.closest('tr, li, article, [class*="item"], [class*="Item"]') || a.parentElement;
          for (var i = 0; i < 6 && riga; i++) {
            var b = Array.prototype.slice.call(riga.querySelectorAll('button, a, input[type=submit]'))
              .filter(function (e) { return /^remove\\b/.test(((e.innerText || e.value || '') + '').trim().toLowerCase()); })[0];
            if (b) { b.click(); return 'premuto'; }
            riga = riga.parentElement;
          }
          return 'manca';
        })();
        """
    }

    /// Le copie della pagina For Sale: numero, prezzo, condizioni del disco e della copertina (lette dalla scritta), come JSON.
    private static let jsCopieInVendita = """
    (function () {
      var gradi = /(Mint \\(M\\)|Near Mint \\(NM or M-\\)|Very Good Plus \\(VG\\+\\)|Very Good \\(VG\\)|Good Plus \\(G\\+\\)|Good \\(G\\)|Fair \\(F\\)|Poor \\(P\\))/g;
      var visti = {}, out = [];
      Array.prototype.slice.call(document.querySelectorAll('a[href*="/sell/item/"]')).forEach(function (a) {
        var m = a.href.match(/\\/sell\\/item\\/(\\d+)/); if (!m || visti[m[1]]) return;
        var riga = a.closest('tr, li, article, [class*="item"], [class*="Item"]') || a.parentElement;
        var t = (riga && riga.innerText) || '';
        var g = t.match(gradi) || [];
        var p = t.match(/[€$£]\\s?([\\d.,]+)|([\\d.,]+)\\s?€/);
        if (!g.length || !p) return;
        var n = (p[1] || p[2]).replace(/\\.(?=\\d{3}\\b)/g, '').replace(',', '.');
        visti[m[1]] = 1;
        out.push({ id: +m[1], prezzo: parseFloat(n) || 0, media: g[0] || '', sleeve: g[1] || '' });
      });
      return JSON.stringify(out);
    })();
    """

    /// I numeri delle copie («/sell/item/123») presenti sulla pagina, come testo JSON.
    private static let jsCopie = """
    JSON.stringify(Array.from(new Set(Array.prototype.slice.call(document.querySelectorAll('a[href*="/sell/item/"]'))
      .map(function (a) { var m = a.href.match(/\\/sell\\/item\\/(\\d+)/); return m ? m[1] : null; })
      .filter(function (x) { return x; }))));
    """
}

// MARK: - Cosa si vede nell'app (solo col programmino acceso)

/// Sotto «Aggiungi al carrello» della copia: «Aggiungo al carrello Discogs…» / «Anche nel carrello Discogs ✓».
struct StatoCopiaDiscogs: View {
    let copia: Int
    private let programmino = CarrelloDiscogs.shared
    private let carrello = Carrello.shared

    var body: some View {
        if CarrelloDiscogs.acceso && (programmino.inCorso.contains(copia) || carrello.nelCarrelloDiscogs(copia)) {
            Text(programmino.inCorso.contains(copia) ? "Aggiungo al carrello Discogs…" : "Anche nel carrello Discogs ✓")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(programmino.inCorso.contains(copia) ? Theme.muted : Theme.glow)
        }
    }
}

/// Nel Carrello: ACQUISTI e REGISTRO (cosa ha fatto il programmino e quando), e «Accedi a Discogs» quando serve.
struct SezioniCarrelloDiscogs: View {
    let apriWeb: (PaginaWeb) -> Void
    private let programmino = CarrelloDiscogs.shared
    private let carrello = Carrello.shared

    var body: some View {
        if CarrelloDiscogs.acceso {
            VStack(alignment: .leading, spacing: 10) {
                if programmino.stato == .serveAccesso {
                    Button {
                        Suoni.tocco()
                        programmino.accessoFatto()
                        apriWeb(PaginaWeb(url: URL(string: "https://www.discogs.com/login")!))
                    } label: {
                        Text("Accedi a Discogs").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.accent, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
                if case .lavoro(let testo) = programmino.stato {
                    Text(testo).font(Theme.mono(10, .bold)).tracking(1.2).foregroundStyle(Theme.muted)
                }
                if !carrello.acquisti.isEmpty {
                    titolo("ACQUISTI · \(carrello.acquisti.count)")
                    ForEach(carrello.acquisti, id: \.chiave) { v in
                        HStack {
                            Text(v.nome).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(v.prezzo.map { soldiIT($0, v.valuta) } ?? "—").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.money)
                        }
                        .padding(10)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                if !programmino.registro.isEmpty {
                    titolo("REGISTRO")
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(programmino.registro.prefix(10)) { r in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(r.quando.formatted(date: .omitted, time: .shortened)).monospacedDigit().foregroundStyle(Theme.muted)
                                Text(r.testo).foregroundStyle(r.ok ? Theme.text : Theme.warn)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 12))
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private func titolo(_ t: String) -> some View {
        Text(t).font(Theme.mono(10, .bold)).tracking(2).foregroundStyle(Theme.glow).padding(.top, 4)
    }
}
