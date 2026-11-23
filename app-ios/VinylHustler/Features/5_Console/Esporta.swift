import SwiftUI
import UIKit
import UniformTypeIdentifiers

// V79 — SETTINGS › ESPORTA (come nel mock-up approvato)
//   · Inventario: Excel con i dischi online e le bozze (Stato, Artista, Titolo, Vinile, Copertina, Prezzo, Valuta,
//     Posizione, link Discogs da toccare);
//   · Ordini: Excel con le vendite (totali, commissione Discogs, netto, link all'ordine);
//   · Catalogo: PDF in stile Discogs con i dischi online (copertina, artista – titolo, condizioni, prezzo), in alto
//     utente, «In vendita» e data, in basso il logo e «© anno Vinyl Hustler · Data provided by Discogs»; ogni riga
//     apre l'annuncio su Discogs.
// Il foglio ha solo il titolo, Chiudi, il file e due tasti: Condividi (il foglio di Apple: WhatsApp, Mail, Messaggi…)
// e Scarica (salva in File).

enum TipoEsporta: String, Identifiable {
    case inventario, ordini, catalogo
    var id: String { rawValue }
    var titolo: String {
        switch self {
        case .inventario: return "INVENTARIO"
        case .ordini: return "ORDINI"
        case .catalogo: return "CATALOGO"
        }
    }
    var formato: String { self == .catalogo ? "PDF" : "XLSX" }
}

/// Il gruppo «Esporta» di Settings: tre righe, ognuna apre il suo foglio.
struct EsportaSettings: View {
    @State private var aperto: TipoEsporta?

    var body: some View {
        GruppoJarvis("Esporta") {
            riga("Inventario", "Excel", .inventario)
            riga("Ordini", "Excel", .ordini)
            riga("Catalogo", "PDF", .catalogo, ultima: true)
        } piede: {
            Text("Inventario: i dischi online e le bozze, con il link Discogs. Ordini: le vendite con totali, commissioni e netto. Catalogo: i dischi online con copertina e prezzo, da mandare a un cliente.")
        }
        .sheet(item: $aperto) { t in
            FoglioEsporta(tipo: t)
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.hidden)
        }
    }

    private func riga(_ nome: String, _ formato: String, _ tipo: TipoEsporta, ultima: Bool = false) -> some View {
        Button { Suoni.tocco(); aperto = tipo } label: {
            RigaJarvis(ultima: ultima) {
                Text(nome)
                Spacer()
                Text(formato).font(Theme.mono(11, .semibold)).foregroundStyle(Theme.glow)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Il foglio: titolo e Chiudi, il file in alto, Condividi e Scarica.
struct FoglioEsporta: View {
    let tipo: TipoEsporta
    @Environment(Seller.self) private var seller
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var info = "Preparo il file…"
    @State private var errore: String?
    @State private var salva = false

    private var nome: String {
        let oggi = Date().formatted(.iso8601.year().month().day())
        let utente = seller.username.isEmpty ? "vinylhustler" : seller.username
        switch tipo {
        case .inventario: return "Inventario \(utente) \(oggi).xlsx"
        case .ordini: return "Ordini \(utente) \(oggi).xlsx"
        case .catalogo: return "Catalogo \(utente) \(oggi).pdf"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(tipo.titolo).font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow)
                Spacer()
                Button("Chiudi") { Suoni.testa(); dismiss() }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            HStack(spacing: 14) {
                Text(tipo.formato)
                    .font(Theme.mono(10, .bold)).foregroundStyle(Theme.glow)
                    .frame(width: 44, height: 56, alignment: .bottom)
                    .padding(.bottom, 8)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.glow.opacity(0.6), lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(nome).font(.system(size: 15, weight: .bold)).lineLimit(1).truncationMode(.middle)
                    Text(errore ?? info).font(.system(size: 13)).foregroundStyle(errore == nil ? Theme.muted : Theme.warn)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 8) {
                if let file {
                    ShareLink(item: file) {
                        Text("Condividi").font(.system(size: 16, weight: .bold)).foregroundStyle(Color.black)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .simultaneousGesture(TapGesture().onEnded { Suoni.tocco() })
                } else {
                    Text("Condividi").font(.system(size: 16, weight: .bold)).foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Theme.accent.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                Button { Suoni.tocco(); salva = true } label: {
                    Text("Scarica").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.accent, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(file == nil)
                .opacity(file == nil ? 0.4 : 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.top, 18)
        .background(Color(red: 0.043, green: 0.059, blue: 0.047).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $salva) {
            if let file { SalvaInFile(url: file) { ok in if ok { Suoni.fatto() } } }
        }
        .task { await prepara() }
    }

    private func prepara() async {
        Suoni.chatCarica()
        defer { Suoni.chatPronta() }
        do {
            let dati: Data
            switch tipo {
            case .inventario:
                info = "Leggo l'inventario su Discogs…"
                let online = try await seller.client.inventory(username: seller.username, status: "For Sale")
                let bozze = try await seller.client.inventory(username: seller.username, status: "Draft")
                dati = FoglioExcel.crea(foglio: "Inventario", righe: Esporta.righeInventario(online, bozze, valuta: seller.currency))
                info = "\(online.count + bozze.count) dischi · online e bozze · 9 colonne"
            case .ordini:
                info = "Leggo gli ordini su Discogs…"
                var tutti: [Order] = []
                var pagina = 1
                while true {
                    let p = try await seller.client.orders(page: pagina)
                    tutti += p.orders
                    if pagina >= p.pagination.pages { break }
                    pagina += 1
                }
                dati = FoglioExcel.crea(foglio: "Ordini", righe: Esporta.righeOrdini(tutti, valuta: seller.currency))
                info = "\(tutti.count) ordini · 12 colonne"
            case .catalogo:
                info = "Leggo i dischi online su Discogs…"
                let online = try await seller.client.inventory(username: seller.username, status: "For Sale")
                var copertine: [Int: Data] = [:]
                var fatte = 0
                // le copertine di Discogs (miniature), sei alla volta
                await withTaskGroup(of: (Int, Data?).self) { gruppo in
                    var coda = online.compactMap { l in l.release.thumbnail.flatMap(URL.init(string:)).map { (l.id, $0) } }[...]
                    for _ in 0..<min(6, coda.count) {
                        let (id, url) = coda.removeFirst()
                        gruppo.addTask { (id, try? await URLSession.shared.data(from: url).0) }
                    }
                    for await (id, d) in gruppo {
                        if let d { copertine[id] = d }
                        fatte += 1
                        info = "Copertine \(fatte) / \(online.count)"
                        if !coda.isEmpty {
                            let (id2, url2) = coda.removeFirst()
                            gruppo.addTask { (id2, try? await URLSession.shared.data(from: url2).0) }
                        }
                    }
                }
                let voci = online.map { l in
                    VoceCatalogo(titolo: Esporta.artistaTitolo(l.release.description ?? "Release \(l.release.id)"),
                                 condizioni: Esporta.condizioni(l),
                                 prezzo: soldiIT(l.price?.value ?? 0, l.price?.currency ?? seller.currency),
                                 link: URL(string: "https://www.discogs.com/sell/item/\(l.id)"),
                                 copertina: copertine[l.id])
                }
                let utente = seller.username
                let pagine = CatalogoPDF.pagine(voci.count)
                dati = await Task.detached(priority: .userInitiated) { CatalogoPDF.crea(utente: utente, voci: voci) }.value
                info = "\(online.count) dischi online · \(pagine) \(pagine == 1 ? "pagina" : "pagine") A4"
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(nome)
            try? FileManager.default.removeItem(at: url)
            try dati.write(to: url)
            file = url
        } catch {
            if !error.isCancellation { errore = "Non riuscito: " + error.localizedDescription; Suoni.nego() }
        }
    }
}

/// Scarica: il foglio di Apple per salvare il file in File (sul telefono, iCloud Drive…).
struct SalvaInFile: UIViewControllerRepresentable {
    let url: URL
    let fatto: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinatore { Coordinatore(fatto: fatto) }

    final class Coordinatore: NSObject, UIDocumentPickerDelegate {
        let fatto: (Bool) -> Void
        init(fatto: @escaping (Bool) -> Void) { self.fatto = fatto }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { fatto(true) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { fatto(false) }
    }
}

// MARK: - I dati

/// Una cella del foglio Excel: testo, numero o link (testo da toccare che apre l'indirizzo).
enum CellaExcel {
    case testo(String)
    case numero(Double)
    case link(String, URL)
}

enum Esporta {
    /// «Miles Davis - Kind Of Blue (LP, Album, RE)» → («Miles Davis», «Kind Of Blue»).
    static func dividi(_ descrizione: String) -> (artista: String, titolo: String) {
        let senza = descrizione.replacingOccurrences(of: #"\s*\([^()]*\)\s*$"#, with: "", options: .regularExpression)
        if let r = senza.range(of: " - ") {
            return (String(senza[..<r.lowerBound]), String(senza[r.upperBound...]))
        }
        return ("", senza)
    }

    static func artistaTitolo(_ descrizione: String) -> String {
        let d = dividi(descrizione)
        return d.artista.isEmpty ? d.titolo : "\(d.artista) – \(d.titolo)"
    }

    /// «Very Good Plus (VG+)» → «VG+» (come ListingRow.short, qui fuori dalle viste).
    static func breve(_ condizione: String?) -> String {
        guard let c = condizione, !c.isEmpty else { return "" }
        if let a = c.lastIndex(of: "("), let b = c.lastIndex(of: ")"), a < b {
            let dentro = c[c.index(after: a)..<b]
            return String(dentro.split(separator: " ").first ?? Substring(dentro))
        }
        return c
    }

    static func condizioni(_ l: Listing) -> String {
        let v = breve(l.condition), c = breve(l.sleeveCondition)
        if v.isEmpty && c.isEmpty { return "" }
        return "Vinile \(v.isEmpty ? "—" : v)  ·  Copertina \(c.isEmpty ? (v.isEmpty ? "—" : v) : c)"
    }

    static func righeInventario(_ online: [Listing], _ bozze: [Listing], valuta: String) -> [[CellaExcel]] {
        var righe: [[CellaExcel]] = [["Stato", "Artista", "Titolo", "Vinile", "Copertina", "Prezzo", "Valuta", "Posizione", "Discogs"].map { .testo($0) }]
        let gruppi: [(String, [Listing])] = [("Online", online), ("Bozza", bozze)]
        for (stato, lista) in gruppi {
            for l in lista {
                let d = dividi(l.release.description ?? "Release \(l.release.id)")
                let v = breve(l.condition), c = breve(l.sleeveCondition)
                var riga: [CellaExcel] = [.testo(stato), .testo(d.artista), .testo(d.titolo), .testo(v), .testo(c.isEmpty ? v : c)]
                riga.append(l.price.map { .numero($0.value) } ?? .testo(""))
                riga.append(.testo(l.price?.currency ?? valuta))
                riga.append(.testo(l.location ?? ""))
                if let u = URL(string: "https://www.discogs.com/sell/item/\(l.id)") { riga.append(.link("Apri su Discogs", u)) } else { riga.append(.testo("")) }
                righe.append(riga)
            }
        }
        return righe
    }

    static func righeOrdini(_ ordini: [Order], valuta: String) -> [[CellaExcel]] {
        var righe: [[CellaExcel]] = [["Ordine", "Data", "Stato", "Compratore", "Dischi", "Prezzo dischi", "Spedizione", "Totale",
                                      "Commissione Discogs", "Netto", "Valuta", "Discogs"].map { .testo($0) }]
        for o in ordini {
            let dischi = o.items.compactMap { $0.release.description.map(artistaTitolo) }.joined(separator: " · ")
            let prezzoDischi = o.items.compactMap { $0.price?.value }.reduce(0, +)
            var riga: [CellaExcel] = [.testo(o.id), .testo(OrderStyle.date(o.created)), .testo(OrderStyle(o.status).label),
                                      .testo(o.buyer.username), .testo(dischi), .numero(prezzoDischi),
                                      .numero(o.shipping?.value ?? 0), .numero(OrderCifre.totale(o)),
                                      .numero(OrderCifre.commissione(o)), .numero(OrderCifre.netto(o)),
                                      .testo(o.total?.currency ?? valuta)]
            if let u = URL(string: "https://www.discogs.com/sell/order/\(o.id)") { riga.append(.link("Apri su Discogs", u)) } else { riga.append(.testo("")) }
            righe.append(riga)
        }
        return righe
    }
}

extension CellaExcel: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .testo(value) }
}

// MARK: - Excel (.xlsx) scritto qui, senza librerie: uno zip «store» con i fogli XML

enum FoglioExcel {
    static func crea(foglio: String, righe: [[CellaExcel]]) -> Data {
        func x(_ t: String) -> String {
            t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func colonna(_ i: Int) -> String {
            var n = i + 1, s = ""
            while n > 0 { let m = (n - 1) % 26; s = String(UnicodeScalar(65 + m)!) + s; n = (n - m - 1) / 26 }
            return s
        }
        var link: [(String, String)] = []
        var larghezze = [Int](repeating: 8, count: righe.first?.count ?? 0)
        var dati = ""
        for (ri, r) in righe.enumerated() {
            dati += "<row r=\"\(ri + 1)\">"
            for (ci, c) in r.enumerated() {
                let ref = colonna(ci) + String(ri + 1)
                if ci >= larghezze.count { larghezze.append(8) }
                switch c {
                case .link(let testo, let url):
                    link.append((ref, url.absoluteString))
                    dati += "<c r=\"\(ref)\" t=\"inlineStr\" s=\"3\"><is><t>\(x(testo))</t></is></c>"
                    larghezze[ci] = max(larghezze[ci], testo.count)
                case .numero(let v):
                    dati += "<c r=\"\(ref)\" s=\"2\"><v>\(v)</v></c>"
                    larghezze[ci] = max(larghezze[ci], 10)
                case .testo(let t):
                    dati += "<c r=\"\(ref)\" t=\"inlineStr\"\(ri == 0 ? " s=\"1\"" : "")><is><t xml:space=\"preserve\">\(x(t))</t></is></c>"
                    larghezze[ci] = max(larghezze[ci], t.count)
                }
            }
            dati += "</row>"
        }
        let intestazione = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let colonne = "<cols>" + larghezze.enumerated().map { "<col min=\"\($0.offset + 1)\" max=\"\($0.offset + 1)\" width=\"\(min(48, $0.element + 3))\" customWidth=\"1\"/>" }.joined() + "</cols>"
        let collegamenti = link.isEmpty ? "" : "<hyperlinks>" + link.enumerated().map { "<hyperlink ref=\"\($0.element.0)\" r:id=\"rId\($0.offset + 1)\"/>" }.joined() + "</hyperlinks>"
        let foglioXML = intestazione + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>" + colonne + "<sheetData>" + dati + "</sheetData>" + collegamenti + "</worksheet>"
        let relazioniFoglio = intestazione + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + link.enumerated().map { "<Relationship Id=\"rId\($0.offset + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(x($0.element.1))\" TargetMode=\"External\"/>" }.joined() + "</Relationships>"
        let stili = intestazione + "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><numFmts count=\"1\"><numFmt numFmtId=\"164\" formatCode=\"#,##0.00\"/></numFmts><fonts count=\"3\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font><font><u/><sz val=\"11\"/><color rgb=\"FF0563C1\"/><name val=\"Calibri\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"4\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/><xf numFmtId=\"164\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/><xf numFmtId=\"0\" fontId=\"2\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/></cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
        var parti: [(String, String)] = [
            ("[Content_Types].xml", intestazione + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/></Types>"),
            ("_rels/.rels", intestazione + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"),
            ("xl/workbook.xml", intestazione + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"\(x(foglio))\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", intestazione + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>"),
            ("xl/styles.xml", stili),
            ("xl/worksheets/sheet1.xml", foglioXML),
        ]
        if !link.isEmpty { parti.append(("xl/worksheets/_rels/sheet1.xml.rels", relazioniFoglio)) }
        return Zip.store(parti.map { ($0.0, Data($0.1.utf8)) })
    }
}

/// Uno zip senza compressione («store»): basta per i fogli Excel.
enum Zip {
    private static let tabella: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in d { c = tabella[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    static func store(_ file: [(String, Data)]) -> Data {
        var out = Data()
        var centrale = Data()
        func u16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ v: UInt32, _ d: inout Data) { for k in 0..<4 { d.append(UInt8((v >> (8 * UInt32(k))) & 0xFF)) } }
        for (nome, dati) in file {
            let n = Data(nome.utf8), c = crc32(dati), off = UInt32(out.count)
            out.append(contentsOf: [0x50, 0x4b, 3, 4]); u16(20, &out); u16(0x0800, &out); u16(0, &out); u16(0, &out); u16(0x21, &out)
            u32(c, &out); u32(UInt32(dati.count), &out); u32(UInt32(dati.count), &out); u16(n.count, &out); u16(0, &out)
            out.append(n); out.append(dati)
            centrale.append(contentsOf: [0x50, 0x4b, 1, 2]); u16(20, &centrale); u16(20, &centrale); u16(0x0800, &centrale); u16(0, &centrale)
            u16(0, &centrale); u16(0x21, &centrale); u32(c, &centrale); u32(UInt32(dati.count), &centrale); u32(UInt32(dati.count), &centrale)
            u16(n.count, &centrale); u16(0, &centrale); u16(0, &centrale); u16(0, &centrale); u16(0, &centrale); u32(0, &centrale); u32(off, &centrale)
            centrale.append(n)
        }
        let inizioCentrale = UInt32(out.count)
        out.append(centrale)
        out.append(contentsOf: [0x50, 0x4b, 5, 6]); u16(0, &out); u16(0, &out); u16(file.count, &out); u16(file.count, &out)
        u32(UInt32(centrale.count), &out); u32(inizioCentrale, &out); u16(0, &out)
        return out
    }
}

// MARK: - Catalogo PDF in stile Discogs

struct VoceCatalogo {
    let titolo: String
    let condizioni: String
    let prezzo: String
    let link: URL?
    let copertina: Data?
}

enum CatalogoPDF {
    static let pagina = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    static let margine: CGFloat = 40
    static let alto: CGFloat = 96          // dove parte l'elenco
    static let riga: CGFloat = 56
    static let piede: CGFloat = 64
    static var perPagina: Int { Int((pagina.height - piede - alto) / riga) }
    static func pagine(_ n: Int) -> Int { max(1, Int((Double(n) / Double(perPagina)).rounded(.up))) }

    static func crea(utente: String, voci: [VoceCatalogo]) -> Data {
        let W = pagina.width, H = pagina.height, M = margine
        let testo = UIColor(white: 0.067, alpha: 1), muto = UIColor(red: 0.42, green: 0.42, blue: 0.44, alpha: 1)
        let rigaGrigia = UIColor(red: 0.89, green: 0.89, blue: 0.90, alpha: 1), bordo = UIColor(red: 0.84, green: 0.84, blue: 0.85, alpha: 1)
        func font(_ size: CGFloat, _ bold: Bool) -> UIFont {
            UIFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size) ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
        }
        func scrivi(_ s: String, _ f: UIFont, _ c: UIColor, x: CGFloat, baseline: CGFloat, larghezza: CGFloat? = nil, allinea: NSTextAlignment = .left) {
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; p.alignment = allinea
            let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: c, .paragraphStyle: p]
            let w = larghezza ?? ((s as NSString).size(withAttributes: a).width + 1)
            let x0 = allinea == .right ? x - w : (allinea == .center ? x - w / 2 : x)
            (s as NSString).draw(with: CGRect(x: x0, y: baseline - f.ascender, width: w, height: f.lineHeight),
                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: a, context: nil)
        }
        let formato = DateFormatter()
        formato.locale = Locale(identifier: "it_IT")
        formato.dateFormat = "dd.MM.yyyy"
        let data = formato.string(from: Date())
        let logo = UIImage(named: "IconaCatalogo")
        let copyright = "© \(Calendar.current.component(.year, from: Date())) Vinyl Hustler · Data provided by Discogs"
        let r = UIGraphicsPDFRenderer(bounds: pagina, format: {
            let f = UIGraphicsPDFRendererFormat()
            f.documentInfo = [kCGPDFContextTitle as String: "\(utente) · In vendita", kCGPDFContextCreator as String: "Vinyl Hustler"]
            return f
        }())
        let gruppi = stride(from: 0, to: max(voci.count, 1), by: perPagina).map { Array(voci[min($0, voci.count)..<min($0 + perPagina, voci.count)]) }
        return r.pdfData { ctx in
            for lista in gruppi {
                ctx.beginPage()
                let g = ctx.cgContext
                // in alto: utente, In vendita, data
                scrivi(utente, font(16, true), testo, x: M, baseline: 58)
                scrivi("In vendita", font(8.5, false), muto, x: M, baseline: 74)
                scrivi(data, font(8.5, false), muto, x: W - M, baseline: 74, allinea: .right)
                g.setStrokeColor(testo.cgColor); g.setLineWidth(0.75)
                g.move(to: CGPoint(x: M, y: 84)); g.addLine(to: CGPoint(x: W - M, y: 84)); g.strokePath()
                // l'elenco, come su Discogs
                for (k, v) in lista.enumerated() {
                    let y = alto + CGFloat(k) * riga, lato: CGFloat = 40, xt = M + lato + 14
                    let quadro = CGRect(x: M, y: y + 8, width: lato, height: lato)
                    if let d = v.copertina, let im = UIImage(data: d) {
                        im.draw(in: quadro)
                    } else {
                        g.setFillColor(UIColor(white: 0.93, alpha: 1).cgColor); g.fill(quadro)
                    }
                    g.setStrokeColor(bordo.cgColor); g.setLineWidth(0.5); g.stroke(quadro)
                    let fp = font(9.5, true)
                    let wp = (v.prezzo as NSString).size(withAttributes: [.font: fp]).width
                    scrivi(v.titolo, font(9, true), testo, x: xt, baseline: y + 25, larghezza: W - M - xt - wp - 24)
                    scrivi(v.condizioni, font(7.5, false), muto, x: xt, baseline: y + 38, larghezza: W - M - xt - wp - 24)
                    scrivi(v.prezzo, fp, testo, x: W - M, baseline: y + 25, allinea: .right)
                    g.setStrokeColor(rigaGrigia.cgColor); g.setLineWidth(0.5)
                    g.move(to: CGPoint(x: M, y: y + riga)); g.addLine(to: CGPoint(x: W - M, y: y + riga)); g.strokePath()
                    if let link = v.link { UIGraphicsSetPDFContextURLForRect(link, CGRect(x: M, y: y, width: W - 2 * M, height: riga)) }
                }
                // in basso: il logo e, al centro, © e Discogs
                logo?.draw(in: CGRect(x: M, y: H - 42, width: 16, height: 16))
                scrivi(copyright, font(7, false), muto, x: W / 2, baseline: H - 31, allinea: .center)
                if let discogs = URL(string: "https://www.discogs.com") {
                    let w = (copyright as NSString).size(withAttributes: [.font: font(7, false)]).width
                    UIGraphicsSetPDFContextURLForRect(discogs, CGRect(x: W / 2 - w / 2, y: H - 42, width: w, height: 16))
                }
            }
        }
    }
}
