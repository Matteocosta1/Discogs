import SwiftUI
import UIKit
import WebKit

// V83 — COPIE e COPIA (come nel mock-up approvato).
// «For Sale · N» (V84, al posto di «Compra su Discogs») nella scheda del disco apre, dentro l'app, la pagina di Discogs con tutte le copie in vendita di quella
// stampa (si ordinano e si filtrano con gli strumenti di Discogs). Quando si tocca una copia, la pagina non va avanti:
// si apre la nostra scheda COPIA con i dati di quella copia, chiesti a Discogs uno per volta (GET /marketplace/listings,
// nelle regole), e «Aggiungi al carrello». La pagina non viene mai letta né copiata: l'app guarda solo il link toccato.

/// Una copia in vendita, come la dà Discogs (/marketplace/listings/{id}).
struct CopiaInVendita: Decodable, Identifiable {
    struct Venditore: Decodable {
        struct Voti: Decodable {
            var rating: String?
            var total: Int?
        }
        var username: String
        var stats: Voti?
    }
    var id: Int
    var status: String?
    var price: Money?
    var condition: String?
    var sleeveCondition: String?
    var comments: String?
    var shipsFrom: String?
    var allowOffers: Bool?
    var uri: String?
    var seller: Venditore?
    var release: ListingRelease

    /// «99,8%» (Discogs lo dà come "99.8"); niente se il venditore non ha ancora voti.
    var voto: String? {
        guard let r = seller?.stats?.rating, let v = Double(r), v > 0 else { return nil }
        return v.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "it_IT"))) + "%"
    }
    var inVendita: Bool { (status ?? "For Sale") == "For Sale" }
    var link: URL? { uri.flatMap(URL.init(string:)) ?? URL(string: "https://www.discogs.com/sell/item/\(id)") }
}

extension DiscogsClient {
    /// I dati di una sola copia in vendita (pubblici su Discogs). `bassa`: dopo tutto il resto (rilettura del Carrello).
    func copia(_ id: Int, currency: String, bassa: Bool = false) async throws -> CopiaInVendita {
        try await request("GET", "/marketplace/listings/\(id)", query: ["curr_abbr": currency], bassa: bassa)
    }
}

/// Il numero della copia da un link di Discogs («…/sell/item/4413121980», anche con la lingua davanti: «/it/sell/item/…»).
func idCopia(_ url: URL?) -> Int? {
    guard let p = url?.path, let r = p.range(of: #"/sell/item/(\d+)"#, options: .regularExpression) else { return nil }
    return Int(p[r].split(separator: "/").last ?? "")
}

// MARK: - COPIE · N: la pagina di Discogs dentro l'app

struct CopieView: View {
    let releaseID: Int
    let quante: Int?
    let nome: String
    @Environment(\.dismiss) private var dismiss
    @State private var scelta: CopiaScelta?
    @State private var carico = true

    struct CopiaScelta: Identifiable { let id: Int }

    private var url: URL { URL(string: "https://www.discogs.com/sell/release/\(releaseID)?ev=rb")! }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold))
                    Text("discogs.com/sell/release/\(String(releaseID))").lineLimit(1)
                }
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(Theme.panelHigh, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                PaginaDiscogs(url: url, carico: $carico) { id in
                    Suoni.tocco()
                    scelta = CopiaScelta(id: id)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { if carico { ProgressView().tint(Theme.accent) } }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
            .sfondoHUD()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(quante.map { "COPIE · \($0)" } ?? "COPIE").font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { Suoni.testa(); dismiss() }.foregroundStyle(Theme.accent)
                }
            }
            .sheet(item: $scelta) { c in CopiaSheet(copiaID: c.id, nomeDisco: nome) }
        }
        .preferredColorScheme(.dark)
    }
}

/// La pagina vera di Discogs. Quando la persona tocca una copia («/sell/item/…») la pagina non va avanti e l'app apre
/// la sua scheda. Il tocco si vede in due modi: un ascolto del tocco sul link della copia (solo il link toccato,
/// nient'altro della pagina) e, se la pagina cambia indirizzo da sé, l'indirizzo nuovo (si torna indietro alla lista).
private struct PaginaDiscogs: UIViewRepresentable {
    let url: URL
    @Binding var carico: Bool
    let scegli: (Int) -> Void

    func makeCoordinator() -> Ponte { Ponte(scegli: scegli, carico: $carico) }

    func makeUIView(context: Context) -> WKWebView {
        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = .default()          // resta l'accesso a Discogs (carrello di Discogs, preferenze)
        let tocco = """
        document.addEventListener('click', function (e) {
          var a = e.target && e.target.closest ? e.target.closest('a[href*="/sell/item/"]') : null;
          if (!a) return;
          e.preventDefault(); e.stopPropagation();
          window.webkit.messageHandlers.copia.postMessage(a.href);
        }, true);
        """
        conf.userContentController.addUserScript(WKUserScript(source: tocco, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        conf.userContentController.add(context.coordinator, name: "copia")
        let w = WKWebView(frame: .zero, configuration: conf)
        w.allowsBackForwardNavigationGestures = true
        w.isOpaque = false
        w.backgroundColor = .black
        context.coordinator.osserva(w)
        w.load(URLRequest(url: url))
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {}

    static func dismantleUIView(_ w: WKWebView, coordinator: Ponte) {
        w.configuration.userContentController.removeScriptMessageHandler(forName: "copia")
        coordinator.osservatori.removeAll()
        w.stopLoading()
    }

    final class Ponte: NSObject, WKScriptMessageHandler {
        let scegli: (Int) -> Void
        let carico: Binding<Bool>
        var osservatori: [NSKeyValueObservation] = []
        init(scegli: @escaping (Int) -> Void, carico: Binding<Bool>) {
            self.scegli = scegli
            self.carico = carico
        }

        /// Caricamento (la rotellina) e indirizzo: se la pagina va da sola su una copia, si torna alla lista e si apre la scheda.
        func osserva(_ w: WKWebView) {
            let c = carico, s = scegli
            osservatori = [
                w.observe(\.isLoading, options: [.new]) { web, _ in
                    Task { @MainActor in c.wrappedValue = web.isLoading }
                },
                w.observe(\.url, options: [.new]) { web, _ in
                    Task { @MainActor in
                        guard let id = idCopia(web.url) else { return }
                        if web.canGoBack { web.goBack() }
                        s(id)
                    }
                },
            ]
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let t = message.body as? String, let id = idCopia(URL(string: t)) else { return }
            let s = scegli
            Task { @MainActor in s(id) }
        }
    }
}

// MARK: - V91 · Una pagina di Discogs dentro l'app (la copia scelta, il carrello)

/// La pagina da aprire: quella di una copia (per «Add to Cart») o il carrello di Discogs (per «Remove»).
/// I tasti di Discogs li preme la persona: le regole di Discogs vietano di farli premere a un programma.
struct PaginaWeb: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
    var indirizzo: String { url.host.map { $0.replacingOccurrences(of: "www.", with: "") + url.path } ?? url.absoluteString }
    static func copia(_ id: Int) -> PaginaWeb { PaginaWeb(url: URL(string: "https://www.discogs.com/sell/item/\(id)")!) }
    static let carrelloDiscogs = PaginaWeb(url: URL(string: "https://www.discogs.com/sell/cart")!)
}

struct PaginaWebView: View {
    let pagina: PaginaWeb
    @Environment(\.dismiss) private var dismiss
    @State private var carico = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold))
                    Text(pagina.indirizzo).lineLimit(1)
                }
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(Theme.panelHigh, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                WebSemplice(url: pagina.url, carico: $carico)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay { if carico { ProgressView().tint(Theme.accent) } }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
            .sfondoHUD()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("DISCOGS").font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { Suoni.testa(); dismiss() }.foregroundStyle(Theme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Il sito di Discogs così com'è, con l'accesso che resta (lo stesso delle COPIE): l'app non legge né tocca la pagina.
private struct WebSemplice: UIViewRepresentable {
    let url: URL
    @Binding var carico: Bool

    func makeCoordinator() -> Ponte { Ponte(carico: $carico) }

    func makeUIView(context: Context) -> WKWebView {
        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = .default()
        let w = WKWebView(frame: .zero, configuration: conf)
        w.allowsBackForwardNavigationGestures = true
        w.isOpaque = false
        w.backgroundColor = .black
        let c = $carico
        context.coordinator.osservatore = w.observe(\.isLoading, options: [.new]) { web, _ in
            Task { @MainActor in c.wrappedValue = web.isLoading }
        }
        w.load(URLRequest(url: url))
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {}

    static func dismantleUIView(_ w: WKWebView, coordinator: Ponte) {
        coordinator.osservatore = nil
        w.stopLoading()
    }

    final class Ponte {
        let carico: Binding<Bool>
        var osservatore: NSKeyValueObservation?
        init(carico: Binding<Bool>) { self.carico = carico }
    }
}

// MARK: - COPIA: la nostra scheda di una copia

struct CopiaSheet: View {
    let copiaID: Int
    let nomeDisco: String
    @Environment(Seller.self) private var seller
    @Environment(\.dismiss) private var dismiss
    @State private var copia: CopiaInVendita?
    @State private var errore = false
    @State private var web: PaginaWeb?
    private let carrello = Carrello.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let c = copia {
                        contenuto(c)
                    } else if errore {
                        Text("Questa copia non si riesce a leggere: forse è appena stata venduta.")
                            .font(.system(size: 14)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 60)
                    }
                }
                .padding(16)
            }
            .sfondoHUD()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("COPIA").font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { Suoni.testa(); dismiss() }.foregroundStyle(Theme.accent)
                }
            }
            .task(id: copiaID) {
                do { copia = try await seller.client.copia(copiaID, currency: seller.currency) } catch { errore = true }
            }
            .sheet(item: $web) { p in PaginaWebView(pagina: p) }
        }
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func contenuto(_ c: CopiaInVendita) -> some View {
        let nome = (c.release.description ?? nomeDisco)
            .replacingOccurrences(of: #"\s*\([^()]*\)\s*$"#, with: "", options: .regularExpression)
        HStack(alignment: .center, spacing: 14) {
            AsyncImage(url: c.release.thumbnail.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                .copertina(96)
            VStack(alignment: .leading, spacing: 4) {
                Text(nome).font(.system(size: 18, weight: .bold)).lineLimit(3)
                if let f = c.release.format, !f.isEmpty {
                    Text(f).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(2)
                }
            }
        }
        HStack(spacing: 6) {
            casella("PRICE", c.price.map { soldiIT($0.value, $0.currency ?? seller.currency) } ?? "—", Theme.money)
            casella("SHIPS FROM", c.shipsFrom ?? "—", Theme.text)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        VStack(alignment: .leading, spacing: 8) {
            riga("MEDIA CONDITION", c.condition ?? "—")
            riga("SLEEVE CONDITION", c.sleeveCondition ?? "—")
            riga("SELLER", [c.seller?.username, c.voto].compactMap { $0 }.joined(separator: " · "))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        if let t = c.comments?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            Text(t).font(.system(size: 14)).foregroundStyle(Color(white: 0.82)).fixedSize(horizontal: false, vertical: true)
        }
        if !c.inVendita {
            Text("Non è più in vendita su Discogs.").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.warn)
        }
        let dentro = carrello.contieneCopia(c.id)
        HStack(spacing: 10) {
            Button {
                if dentro {
                    let suDiscogs = carrello.suDiscogs(c.id), nelDiscogs = carrello.nelCarrelloDiscogs(c.id)
                    Suoni.svuota(); carrello.togliCopia(c.id)
                    if CarrelloDiscogs.acceso {
                        if nelDiscogs { CarrelloDiscogs.shared.togli(c.id, nome: nomeDisco) }     // programmino: «Remove» da solo
                    } else if suDiscogs { web = .carrelloDiscogs }          // V91: e dal carrello Discogs, con «Remove»
                } else {
                    Suoni.tocco()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    carrello.mettiCopia(c, valuta: seller.currency)
                    if CarrelloDiscogs.acceso {
                        CarrelloDiscogs.shared.aggiungi(c.id, nome: nomeDisco)              // programmino: «Add to Cart» da solo
                    } else {
                        // V91: subito la pagina di questa copia su Discogs, per metterla anche nel carrello Discogs («Add to Cart»)
                        carrello.segnaSuDiscogs(c.id)
                        web = .copia(c.id)
                    }
                }
            } label: {
                // V91: come gli altri tasti (dentro nero, bordo verde); nel carrello si accende
                Text(dentro ? "Nel carrello ✓" : "Aggiungi al carrello")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(dentro ? Theme.money : Theme.accent)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(dentro ? Theme.military : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(dentro ? Color.clear : Theme.accent, lineWidth: 1.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!c.inVendita && !dentro)
            if let url = c.link {
                Link(destination: url) {
                    Text("Anche su Discogs ↗").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.accent, lineWidth: 1.5))
                }
                .simultaneousGesture(TapGesture().onEnded { Suoni.tocco() })
            }
        }
        StatoCopiaDiscogs(copia: c.id)                      // programmino «Carrello Discogs»: solo se acceso
    }

    private func casella(_ t: String, _ v: String, _ colore: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t).font(Theme.mono(8.5, .bold)).tracking(1.1).foregroundStyle(Theme.muted)
            Text(v).font(.system(size: 15, weight: .bold)).foregroundStyle(colore).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func riga(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t).font(Theme.mono(8.5, .bold)).tracking(1.1).foregroundStyle(Theme.muted)
            Text(v).font(.system(size: 15, weight: .semibold))
        }
    }
}
