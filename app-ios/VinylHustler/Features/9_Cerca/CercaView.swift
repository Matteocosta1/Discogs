import Combine
import SwiftUI
import UIKit
import UserNotifications

// V79 — 05 / CERCA (come nel mock-up approvato): cercare dischi su Discogs, ascoltarli, metterli nel Carrello
// e comprarli su Discogs. Discogs non ha un'API per comprare: l'acquisto si chiude sempre su Discogs
// («Compra su Discogs» apre la pagina del disco con le copie in vendita). Per ogni disco Discogs dà solo
// «da X € · N in vendita» (/marketplace/stats), non l'elenco delle copie.
// Regole delle API di Discogs: accanto ai dati la frase in inglese, ogni dato porta alla sua pagina Discogs,
// i prezzi non restano più di 6 ore (il Carrello li rilegge).

/// Un disco trovato (una stampa: la «release» di Discogs).
struct VoceCerca: Identifiable, Hashable {
    let id: Int
    let artista: String
    let album: String
    let anno: String
    let formato: String
    let etichetta: String
    let paese: String
    let copertina: URL?
    let miniatura: URL?
    let want: Int
    let have: Int
    let masterID: Int?
    let genere: String

    var nome: String { artista.isEmpty ? album : "\(artista) – \(album)" }
    var meta: String { [anno, formato, etichetta].filter { !$0.isEmpty }.joined(separator: " · ") }
    var linkCompra: URL? { URL(string: "https://www.discogs.com/sell/release/\(id)?ev=rb") }

    init(_ r: SearchResult) {
        id = r.id
        let parti = r.title.components(separatedBy: " - ")
        artista = parti.count > 1 ? parti[0] : ""
        album = parti.count > 1 ? parti.dropFirst().joined(separator: " - ") : r.title
        anno = r.year ?? ""
        formato = (r.format ?? []).first ?? ""
        etichetta = (r.label ?? []).first ?? ""
        paese = r.country ?? ""
        copertina = r.coverImage.flatMap(URL.init(string:))
        miniatura = r.thumb.flatMap(URL.init(string:))
        want = r.community?.want ?? 0
        have = r.community?.have ?? 0
        masterID = (r.masterId ?? 0) > 0 ? r.masterId : nil
        genere = (r.genre ?? []).first ?? ""
    }
}

/// «da X € · N in vendita» di una stampa, letto da Discogs (una richiesta per disco, al passo di una al secondo).
struct PrezzoCerca: Codable, Hashable {
    var da: Double?
    var inVendita: Int
    var valuta: String
}

@MainActor
@Observable
final class PrezziCerca {
    static let shared = PrezziCerca()
    private(set) var prezzi: [Int: PrezzoCerca] = [:]
    private var inCorso: Set<Int> = []

    func prezzo(_ id: Int) -> PrezzoCerca? { prezzi[id] }

    /// Legge (una volta) il prezzo di una stampa.
    func carica(_ id: Int, client: DiscogsClient, valuta: String) async {
        guard prezzi[id] == nil, !inCorso.contains(id) else { return }
        inCorso.insert(id)
        defer { inCorso.remove(id) }
        if let s = try? await client.stats(id, currency: valuta) {
            prezzi[id] = PrezzoCerca(da: s.lowestPrice?.value, inVendita: s.numForSale ?? 0, valuta: s.lowestPrice?.currency ?? valuta)
        }
    }

    /// Rilegge sempre (per il Carrello).
    func rileggi(_ id: Int, client: DiscogsClient, valuta: String) async -> PrezzoCerca? {
        if let s = try? await client.stats(id, currency: valuta) {
            let p = PrezzoCerca(da: s.lowestPrice?.value, inVendita: s.numForSale ?? 0, valuta: s.lowestPrice?.currency ?? valuta)
            prezzi[id] = p
            return p
        }
        return prezzi[id]
    }

    static func testo(_ p: PrezzoCerca?) -> String {
        guard let p else { return "…" }
        guard let da = p.da else { return "nessuno in vendita" }
        return "da " + soldiIT(da, p.valuta)
    }
}

// MARK: - I filtri, come su Discogs

struct FiltriCerca: Equatable {
    enum Ordine: Int, CaseIterable { case rilevanza, prezzo, recenti, cercati
        var nome: String { ["Rilevanza", "Prezzo più basso", "Più recenti", "Più cercati"][rawValue] }
    }
    var formato = "Tutti"
    var ordine: Ordine = .rilevanza
    var genere = ""
    var stile = ""
    var decennio = ""
    var paese = ""

    static let formati: [(String, String)] = [("Tutti", ""), ("Vinile", "Vinyl"), ("CD", "CD"), ("Cassetta", "Cassette")]
    static let generi = ["Electronic", "Rock", "Jazz", "Funk / Soul", "Hip Hop", "Pop", "Reggae", "Latin", "Blues", "Classical"]
    static let stili: [String: [String]] = [
        "Electronic": ["House", "Techno", "Ambient", "Trip Hop", "Electro", "IDM", "Downtempo", "Disco"],
        "Rock": ["Punk", "Post-Punk", "New Wave", "Art Rock", "Indie Rock"],
        "Jazz": ["Modal", "Hard Bop", "Cool Jazz", "Jazz-Funk", "Soul-Jazz", "Fusion"],
        "Funk / Soul": ["Afrobeat", "Funk", "Soul", "Disco"],
        "Hip Hop": ["Boom Bap", "Instrumental", "Jazzy Hip-Hop"],
        "Pop": ["Synth-pop", "Ballad"], "Reggae": ["Roots Reggae", "Dub"], "Latin": ["Bossa Nova", "Salsa"],
        "Blues": ["Delta Blues", "Chicago Blues"], "Classical": ["Baroque", "Modern"],
    ]
    static let decenni = ["1950", "1960", "1970", "1980", "1990", "2000", "2010", "2020"]
    /// (come lo scrive Discogs, come lo leggiamo noi)
    static let paesi: [(String, String)] = [("Italy", "Italia"), ("UK", "UK"), ("US", "USA"), ("Germany", "Germania"), ("France", "Francia"),
                                            ("Europe", "Europa"), ("Belgium", "Belgio"), ("Japan", "Giappone"), ("Nigeria", "Nigeria")]
    static var tuttiGliStili: [String] {
        var visti = Set<String>(), out: [String] = []
        for g in generi { for s in stili[g] ?? [] where !visti.contains(s) { visti.insert(s); out.append(s) } }
        return out
    }

    /// Quanti filtri della finestra sono attivi (il formato sta fuori, nelle pillole).
    var attivi: Int { [genere, stile, decennio, paese].filter { !$0.isEmpty }.count + (ordine == .rilevanza ? 0 : 1) }

    func parametri(_ testo: String) -> [String: String] {
        var p: [String: String] = [:]
        let q = testo.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { p["q"] = q }
        if let f = Self.formati.first(where: { $0.0 == formato })?.1, !f.isEmpty { p["format"] = f }
        if !genere.isEmpty { p["genre"] = genere }
        if !stile.isEmpty { p["style"] = stile }
        if !decennio.isEmpty { p["decade"] = decennio }
        if !paese.isEmpty { p["country"] = paese }
        switch ordine {
        case .recenti: p["sort"] = "year"; p["sort_order"] = "desc"
        case .cercati: p["sort"] = "want"; p["sort_order"] = "desc"
        case .rilevanza, .prezzo: if q.isEmpty { p["sort"] = "want"; p["sort_order"] = "desc" }   // senza testo: i più cercati
        }
        return p
    }
}

// MARK: - La sezione

struct CercaView: View {
    @Environment(Seller.self) private var seller
    @State private var testo = ""
    @State private var filtri = FiltriCerca()
    @State private var voci: [VoceCerca] = []
    @State private var totale = 0
    @State private var pagina = 1
    @State private var pagine = 1
    @State private var carico = false
    @State private var errore: String?
    @State private var cercaT = Date()
    @State private var scheda: VoceCerca?
    @State private var carrelloAperto = false
    @State private var scansiona = false
    @State private var scava = false
    @State private var filtriDa: PuntoFiltri?
    @State private var ascolta: BersaglioAscolto?
    private let carrello = Carrello.shared
    private let prezzi = PrezziCerca.shared

    private var chiave: String { "\(testo)|\(filtri.formato)|\(filtri.ordine.rawValue)|\(filtri.genere)|\(filtri.stile)|\(filtri.decennio)|\(filtri.paese)" }
    private var conTesto: Bool { !testo.trimmingCharacters(in: .whitespaces).isEmpty || filtri.attivi > 0 }

    /// Con «Prezzo più basso» l'ordine si fa qui, sui prezzi letti (la ricerca di Discogs non ordina per prezzo).
    private var mostrate: [VoceCerca] {
        guard filtri.ordine == .prezzo else { return voci }
        return voci.enumerated().sorted { a, b in
            let pa = prezzi.prezzo(a.element.id)?.da, pb = prezzi.prezzo(b.element.id)?.da
            switch (pa, pb) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    pillole
                    TestoDecodifica(testo: intestazione, da: cercaT, durata: 0.38)
                        .font(Theme.mono(10, .bold)).tracking(2).foregroundStyle(Theme.glow)
                        .padding(.horizontal, 2).padding(.top, 2)
                    if let errore {
                        Text(errore).font(.system(size: 14)).foregroundStyle(Theme.warn)
                    } else if voci.isEmpty && !carico {
                        Text(filtri.attivi > 0 ? "Nessun disco con questi filtri." : "Prova con artista, titolo o etichetta.")
                            .font(.system(size: 14)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    ForEach(mostrate) { v in
                        RigaCerca(voce: v, prezzo: prezzi.prezzo(v.id), nelCarrello: carrello.contiene(v.id),
                                  ascolta: { punto in
                                      apriFinestraAscolto(BersaglioAscolto(releaseID: v.id, titolo: v.nome, origine: punto), in: $ascolta)
                                  },
                                  carrello: { mettiNelCarrello(v) })
                            .onTapGesture { Suoni.tocco(); scheda = v }
                            .task { await prezzi.carica(v.id, client: seller.client, valuta: seller.currency) }
                            .onAppear { if v.id == voci.last?.id { Task { await altre() } } }
                    }
                    if carico { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding() }
                    Text("Dati e prezzi di Discogs. This application uses Discogs’ API but is not affiliated with, sponsored or endorsed by Discogs.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.immediately)
            .sfondoHUD()
            .senzaTitolo("Cerca")
            .searchable(text: $testo, placement: .navigationBarDrawer(displayMode: .always), prompt: "Artista, titolo, etichetta, barcode")
            .refreshable { await Task { await cerca(daCapo: true) }.value }
            .toolbar { strumenti }
            .task(id: chiave) {
                try? await Task.sleep(for: .milliseconds(testo.isEmpty ? 0 : 450))
                if Task.isCancelled { return }
                await cerca(daCapo: true)
            }
            .sheet(item: $scheda) { v in SchedaCerca(voce: v).environment(seller) }
            .sheet(isPresented: $carrelloAperto) { CarrelloView { v in carrelloAperto = false; Task { try? await Task.sleep(for: .milliseconds(350)); scheda = v } }.environment(seller) }
            .fullScreenCover(isPresented: $scansiona) {
                ScansionaView { v in scansiona = false; Task { try? await Task.sleep(for: .milliseconds(350)); scheda = v } }.environment(seller)
            }
            .fullScreenCover(isPresented: $scava) { ScavaView(voci: mostrate) { v in scheda = v }.environment(seller) }
            .fullScreenCover(item: $filtriDa) { p in
                FinestraFiltri(filtri: $filtri, testo: testo, origine: p.punto) {
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { filtriDa = nil }
                }
                .environment(seller)
                .presentationBackground(.clear)
            }
            .finestraAscolto($ascolta, seller: seller)
            .onReceive(NotificationCenter.default.publisher(for: NotificheDelegate.apriCarrello)) { _ in carrelloAperto = true }
        }
    }

    private var intestazione: String {
        if carico && voci.isEmpty { return "CERCO SU DISCOGS…" }
        if !conTesto { return "PIÙ CERCATI SU DISCOGS" }
        if voci.isEmpty { return "NESSUN DISCO" }
        return totale == 1 ? "1 RISULTATO" : "\(soldiInteri(totale)) RISULTATI"
    }

    private func soldiInteri(_ n: Int) -> String {
        n.formatted(.number.locale(Locale(identifier: "it_IT")))
    }

    /// Tutti / Vinile / CD / Cassetta e, a destra, Filtri (la finestra olografica).
    private var pillole: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(FiltriCerca.formati, id: \.0) { f in
                        let on = filtri.formato == f.0
                        Button { guard !on else { return }; Suoni.tocco(); filtri.formato = f.0 } label: {
                            Text(f.0).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(on ? Color.black : Theme.text)
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(on ? Theme.accent : Theme.panelHigh, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            GeometryReader { g in
                Button {
                    let f = g.frame(in: .global)
                    Suoni.tocco()
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { filtriDa = PuntoFiltri(punto: CGPoint(x: f.midX, y: f.midY)) }
                } label: {
                    Text(filtri.attivi > 0 ? "Filtri · \(filtri.attivi)" : "Filtri")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(filtri.attivi > 0 ? Theme.money : Theme.accent)
                        .frame(width: g.size.width, height: 30)
                        .background(filtri.attivi > 0 ? Theme.military : Color.clear, in: Capsule())
                        .overlay(Capsule().stroke(filtri.attivi > 0 ? Color.clear : Theme.accent.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .frame(width: filtri.attivi > 0 ? 86 : 70, height: 30)
        }
    }

    @ToolbarContentBuilder private var strumenti: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Scava") { Suoni.tocco(); scava = true }
                .disabled(voci.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { Suoni.camera(); scansiona = true } label: { Image(systemName: "viewfinder.circle") }
                .accessibilityLabel("Scansiona un disco")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { Suoni.testa(); carrelloAperto = true } label: {
                Image(systemName: "cart")
                    .overlay(alignment: .topTrailing) {
                        if carrello.voci.count > 0 {
                            Text("\(carrello.voci.count)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                                .background(Theme.warn, in: Capsule())
                                .offset(x: 9, y: -7)
                        }
                    }
            }
            .accessibilityLabel(carrello.voci.isEmpty ? "Carrello" : "Carrello, \(carrello.voci.count) dischi")
        }
    }

    private func mettiNelCarrello(_ v: VoceCerca) {
        if carrello.contiene(v.id) { carrello.togli(v.id); Suoni.svuota() }
        else { carrello.metti(v, prezzo: prezzi.prezzo(v.id), valuta: seller.currency); Suoni.tocco(); UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    private func cerca(daCapo: Bool) async {
        if daCapo { pagina = 1 }
        let suona = conTesto && daCapo
        if suona { Suoni.schedaApre() }
        carico = true
        errore = nil
        defer { carico = false }
        do {
            let r = try await seller.client.cercaCatalogo(filtri.parametri(testo), pagina: pagina)
            if Task.isCancelled { return }
            let nuove = Self.unaPerAlbum(r.results.map(VoceCerca.init), gia: daCapo ? [] : voci)
            if daCapo { voci = nuove; cercaT = Date() } else { voci += nuove }
            totale = r.pagination?.items ?? voci.count
            pagine = r.pagination?.pages ?? 1
            if suona { Suoni.schedaPronta() }
            // con «Prezzo più basso» servono i prezzi di tutti i dischi letti
            if filtri.ordine == .prezzo {
                for v in voci { await prezzi.carica(v.id, client: seller.client, valuta: seller.currency) }
            }
        } catch {
            if error.isCancellation { return }
            if suona { Suoni.errore() }
            errore = error.localizedDescription
        }
    }

    private func altre() async {
        guard !carico, pagina < pagine else { return }
        pagina += 1
        await cerca(daCapo: false)
    }

    /// Una riga per album: della stessa «master» resta la stampa che Discogs mette per prima (le altre sono in Versioni).
    static func unaPerAlbum(_ lista: [VoceCerca], gia: [VoceCerca]) -> [VoceCerca] {
        var visti = Set(gia.compactMap(\.masterID)), ids = Set(gia.map(\.id)), out: [VoceCerca] = []
        for v in lista where !ids.contains(v.id) {
            if let m = v.masterID { if visti.contains(m) { continue }; visti.insert(m) }
            ids.insert(v.id)
            out.append(v)
        }
        return out
    }
}

struct PuntoFiltri: Identifiable {
    let id = UUID()
    let punto: CGPoint
}

/// Una riga: copertina, artista – titolo, anno · formato · etichetta, «da X € · N in vendita», ▶ e +.
struct RigaCerca: View {
    let voce: VoceCerca
    let prezzo: PrezzoCerca?
    let nelCarrello: Bool
    let ascolta: (CGPoint) -> Void
    let carrello: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: voce.miniatura) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(voce.nome).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(voce.meta).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                (Text(PrezziCerca.testo(prezzo)).foregroundColor(Theme.money).fontWeight(.bold)
                    + Text(prezzo.map { $0.da == nil ? "" : " · \($0.inVendita) in vendita" } ?? ""))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                GeometryReader { g in
                    Button {
                        let f = g.frame(in: .global)
                        ascolta(CGPoint(x: f.midX, y: f.midY))
                    } label: {
                        Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                            .frame(width: 36, height: 36)
                            .overlay(Circle().stroke(Theme.accent.opacity(0.4), lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 36, height: 36)
                .accessibilityLabel("Ascolta \(voce.nome)")
                Button(action: carrello) {
                    Image(systemName: nelCarrello ? "checkmark" : "plus").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(nelCarrello ? Color.black : Theme.accent)
                        .frame(width: 36, height: 36)
                        .background(nelCarrello ? Theme.accent : Color.clear, in: Circle())
                        .overlay(Circle().stroke(Theme.accent.opacity(nelCarrello ? 0 : 0.4), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(nelCarrello ? "Nel carrello" : "Aggiungi al carrello")
            }
            .fixedSize()
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
}

// MARK: - La finestra dei Filtri (si apre come quella dell'Ascolto)

struct FinestraFiltri: View {
    @Binding var filtri: FiltriCerca
    let testo: String
    let origine: CGPoint
    let chiudi: () -> Void

    @Environment(Seller.self) private var seller
    private enum Fase { case apre(Date), aperta, chiude(Date) }
    @State private var fase: Fase = .apre(Date())
    @State private var conto: Int?

    private var animando: Bool { if case .aperta = fase { return false }; return true }

    private func avanzamento(_ ora: Date) -> Double {
        switch fase {
        case .aperta: return 1
        case .apre(let d): return min(1, max(0, ora.timeIntervalSince(d) / 0.62))
        case .chiude(let d): return 1 - min(1, max(0, ora.timeIntervalSince(d) / 0.30))
        }
    }

    var body: some View {
        GeometryReader { g in
            TimelineView(.animation(minimumInterval: 1.0 / 120, paused: !animando)) { ctx in
                let k = avanzamento(ctx.date)
                ZStack {
                    Color.black.opacity(0.6 * min(1, k * 1.6))
                        .contentShape(Rectangle())
                        .onTapGesture { avviaChiusura() }
                    finestra(k: k, schermo: g.size)
                }
            }
        }
        .ignoresSafeArea()
        .task {
            Suoni.chatCarica()
            try? await Task.sleep(for: .milliseconds(640))
            if case .apre = fase { fase = .aperta; Suoni.chatPronta() }
        }
        .task(id: filtri) { await contaRisultati() }
    }

    private func avviaChiusura() {
        if case .chiude = fase { return }
        Suoni.tocco()
        Suoni.chatPronta()
        fase = .chiude(Date())
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            chiudi()
        }
    }

    /// «Mostra N dischi»: quanti risultati con questi filtri (una richiesta leggera a Discogs, dopo un attimo).
    private func contaRisultati() async {
        conto = nil
        try? await Task.sleep(for: .milliseconds(500))
        if Task.isCancelled { return }
        var p = filtri.parametri(testo)
        p["per_page"] = "1"
        if let r = try? await seller.client.cercaCatalogo(p, pagina: 1), !Task.isCancelled { conto = r.pagination?.items }
    }

    private func visibile(_ k: Double, _ i: Int) -> Double { min(1, max(0, (k - 0.55 - Double(i) * 0.05) / 0.2)) }

    @ViewBuilder private func finestra(k: Double, schermo: CGSize) -> some View {
        let w = max(10, schermo.width - 28)
        let h = min(schermo.height * 0.8, 640)
        let a = morbido(k / 0.42), b = morbido((k - 0.38) / 0.62)
        let centro = CGPoint(x: schermo.width / 2, y: schermo.height / 2)
        let dx = (origine.x - centro.x) * CGFloat(1 - a), dy = (origine.y - centro.y) * CGFloat(1 - a)
        ZStack {
            contenuto(k: k)
                .frame(width: w, height: h)
                .background(Color(red: 6 / 255, green: 12 / 255, blue: 8 / 255).opacity(0.97))
                .overlay { RigheScansione() }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.glow.opacity(0.6), lineWidth: 1))
                .shadow(color: Theme.glow.opacity(0.18), radius: 15)
                .mask { Rectangle().frame(width: max(2, w * CGFloat(a)), height: max(2, h * CGFloat(b))) }
            Capsule().fill(Theme.glow)
                .frame(width: max(2, w * CGFloat(a)), height: 2)
                .shadow(color: Theme.glow, radius: 6)
                .opacity(1 - b)
                .allowsHitTesting(false)
        }
        .offset(x: dx, y: dy)
    }

    private func contenuto(k: Double) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("FILTRI").font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow)
                Spacer()
                Button("Chiudi") { avviaChiusura() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
            .opacity(min(1, max(0, (k - 0.45) / 0.2)))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    gruppo("ORDINA", FiltriCerca.Ordine.allCases.map { ($0.nome, $0.nome) }, scelto: filtri.ordine.nome) { v in
                        filtri.ordine = FiltriCerca.Ordine.allCases.first { $0.nome == v } ?? .rilevanza
                    }.opacity(visibile(k, 0))
                    gruppo("GENERE", FiltriCerca.generi.map { ($0, $0) }, scelto: filtri.genere, togli: true) { v in
                        filtri.genere = v
                        if !filtri.stile.isEmpty && !(FiltriCerca.stili[v] ?? []).contains(filtri.stile) { filtri.stile = "" }
                    }.opacity(visibile(k, 1))
                    gruppo("STILE", (filtri.genere.isEmpty ? FiltriCerca.tuttiGliStili : (FiltriCerca.stili[filtri.genere] ?? [])).map { ($0, $0) },
                           scelto: filtri.stile, togli: true) { filtri.stile = $0 }.opacity(visibile(k, 2))
                    gruppo("DECENNIO", FiltriCerca.decenni.map { ($0, $0 + "s") }, scelto: filtri.decennio, togli: true) { filtri.decennio = $0 }
                        .opacity(visibile(k, 3))
                    gruppo("PAESE", FiltriCerca.paesi, scelto: filtri.paese, togli: true) { filtri.paese = $0 }.opacity(visibile(k, 4))
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
            }
            HStack(spacing: 8) {
                Button {
                    Suoni.svuota()
                    let formato = filtri.formato
                    filtri = FiltriCerca()
                    filtri.formato = formato
                } label: {
                    Text("Ripristina").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.accent, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(filtri.attivi == 0)
                .opacity(filtri.attivi == 0 ? 0.5 : 1)
                Button { avviaChiusura() } label: {
                    Text(conto.map { $0 == 1 ? "Mostra 1 disco" : "Mostra \($0.formatted(.number.locale(Locale(identifier: "it_IT")))) dischi" } ?? "Mostra")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Color.black)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(Theme.glow.opacity(0.15)).frame(height: 1) }
            .opacity(min(1, max(0, (k - 0.7) / 0.2)))
        }
    }

    /// Un settore: il titolo verde e le pillole (una sola scelta; ritoccandola si toglie, tranne Ordina).
    private func gruppo(_ titolo: String, _ voci: [(String, String)], scelto: String, togli: Bool = false,
                        _ scegli: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titolo).font(Theme.mono(10, .bold)).tracking(2).foregroundStyle(Theme.glow)
            FlowPillole(voci: voci, scelto: scelto) { v in
                Suoni.tocco()
                scegli(togli && v == scelto ? "" : v)
            }
        }
    }
}

/// Pillole che vanno a capo.
struct FlowPillole: View {
    let voci: [(String, String)]
    let scelto: String
    let tocca: (String) -> Void

    var body: some View {
        FlowLayout(spazio: 6) {
            ForEach(voci, id: \.0) { v in
                let on = v.0 == scelto
                Button { tocca(v.0) } label: {
                    Text(v.1).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(on ? Color.black : Theme.text)
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(on ? Theme.accent : Color.white.opacity(0.06), in: Capsule())
                        .overlay(Capsule().stroke(on ? Theme.accent : Theme.glow.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// Disposizione a righe che vanno a capo (come le pillole del mock-up).
struct FlowLayout: Layout {
    var spazio: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let larghezza = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rigaAlta: CGFloat = 0, piuLarga: CGFloat = 0
        for s in subviews {
            let d = s.sizeThatFits(.unspecified)
            if x > 0 && x + d.width > larghezza { x = 0; y += rigaAlta + spazio; rigaAlta = 0 }
            x += d.width + spazio
            rigaAlta = max(rigaAlta, d.height)
            piuLarga = max(piuLarga, x - spazio)
        }
        return CGSize(width: proposal.width ?? piuLarga, height: y + rigaAlta)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rigaAlta: CGFloat = 0
        for s in subviews {
            let d = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + d.width > bounds.maxX { x = bounds.minX; y += rigaAlta + spazio; rigaAlta = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(d))
            x += d.width + spazio
            rigaAlta = max(rigaAlta, d.height)
        }
    }
}

/// Le righe sottili da schermo HUD (come sulla finestra dell'Ascolto).
struct RigheScansione: View {
    var body: some View {
        Canvas { gc, size in
            var y = 0.0
            var p = Path()
            while y < size.height { p.addRect(CGRect(x: 0, y: y, width: size.width, height: 1)); y += 3 }
            gc.fill(p, with: .color(Theme.glow.opacity(0.035)))
        }
        .allowsHitTesting(false)
    }
}
