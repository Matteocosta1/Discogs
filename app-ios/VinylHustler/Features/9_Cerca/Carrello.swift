import SwiftUI
import UIKit
import UserNotifications

// V79 — CARRELLO (come nel mock-up): i dischi da comprare, con il prezzo più basso su Discogs (riletto ogni volta
// che si apre: i dati di Discogs non possono avere più di 6 ore), il totale indicativo e l'Avviso prezzo.
// «Compra» apre la pagina del disco su Discogs: lì si sceglie la copia e si paga (ogni venditore spedisce il suo ordine).

struct VoceCarrello: Codable, Identifiable, Hashable {
    var id: Int                     // la stampa (release) Discogs
    var nome: String
    var annoPaese: String
    var miniatura: String?
    var da: Double?
    var inVendita: Int
    var valuta: String
    /// Avviso prezzo: notifica quando il prezzo più basso scende sotto questa cifra (nil = spento).
    var avviso: Double?
    /// L'ultimo prezzo già avvisato (per non avvisare due volte lo stesso prezzo).
    var avvisato: Double?
    // V83: una copia precisa scelta in COPIE (l'annuncio Discogs). Senza: il disco, al prezzo più basso.
    var copia: Int?
    var prezzo: Double?
    var media: String?
    var sleeve: String?
    var venditore: String?
    var paese: String?
    var venduta: Bool?
    /// V91: la sua pagina Discogs è stata aperta per «Add to Cart» (togliendola da qui si apre il carrello Discogs).
    var suDiscogs: Bool?

    /// Una riga del carrello: la copia o il disco (lo stesso disco può esserci in tutti e due i modi).
    var chiave: String { copia.map { "c\($0)" } ?? "r\(id)" }
    var linkCompra: URL? {
        if let copia { return URL(string: "https://www.discogs.com/sell/item/\(copia)") }
        return URL(string: "https://www.discogs.com/sell/release/\(id)?ev=rb")
    }
    /// Il prezzo che conta nel totale: quello esatto della copia, o il più basso del disco.
    var conto: Double? { copia != nil ? prezzo : da }
}

@MainActor
@Observable
final class Carrello {
    static let shared = Carrello()
    nonisolated static let chiave = "carrelloV79"
    private(set) var voci: [VoceCarrello] = Carrello.leggi()
    private(set) var aggiornato: Date?
    /// V91: le copie tolte perché su Discogs non sono più in vendita (comprate da te o da un altro), per l'avviso nel Carrello.
    private(set) var tolte: [String] = UserDefaults.standard.stringArray(forKey: "vh.copieTolte") ?? []

    nonisolated static func leggi() -> [VoceCarrello] {
        guard let d = UserDefaults.standard.data(forKey: chiave) else { return [] }
        return (try? JSONDecoder().decode([VoceCarrello].self, from: d)) ?? []
    }
    nonisolated static func scrivi(_ v: [VoceCarrello]) {
        if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: chiave) }
    }
    private func salva() { Self.scrivi(voci) }

    func contiene(_ id: Int) -> Bool { voci.contains { $0.id == id && $0.copia == nil } }
    func contieneCopia(_ copia: Int) -> Bool { voci.contains { $0.copia == copia } }

    /// V83: la copia scelta in COPIE, con prezzo, condizioni, venditore e paese.
    func mettiCopia(_ c: CopiaInVendita, valuta: String) {
        guard !contieneCopia(c.id) else { return }
        let nome = (c.release.description ?? "").replacingOccurrences(of: #"\s*\([^()]*\)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " - ", with: " – ")
        var v = VoceCarrello(id: c.release.id, nome: nome, annoPaese: "", miniatura: c.release.thumbnail, da: nil, inVendita: 0,
                             valuta: c.price?.currency ?? valuta, avviso: nil, avvisato: nil)
        v.copia = c.id
        v.prezzo = c.price?.value
        v.media = c.condition
        v.sleeve = c.sleeveCondition
        v.venditore = [c.seller?.username, c.voto].compactMap { $0 }.joined(separator: " · ")
        v.paese = c.shipsFrom
        voci.insert(v, at: 0)
        salva()
    }
    func togliCopia(_ copia: Int) { voci.removeAll { $0.copia == copia }; salva() }
    func segnaSuDiscogs(_ copia: Int) {
        guard let i = voci.firstIndex(where: { $0.copia == copia }) else { return }
        voci[i].suDiscogs = true
        salva()
    }
    func suDiscogs(_ copia: Int) -> Bool { voci.first { $0.copia == copia }?.suDiscogs == true }
    /// L'avviso delle copie tolte è stato visto.
    func avvisoVisto() { tolte = []; UserDefaults.standard.removeObject(forKey: "vh.copieTolte") }

    /// V91 · Le copie del carrello ancora in vendita su Discogs? Quelle che non lo sono più (comprate da te o da un
    /// altro) escono dal carrello. Una richiesta per copia; se Discogs non risponde si riprova la volta dopo.
    func controllaCopie(client: DiscogsClient) async {
        for copia in voci.compactMap(\.copia) {
            guard !Task.isCancelled else { return }
            var via = false
            do {
                let c = try await client.copia(copia, currency: voci.first { $0.copia == copia }?.valuta ?? "EUR", bassa: true)
                if c.inVendita, let i = voci.firstIndex(where: { $0.copia == copia }) {
                    voci[i].venduta = false
                    if let p = c.price?.value { voci[i].prezzo = p }
                } else { via = !c.inVendita }
            } catch DiscogsError.http(let codice, _) where codice == 404 {
                via = true                                          // l'annuncio non c'è più
            } catch {}
            if via, let i = voci.firstIndex(where: { $0.copia == copia }) {
                tolte.append(voci[i].nome)
                voci.remove(at: i)
            }
        }
        UserDefaults.standard.set(tolte, forKey: "vh.copieTolte")
        salva()
    }

    func metti(_ v: VoceCerca, prezzo: PrezzoCerca?, valuta: String) {
        guard !contiene(v.id) else { return }
        voci.insert(VoceCarrello(id: v.id, nome: v.nome, annoPaese: [v.anno, v.paese].filter { !$0.isEmpty }.joined(separator: " "),
                                 miniatura: v.miniatura?.absoluteString, da: prezzo?.da, inVendita: prezzo?.inVendita ?? 0,
                                 valuta: prezzo?.valuta ?? valuta, avviso: nil, avvisato: nil), at: 0)
        salva()
    }

    func togli(_ id: Int) { voci.removeAll { $0.id == id && $0.copia == nil }; salva() }

    func avviso(_ id: Int, _ valore: Double?) {
        guard let i = voci.firstIndex(where: { $0.id == id && $0.copia == nil }) else { return }
        voci[i].avviso = valore
        voci[i].avvisato = nil
        salva()
    }

    /// Rilegge i prezzi di tutti i dischi; per le copie controlla se sono ancora in vendita (dopo tutto il resto).
    func aggiorna(client: DiscogsClient, valuta: String) async {
        await controllaCopie(client: client)
        for v in voci {
            if v.copia != nil { continue }
            guard let p = await PrezziCerca.shared.rileggi(v.id, client: client, valuta: valuta),
                  let i = voci.firstIndex(where: { $0.id == v.id && $0.copia == nil }) else { continue }
            voci[i].da = p.da
            voci[i].inVendita = p.inVendita
            voci[i].valuta = p.valuta
        }
        aggiornato = Date()
        salva()
    }

    var totale: Double { voci.filter { $0.venduta != true }.compactMap(\.conto).reduce(0, +) }
    /// Tutte copie precise: il totale è esatto (senza «da»).
    var soloCopie: Bool { !voci.isEmpty && voci.allSatisfy { $0.copia != nil } }
}

/// L'Avviso prezzo in sottofondo (insieme al controllo degli ordini): se il prezzo più basso di un disco del
/// Carrello scende sotto la cifra scelta, arriva la notifica «Prezzo sceso».
enum AvvisiPrezzo {
    static func controlla(client: DiscogsClient) async {
        await Carrello.shared.controllaCopie(client: client)      // V91: le copie comprate escono dal carrello anche da sole
        var voci = Carrello.leggi()
        var cambiato = false
        for i in voci.indices {
            guard voci[i].copia == nil, let soglia = voci[i].avviso, !Task.isCancelled else { continue }
            guard let s = try? await client.stats(voci[i].id, currency: voci[i].valuta, bassa: true), let da = s.lowestPrice?.value else { continue }
            voci[i].da = da
            voci[i].inVendita = s.numForSale ?? voci[i].inVendita
            cambiato = true
            if da <= soglia && voci[i].avvisato != da {
                voci[i].avvisato = da
                let c = UNMutableNotificationContent()
                c.title = "Prezzo sceso"
                c.body = "\(voci[i].nome) · da \(soldiIT(da, voci[i].valuta))"
                c.sound = .default
                c.userInfo = ["carrello": voci[i].id]
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "prezzo-\(voci[i].id)", content: c, trigger: nil))
            }
        }
        if cambiato { Carrello.scrivi(voci) }
    }
}

struct CarrelloView: View {
    /// Tocco sulla copertina: si chiude il carrello e si apre la scheda del disco.
    let apriScheda: (VoceCerca) -> Void
    @Environment(Seller.self) private var seller
    @Environment(\.dismiss) private var dismiss
    private let carrello = Carrello.shared
    @State private var leggo = false
    @State private var web: PaginaWeb?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(carrello.voci.count == 1 ? "1 DISCO" : "\(carrello.voci.count) DISCHI")
                                .font(Theme.mono(9, .bold)).tracking(1.3).foregroundStyle(Theme.muted)
                            Text((carrello.soloCopie ? "" : "da ") + soldiIT(carrello.totale, seller.currency))
                                .font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.money)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Text("+ le spedizioni dei venditori").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("PREZZI DISCOGS").font(Theme.mono(9, .bold)).tracking(1.3).foregroundStyle(Theme.muted)
                            Text(leggo ? "aggiorno…" : (carrello.aggiornato.map { "aggiornati alle " + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if !carrello.tolte.isEmpty {
                        // V91: le copie comprate su Discogs (da te o da un altro) sono uscite da sole
                        Text((carrello.tolte.count == 1 ? "Venduta · tolta dal carrello: " : "\(carrello.tolte.count) vendute · tolte dal carrello: ")
                             + carrello.tolte.joined(separator: ", "))
                            .font(.system(size: 13)).foregroundStyle(Theme.glow)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.glow.opacity(0.4), lineWidth: 1))
                    }
                    if carrello.voci.isEmpty {
                        Text("Il carrello è vuoto.\nTocca + su un disco per aggiungerlo.")
                            .font(.system(size: 14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    ForEach(carrello.voci, id: \.chiave) { v in RigaCarrello(voce: v, apriScheda: apriScheda, apriWeb: { web = $0 }) }
                    Text("Si compra su Discogs: ogni venditore spedisce il suo ordine. L'avviso arriva quando il prezzo più basso scende sotto la cifra che scrivi.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .sfondoHUD()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("CARRELLO").font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { Suoni.testa(); dismiss() }.foregroundStyle(Theme.accent)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Fine") { _ = UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                        .foregroundStyle(Theme.accent)
                }
            }
            .sheet(item: $web) { p in PaginaWebView(pagina: p) }
            .onDisappear { carrello.avvisoVisto() }
            .task {
                guard !carrello.voci.isEmpty else { return }
                leggo = true
                await carrello.aggiorna(client: seller.client, valuta: seller.currency)
                leggo = false
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            }
        }
    }
}

private struct RigaCarrello: View {
    let voce: VoceCarrello
    let apriScheda: (VoceCerca) -> Void
    /// V91: togliendo una copia aperta su Discogs, il carrello Discogs per «Remove».
    let apriWeb: (PaginaWeb) -> Void
    private let carrello = Carrello.shared
    @State private var soglia = ""
    @FocusState private var scrivo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { Suoni.tocco(); apriScheda(voceCerca) } label: {
                    AsyncImage(url: voce.miniatura.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    Text(voce.nome).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if voce.copia != nil {
                        // V83: la copia scelta: prezzo esatto · condizioni (disco / copertina) · venditore · paese
                        (Text(voce.prezzo.map { soldiIT($0, voce.valuta) } ?? "—").foregroundColor(Theme.money).fontWeight(.bold)
                            + Text(" · \(Self.sigla(voce.media)) / \(Self.sigla(voce.sleeve))"))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                        Text(voce.venduta == true ? "Non più in vendita su Discogs"
                             : [voce.venditore, voce.paese].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(voce.venduta == true ? Theme.warn : Theme.muted).lineLimit(1)
                    } else {
                        (Text(voce.da.map { "da " + soldiIT($0, voce.valuta) } ?? "nessuno in vendita").foregroundColor(Theme.money).fontWeight(.bold)
                            + Text(" · \(voce.inVendita) in vendita" + (voce.annoPaese.isEmpty ? "" : " · \(voce.annoPaese)")))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    Suoni.svuota()
                    if let c = voce.copia {
                        carrello.togliCopia(c)
                        if voce.suDiscogs == true { apriWeb(.carrelloDiscogs) }
                    } else { carrello.togli(voce.id) }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(white: 0.78))
                        .frame(width: 30, height: 30).background(Color(white: 0.23), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Togli dal carrello")
            }
            HStack(spacing: 8) {
              if voce.copia == nil {                       // l'Avviso prezzo vale per il disco, non per una copia
                HStack(spacing: 6) {
                    Image(systemName: "bell").font(.system(size: 13))
                    Text("Avviso sotto")
                    Spacer(minLength: 4)
                    TextField("—", text: $soglia)
                        .keyboardType(.decimalPad)
                        .focused($scrivo)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .foregroundStyle(Theme.text)
                    Text("€")
                }
                .font(.system(size: 13))
                .foregroundStyle(voce.avviso == nil ? Theme.muted : Theme.glow)
                .padding(.horizontal, 10).frame(height: 36)
                .background(Theme.panelHigh, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
              } else {
                Spacer()
              }
                if let url = voce.linkCompra {
                    Link(destination: url) {
                        Text("Compra").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 12).frame(height: 36)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.accent, lineWidth: 1.5))
                    }
                    .simultaneousGesture(TapGesture().onEnded { Suoni.tocco() })
                }
            }
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { soglia = voce.avviso.map { WarehouseView.italian($0).replacingOccurrences(of: ",00", with: "") } ?? "" }
        .onChange(of: scrivo) { _, s in
            guard !s else { return }
            let v = Double(soglia.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "."))
            let valore = (v ?? 0) > 0 ? v : nil
            if valore != voce.avviso { carrello.avviso(voce.id, valore); if valore != nil { Suoni.tocco() } }
            soglia = valore.map { WarehouseView.italian($0).replacingOccurrences(of: ",00", with: "") } ?? ""
        }
    }

    /// «Near Mint (NM or M-)» → «NM or M-», «Very Good Plus (VG+)» → «VG+».
    static func sigla(_ g: String?) -> String {
        guard let g, let a = g.lastIndex(of: "("), let b = g.lastIndex(of: ")"), a < b else { return g ?? "—" }
        return String(g[g.index(after: a)..<b])
    }

    /// Per aprire la scheda: i dati che ha il carrello (la scheda rilegge il resto da Discogs).
    private var voceCerca: VoceCerca {
        VoceCerca(id: voce.id, nome: voce.nome, miniatura: voce.miniatura)
    }
}

extension VoceCerca {
    /// Una voce fatta dai dati del carrello o del riconoscimento (la scheda rilegge il resto da Discogs).
    init(id: Int, nome: String, miniatura: String?) {
        var r = SearchResult(id: id, title: nome.replacingOccurrences(of: " – ", with: " - "))
        r.thumb = miniatura
        r.coverImage = miniatura
        self.init(r)
    }
}

/// V79: la notifica «Prezzo sceso» porta a Cerca › Carrello (come nel mock-up). Le altre notifiche restano come prima.
final class NotificheDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificheDelegate()
    static let apriCarrello = Notification.Name("vh.apriCarrello")
    /// V85: l'app è stata aperta toccando una notifica (allora non parte da Foto).
    static let chiaveApertura = "vh.apertaDaNotifica"

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.userInfo["carrello"] != nil {
            UserDefaults.standard.set(4, forKey: "selectedTab")
            UserDefaults.standard.set(true, forKey: Self.chiaveApertura)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NotificationCenter.default.post(name: Self.apriCarrello, object: nil)
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.content.userInfo["carrello"] != nil ? [.banner, .sound] : [])
    }
}
