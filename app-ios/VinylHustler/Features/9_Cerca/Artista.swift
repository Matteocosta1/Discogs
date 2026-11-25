import SwiftUI
import UIKit

// V85 · Cerca › la pagina dell'artista (come nel mock-up): scrivendo il nome di un artista, in cima ai risultati
// compare la sua riga; dentro ci sono foto, numeri, Digging e tutte le uscite dalla prima all'ultima.

// MARK: - Discogs

/// La scheda di un artista su Discogs (/artists/{id}).
struct ArtistaDiscogs: Decodable {
    var id: Int
    var name: String
    var realname: String?
    var profile: String?
    var images: [ReleaseImage]?
    var members: [Membro]?

    struct Membro: Decodable {
        var name: String
        var active: Bool?
    }
}

/// V91 · La scheda di un'etichetta su Discogs (/labels/{id}).
struct EtichettaDiscogs: Decodable {
    var id: Int
    var name: String
    var profile: String?
    var images: [ReleaseImage]?
    var parentLabel: Rif?

    struct Rif: Decodable { var name: String }
}

/// V91 · Un'uscita dell'elenco ufficiale di un artista (/artists/{id}/releases) o di un'etichetta (/labels/{id}/releases):
/// si legge dal codice Discogs, quindi niente omonimi. Per l'artista c'è il ruolo («Main»: il disco è suo) e l'album (master)
/// con la sua stampa principale.
struct UscitaDiscogs: Decodable {
    var id: Int
    var type: String?
    var mainRelease: Int?
    var role: String?
    var title: String?
    var artist: String?
    var year: Int?
    var thumb: String?
    var format: String?
    var label: String?
    var stats: Statistiche?

    struct Statistiche: Decodable {
        struct Comunita: Decodable { var inWantlist: Int?; var inCollection: Int? }
        var community: Comunita?
    }

    /// La riga per Cerca, Digging e le liste: la stampa da ascoltare e da comprare (per l'album, la principale).
    var voce: VoceCerca {
        let master = type == "master"
        var r = SearchResult(id: master ? (mainRelease ?? id) : id, title: "\(artist ?? "") - \(title ?? "")")
        r.year = year.map(String.init)
        r.format = format.map { [$0] }
        r.label = label.map { [$0] }
        r.thumb = thumb
        r.coverImage = thumb
        r.community = SearchCommunity(want: stats?.community?.inWantlist, have: stats?.community?.inCollection)
        r.masterId = master ? id : nil
        return VoceCerca(r)
    }
}

struct PaginaUsciteDiscogs: Decodable {
    var pagination: Pagination?
    var releases: [UscitaDiscogs]
}

extension DiscogsClient {
    /// Gli artisti che si chiamano come il testo cercato (i primi 5).
    func cercaArtista(_ testo: String) async throws -> [SearchResult] {
        let p: SearchPage = try await request("GET", "/database/search", query: ["q": testo, "type": "artist", "per_page": "5"])
        return p.results
    }

    func artista(_ id: Int) async throws -> ArtistaDiscogs {
        try await request("GET", "/artists/\(id)")
    }

    /// V91 · Le uscite di un artista dal suo codice, dalla più vecchia (100 per pagina).
    func usciteArtista(_ id: Int, pagina: Int) async throws -> PaginaUsciteDiscogs {
        try await request("GET", "/artists/\(id)/releases", query: ["sort": "year", "sort_order": "asc", "per_page": "100", "page": String(pagina)])
    }

    func etichetta(_ id: Int) async throws -> EtichettaDiscogs {
        try await request("GET", "/labels/\(id)")
    }

    /// V91 · Le uscite di un'etichetta dal suo codice (100 per pagina); `ultima`: dalla più recente, una sola (per «AL»).
    func usciteEtichetta(_ id: Int, pagina: Int, ultima: Bool = false) async throws -> PaginaUsciteDiscogs {
        try await request("GET", "/labels/\(id)/releases", query: ["sort": "year", "sort_order": ultima ? "desc" : "asc",
                                                                   "per_page": ultima ? "1" : "100", "page": String(pagina)])
    }

    /// Gli album (master) di un artista, uno solo per pagina: dice quanti sono e l'anno del primo (o dell'ultimo).
    func albumArtista(_ nome: String, ultimo: Bool) async throws -> SearchPage {
        try await request("GET", "/database/search", query: ["artist": nome, "type": "master", "per_page": "1",
                                                             "sort": "year", "sort_order": ultimo ? "desc" : "asc"])
    }
}

// MARK: - L'artista trovato in Cerca

struct ArtistaTrovato: Identifiable, Hashable {
    let id: Int
    let nome: String
    let foto: URL?
    /// V91: la stessa pagina, per un'etichetta (dalla scheda del disco).
    var etichetta = false

    /// «Daft Punk (2)» → «Daft Punk»: il numero lo mette Discogs per distinguere gli omonimi.
    static func pulito(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
    }
    private static func chiave(_ s: String) -> String { pulito(s).lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Il primo artista il cui nome corrisponde a quello che si sta scrivendo («aux» → Aux 88, «daft punk homework» → Daft Punk).
    static func scegli(_ risultati: [SearchResult], testo: String) -> ArtistaTrovato? {
        let q = chiave(testo)
        guard q.count >= 3 else { return nil }
        for r in risultati {
            let k = chiave(r.title)
            guard !k.isEmpty, k.hasPrefix(q) || q.hasPrefix(k) else { continue }
            return ArtistaTrovato(id: r.id, nome: pulito(r.title), foto: (r.coverImage ?? r.thumb).flatMap(URL.init(string:)))
        }
        return nil
    }

    /// Il gruppo e chi ne fa parte, oppure il nome vero dell'artista.
    static func chi(_ d: ArtistaDiscogs?) -> String {
        guard let d else { return "" }
        let membri = (d.members ?? []).filter { $0.active != false }.map { pulito($0.name) }
        if !membri.isEmpty { return membri.joined(separator: ", ") }
        return d.realname ?? ""
    }

    /// Il testo di Discogs senza i codici dei collegamenti ([a=Nome], [l=Etichetta], [url=…]…[/url], [b]…).
    static func profilo(_ s: String?) -> String {
        var t = s ?? ""
        t = t.replacingOccurrences(of: #"\[url=[^\]]*\]([^\[]*)\[/url\]"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[[almr]=?\d+\]"#, with: "", options: .regularExpression)      // [a123], [m=456]: solo numeri
        t = t.replacingOccurrences(of: #"\[[al]=([^\]]+)\]"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[/?[biu]\]"#, with: "", options: .regularExpression)
        return pulito(t).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// La riga dell'artista in cima ai risultati di Cerca.
struct RigaArtista: View {
    let artista: ArtistaTrovato
    @Environment(Seller.self) private var seller
    @State private var sotto = ""

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: artista.foto) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(artista.nome).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                if !sotto.isEmpty {
                    Text(sotto).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text("Artista ›").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent).fixedSize()
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.accent.opacity(0.35), lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .task(id: artista.id) {
            sotto = ""
            if let d = try? await seller.client.artista(artista.id), !Task.isCancelled { sotto = ArtistaTrovato.chi(d) }
        }
    }
}

// MARK: - Digging che continua da solo con le pagine dopo

/// Le pagine successive di una ricerca Discogs, una riga per album (la usano Cerca e la pagina dell'artista).
@MainActor
final class SorgenteDigging {
    /// Da dove arrivano le righe: una ricerca di Cerca, oppure (V91) l'elenco ufficiale di un artista o di un'etichetta.
    enum Modo {
        case ricerca([String: String])
        case artista(Int)
        case etichetta(Int)
    }
    private let client: DiscogsClient
    private let modo: Modo
    private let soloConAnno: Bool
    private(set) var pagina: Int
    private(set) var pagine: Int
    /// V91 · Quante uscite ha in tutto l'elenco (tutte le stampe e i ruoli): si sa dalla prima pagina.
    private(set) var totale: Int?

    init(client: DiscogsClient, modo: Modo, pagina: Int = 0, pagine: Int = 1, soloConAnno: Bool = false) {
        self.client = client
        self.modo = modo
        self.pagina = pagina
        self.pagine = pagine
        self.soloConAnno = soloConAnno
    }

    convenience init(client: DiscogsClient, parametri: [String: String], pagina: Int, pagine: Int, soloConAnno: Bool = false) {
        self.init(client: client, modo: .ricerca(parametri), pagina: pagina, pagine: pagine, soloConAnno: soloConAnno)
    }

    var finita: Bool { pagina >= pagine }

    /// Una copia che va avanti per conto suo (la lista e Digging leggono pagine diverse).
    func copia() -> SorgenteDigging {
        let c = SorgenteDigging(client: client, modo: modo, pagina: pagina, pagine: pagine, soloConAnno: soloConAnno)
        c.totale = totale
        return c
    }

    /// Le righe nuove della pagina dopo (salta le pagine che hanno solo album già visti).
    func altre(dopo gia: [VoceCerca]) async -> [VoceCerca] {
        while pagina < pagine {
            guard let righe = await leggi(pagina + 1) else { return [] }
            pagina += 1
            let nuove: [VoceCerca]
            switch modo {
            case .ricerca: nuove = CercaView.unaPerAlbum(righe, gia: gia)
            case .artista, .etichetta: nuove = Self.unaPerTitolo(righe, gia: gia)
            }
            if !nuove.isEmpty { return nuove }
        }
        return []
    }

    /// Una pagina, già filtrata (nil: Discogs non ha risposto).
    private func leggi(_ n: Int) async -> [VoceCerca]? {
        switch modo {
        case .ricerca(let parametri):
            guard let r = try? await client.cercaCatalogo(parametri, pagina: n) else { return nil }
            pagine = r.pagination?.pages ?? n
            if totale == nil { totale = r.pagination?.items }
            return r.results.map(VoceCerca.init).filter { !soloConAnno || (!$0.anno.isEmpty && $0.anno != "0") }
        case .artista(let id):
            // solo i dischi suoi («Main»): niente remix, comparsate e compilation di altri
            guard let r = try? await client.usciteArtista(id, pagina: n) else { return nil }
            pagine = r.pagination?.pages ?? n
            if totale == nil { totale = r.pagination?.items }
            return r.releases.filter { ($0.role ?? "Main") == "Main" && ($0.year ?? 0) > 0 }.map(\.voce)
        case .etichetta(let id):
            guard let r = try? await client.usciteEtichetta(id, pagina: n) else { return nil }
            pagine = r.pagination?.pages ?? n
            if totale == nil { totale = r.pagination?.items }
            return r.releases.filter { ($0.year ?? 0) > 0 }.map(\.voce)
        }
    }

    /// Lo stesso disco in più formati (LP, CD…) o lo stesso album: una riga sola, la prima.
    static func unaPerTitolo(_ righe: [VoceCerca], gia: [VoceCerca]) -> [VoceCerca] {
        func chiave(_ v: VoceCerca) -> String { v.masterID.map { "m\($0)" } ?? "t" + v.nome.lowercased() }
        var visti = Set(gia.map(chiave)), out: [VoceCerca] = []
        for v in righe where !visti.contains(chiave(v)) {
            visti.insert(chiave(v))
            out.append(v)
        }
        return out
    }
}

/// Quello che serve a Digging per partire: le righe già lette, quante sono in tutto e da dove leggere le altre.
struct PartenzaDigging: Identifiable {
    let id = UUID()
    let voci: [VoceCerca]
    let totale: Int?
    let sorgente: SorgenteDigging?
}

/// Il tasto lungo di Digging (Cerca e pagina dell'artista): dentro nero, bordo e scritta verdi come Filtri.
struct TastoDigging: View {
    let numero: Int?
    let attivo: Bool
    let azione: () -> Void

    var body: some View {
        Button(action: azione) {
            // V86: niente simbolo del play, solo la scritta
            Text(numero.map { "Digging · \(RigaCerca.numero($0))" } ?? "Digging").font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.accent.opacity(0.4), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!attivo)
        .opacity(attivo ? 1 : 0.35)
    }
}

// MARK: - La pagina dell'artista (V91: e dell'etichetta, uguale)

struct ArtistaView: View {
    let artista: ArtistaTrovato
    @Environment(Seller.self) private var seller
    @Environment(\.dismiss) private var dismiss
    @State private var dettagli: ArtistaDiscogs?
    @State private var dettagliEt: EtichettaDiscogs?
    /// V91 · la bio: sei righe; se va oltre, «Leggi tutto» la apre intera.
    @State private var bioAperta = false
    @State private var bioLunga = false
    @State private var voci: [VoceCerca] = []
    @State private var sorgente: SorgenteDigging?
    @State private var carico = false
    @State private var uscite: Int?
    @State private var dal = ""
    @State private var al = ""
    @State private var scheda: VoceCerca?
    @State private var digging: PartenzaDigging?
    @State private var ascolta: BersaglioAscolto?
    private let carrello = Carrello.shared
    private let prezzi = PrezziCerca.shared

    private var foto: URL? {
        let immagini = artista.etichetta ? dettagliEt?.images : dettagli?.images
        let img = immagini?.first(where: { $0.type == "primary" }) ?? immagini?.first
        return (img?.uri ?? img?.uri150).flatMap(URL.init(string:)) ?? artista.foto
    }
    private var gruppo: Bool { !(dettagli?.members ?? []).isEmpty }
    private var profilo: String { ArtistaTrovato.profilo(artista.etichetta ? dettagliEt?.profile : dettagli?.profile) }
    private var tipo: String { artista.etichetta ? "Etichetta" : (gruppo ? "Gruppo" : "Artista") }
    /// Chi fa parte del gruppo, il nome vero; per l'etichetta, quella di cui fa parte.
    private var chi: String {
        artista.etichetta ? (dettagliEt?.parentLabel.map { "Parte di \(ArtistaTrovato.pulito($0.name))" } ?? "") : ArtistaTrovato.chi(dettagli)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        AsyncImage(url: foto) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                            .frame(width: 112, height: 112)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tipo).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                            Text(artista.nome).font(.system(size: 20, weight: .bold)).lineLimit(3)
                            if !chi.isEmpty { Text(chi).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(3) }
                        }
                    }
                    numeri
                    TastoDigging(numero: uscite, attivo: !voci.isEmpty) {
                        Suoni.tocco()
                        digging = PartenzaDigging(voci: voci, totale: uscite, sorgente: sorgente?.copia())
                    }
                    if !profilo.isEmpty { bio }
                    Text(uscite.map { "USCITE · \(RigaCerca.numero($0)) · DALLA PRIMA" } ?? "USCITE · DALLA PRIMA")
                        .font(Theme.mono(10, .bold)).tracking(2).foregroundStyle(Theme.glow)
                        .padding(.top, 2)
                    ForEach(voci) { v in
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
                    Text("Dati di Discogs. This application uses Discogs’ API but is not affiliated with, sponsored or endorsed by Discogs.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .sfondoHUD()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(artista.etichetta ? "ETICHETTA" : "ARTISTA").font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { Suoni.testa(); dismiss() }.foregroundStyle(Theme.accent)
                }
            }
            .task { await carica() }
            .sheet(item: $scheda) { v in SchedaCerca(voce: v).environment(seller) }
            .fullScreenCover(item: $digging) { d in
                ScavaView(voci: d.voci, totale: d.totale, sorgente: d.sorgente).environment(seller)
            }
            .finestraAscolto($ascolta, seller: seller)
        }
        .preferredColorScheme(.dark)
    }

    /// La bio: sei righe; se il testo è più lungo, «Leggi tutto» / «Riduci».
    private var bio: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(profilo).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(bioAperta ? nil : 6)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    // il testo intero, invisibile, per sapere se le sei righe lo tagliano
                    GeometryReader { corto in
                        Text(profilo).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                            .frame(width: corto.size.width, alignment: .leading)
                            .hidden()
                            .background(GeometryReader { lungo in
                                Color.clear.onChange(of: lungo.size.height, initial: true) { _, h in
                                    if !bioAperta { bioLunga = h > corto.size.height + 1 }
                                }
                            })
                    }
                    .hidden()
                }
            if bioLunga {
                Button(bioAperta ? "Riduci" : "Leggi tutto") { Suoni.tocco(); bioAperta.toggle() }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
            }
        }
    }

    private var numeri: some View {
        HStack(spacing: 6) {
            numero("USCITE", uscite.map { RigaCerca.numero($0) } ?? "…")
            numero("DAL", dal.isEmpty ? "…" : dal)
            numero("AL", al.isEmpty ? "…" : al)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func numero(_ titolo: String, _ valore: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(titolo).font(Theme.mono(8.5, .bold)).tracking(1.1).foregroundStyle(Theme.muted).lineLimit(1)
            Text(valore).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mettiNelCarrello(_ v: VoceCerca) {
        if carrello.contiene(v.id) { carrello.togli(v.id); Suoni.svuota() }
        else { carrello.metti(v, prezzo: prezzi.prezzo(v.id), valuta: seller.currency); Suoni.tocco(); UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    private func carica() async {
        let client = seller.client
        if artista.etichetta {
            // V91 · l'etichetta: la sua scheda e le sue uscite dal codice Discogs (niente omonimi), dalla più vecchia
            async let e = try? client.etichetta(artista.id)
            async let ultima = try? client.usciteEtichetta(artista.id, pagina: 1, ultima: true)
            sorgente = SorgenteDigging(client: client, modo: .etichetta(artista.id))
            await altre()
            dettagliEt = await e
            uscite = sorgente?.totale ?? voci.count
            dal = voci.first?.anno ?? ""
            al = await ultima?.releases.first?.year.map(String.init) ?? ""
            return
        }
        async let d = try? client.artista(artista.id)
        async let primo = try? client.albumArtista(artista.nome, ultimo: false)
        async let ultimo = try? client.albumArtista(artista.nome, ultimo: true)
        dettagli = await d
        if let p = await primo {
            uscite = p.pagination?.items ?? p.results.count
            dal = p.results.first?.year ?? ""
        }
        al = await ultimo?.results.first?.year ?? ""
        // V91: le uscite dall'elenco ufficiale dell'artista (dal suo codice Discogs: niente omonimi), solo i dischi suoi,
        // dalla più vecchia, una riga per album con la sua stampa principale
        sorgente = SorgenteDigging(client: client, modo: .artista(artista.id))
        await altre()
    }

    private func altre() async {
        guard !carico, let s = sorgente, !s.finita else { return }
        carico = true
        defer { carico = false }
        voci += await s.altre(dopo: voci)
    }
}
