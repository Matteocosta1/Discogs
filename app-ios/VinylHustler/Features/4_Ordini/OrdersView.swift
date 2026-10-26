import BackgroundTasks
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

/// 04 / ORDINI — come le serate in Discosizer: in alto i numeri, poi le schede degli ordini da evadere
/// (copertina, cosa, a chi, quanto, da dove prelevarlo), sotto quelli spediti e chiusi.
/// Tocchi una scheda e si apre il dettaglio con indirizzo da copiare e link a Discogs.
/// Discogs non ha webhook: l'app controlla gli ordini ogni 3 minuti mentre è aperta,
/// e in sottofondo quando iOS lo permette (BGAppRefreshTask), con notifica "Nuovo ordine".
///
/// V60 (come Discogs): Imballato mette l'ordine «In preparazione» su Discogs, Spedito chiede il tracking e lo
/// manda all'acquirente insieme allo stato «Shipped»; i messaggi dell'ordine si leggono e si scrivono qui;
/// finché l'acquirente non ha pagato Spedito è bloccato (Sollecita / Annulla); ogni scheda mostra il netto.
struct OrdersView: View {
    @Environment(Seller.self) private var seller
    /// V68: si rilegge ogni volta che si torna su Ordini (come prima).
    @Environment(\.sezioneVisibile) private var visibile
    @Query private var discs: [Disc]
    @State private var orders: [Order] = []
    @State private var error: String?
    @State private var avviso: String?
    @State private var loading = false
    @State private var detail: Order?
    @State private var chat: Order?
    @State private var spedizione: Order?
    private let timer = Timer.publish(every: 180, on: .main, in: .common).autoconnect()
    /// Preso / Imballato / Spedito, segnati nell'app (sul telefono): 0 = niente, 3 = spedito.
    @State private var checkedAt: Date?
    @State private var steps: [String: Int] = (UserDefaults.standard.dictionary(forKey: "orderSteps") as? [String: Int]) ?? [:]
    /// V60: la conversazione di ogni ordine aperto (riletta solo se l'ordine ha novità) e i messaggi non letti.
    @State private var messaggi: [String: [OrderMessage]] = [:]
    @State private var attivitaLetta: [String: String] = [:]
    @State private var nonLetti: [String: Int] = [:]
    /// La riga sotto la pista di ogni scheda («DISCOGS AGGIORNATO…»).
    @State private var note: [String: String] = [:]
    /// Ordini con una richiesta a Discogs in corso.
    @State private var lavoro: Set<String> = []
    /// Spediti adesso: restano un attimo tra gli aperti, il tempo del furgoncino.
    @State private var inUscita: Set<String> = []
    /// I messaggi sono già stati letti una volta (dopo, un messaggio nuovo dell'acquirente suona).
    @State private var chatPronte = false

    private func step(_ o: Order) -> Int {
        let locale = steps[o.id] ?? 0
        return StatoPagamento(o.status) == .inPreparazione ? max(locale, 2) : locale
    }
    private var open: [Order] { orders.filter { !OrderStyle.closed($0.status) && (step($0) < 3 || inUscita.contains($0.id)) } }
    private var closed: [Order] { orders.filter { !open.map(\.id).contains($0.id) } }

    private func setStep(_ o: Order, _ v: Int) {
        steps[o.id] = v
        UserDefaults.standard.set(steps, forKey: "orderSteps")
    }
    private var cashed: Double { orders.filter { !$0.status.hasPrefix("Cancelled") }.compactMap { $0.total?.value }.reduce(0, +) }

    /// Il netto del mese: totale meno la commissione Discogs, degli ordini di questo mese non annullati.
    private var nettoMese: Double {
        let cal = Calendar.current
        let ora = Date()
        return orders.filter { o in
            guard !o.status.hasPrefix("Cancelled"), let d = ChatOrdini.data(o.created) else { return false }
            return cal.isDate(d, equalTo: ora, toGranularity: .month)
        }
        .map { OrderCifre.netto($0) }
        .reduce(0, +)
    }

    private var testata: String {
        let mese = Date().formatted(.dateTime.month(.wide).locale(Locale(identifier: "it_IT"))).uppercased()
        let netto = soldiIT(nettoMese, seller.currency)
        return "APERTI · \(open.count) · NETTO DI \(mese) \(netto)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(testata).font(Theme.mono(10, .bold)).tracking(2).foregroundStyle(Theme.glow)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                    HStack {
                        stat("\(open.count)", "aperti", highlight: !open.isEmpty)
                        stat("\(closed.count)", "spediti")
                        stat(cashed.formatted(.currency(code: seller.currency).precision(.fractionLength(2))), "incassato", highlight: true, money: true)
                    }
                    .padding(16)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))

                    if open.isEmpty && !loading {
                        // niente ordini da spedire: una riga sola, con l'ora dell'ultimo controllo
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Nessun ordine da spedire").font(.system(size: 15, weight: .semibold))
                                Text(checkedAt.map { "Controllato alle \($0.formatted(date: .omitted, time: .shortened)) · ricontrollo ogni 3 minuti" }
                                     ?? "Ricontrollo ogni 3 minuti")
                                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("APERTI").font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.leading, 16)
                            ForEach(open) { o in
                                OpenOrderCard(order: o, box: box(for: o), step: step(o), currency: seller.currency,
                                              stato: StatoPagamento(o.status), nonLetti: nonLetti[o.id] ?? 0,
                                              nota: note[o.id], lavoro: lavoro.contains(o.id),
                                              onOpen: { Suoni.tocco(); detail = o },
                                              onStep: { v in tocca(o, v) },
                                              onMessaggi: { Suoni.tocco(); chat = o },
                                              onSollecita: { Task { await sollecita(o) } },
                                              onAnnulla: { nonPagato in Task { await annulla(o, nonPagato: nonPagato) } })
                                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                            removal: .move(edge: .trailing).combined(with: .opacity)))
                            }
                        }
                    }
                    if !closed.isEmpty {
                        // spediti e chiusi: righe piccole e smorzate (sono fatti, non c'è niente da fare)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SPEDITI E CHIUSI").font(Theme.mono(10, .semibold)).tracking(2).foregroundStyle(Theme.muted)
                            ForEach(closed) { o in
                                Button { Suoni.tocco(); detail = o } label: { closedRow(o) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .sfondoHUD()
            .senzaTitolo("Ordini")
            .refreshable { await Task { await load() }.value }   // Task a parte: il gesto non la interrompe
            .overlay { if loading && orders.isEmpty { ProgressView("Leggo gli ordini…").tint(Theme.accent) } }
            .task(id: visibile) { guard visibile else { return }; await Task { await load() }.value; await OrderWatcher.requestPermission() }
            .onReceive(timer) { _ in Task { await load() } }
            .sheet(item: $detail) { o in
                OrderDetail(order: o, box: box(for: o))
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $chat) { o in
                MessaggiSheet(order: o, onLetti: { ricontaNonLetti(o) })
            }
            .sheet(item: $spedizione) { o in
                SpedizioneSheet(order: o, onSpedito: { spedito(o) })
            }
            .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {}
            .alert(avviso ?? "", isPresented: Binding(get: { avviso != nil }, set: { if !$0 { avviso = nil } })) {}
        }
    }

    private func stat(_ value: String, _ label: String, highlight: Bool = false, money: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 26, weight: .bold)).foregroundStyle(money ? Theme.money : (highlight ? Theme.glow : Theme.text))
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Un ordine già spedito o chiuso: copertina piccola, titolo grigio, stato e data, importo.
    private func closedRow(_ o: Order) -> some View {
        let style = OrderStyle(step(o) >= 3 && !OrderStyle.closed(o.status) ? "Shipped" : o.status)
        return HStack(spacing: 12) {
            AsyncImage(url: o.items.first?.release.thumbnail.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                .frame(width: 36, height: 36).clipShape(Circle()).opacity(0.8)
            VStack(alignment: .leading, spacing: 2) {
                Text(o.items.first?.release.description ?? "Ordine \(o.id)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(white: 0.78)).lineLimit(1)
                Text("\(style.label) · \(OrderStyle.date(o.created))").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 4)
            if let t = o.total {
                Text(t.value, format: .currency(code: t.currency ?? seller.currency))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(red: 0.071, green: 0.071, blue: 0.075), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    /// Da dove prelevare: il posto del primo disco dell'ordine (scatola, casa…).
    private func box(for o: Order) -> String? {
        let boxes = o.items.compactMap { item in discs.first(where: { $0.listingID == item.id })?.box }.filter { !$0.isEmpty }
        return boxes.isEmpty ? nil : Array(Set(boxes)).sorted().joined(separator: ", ")
    }

    // MARK: - I passi: Preso (sul telefono) → Imballato (In Progress su Discogs) → Spedito (tracking + Shipped)

    private func tocca(_ o: Order, _ n: Int) {
        guard !lavoro.contains(o.id) else { return }
        let stato = StatoPagamento(o.status)
        if n >= 3 {
            guard stato != .daPagare else {
                Suoni.tocco()
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                note[o.id] = "PRIMA IL PAGAMENTO: SPEDITO SI SBLOCCA QUANDO HA PAGATO"
                return
            }
            Suoni.tocco()
            spedizione = o
            return
        }
        guard n > step(o) else { Suoni.tocco(); return }        // un passo già fatto non si disfa
        Suoni.tocco()
        if n == 2 && stato == .pagato && puo(o, "In Progress") {
            // Imballato: su Discogs l'ordine diventa «In preparazione» (l'acquirente riceve l'avviso)
            lavoro.insert(o.id)
            Task { @MainActor in
                do {
                    try await seller.client.setOrderStatus(o.id, status: "In Progress")
                    withAnimation(.spring(duration: 0.4)) { setStep(o, 2) }
                    note[o.id] = "DISCOGS AGGIORNATO · IN PREPARAZIONE · \(o.buyer.username.uppercased()) AVVISATO"
                    lavoro.remove(o.id)
                    await load()
                } catch {
                    lavoro.remove(o.id)
                    Suoni.nego()
                    self.error = "Discogs non ha cambiato lo stato: " + error.localizedDescription
                }
            }
        } else {
            withAnimation(.spring(duration: 0.4)) { setStep(o, n) }
            note[o.id] = n == 1 ? "PRESO · SEGNATO SUL TELEFONO" : "IMBALLATO · SEGNATO SUL TELEFONO"
        }
    }

    /// Si può portare l'ordine in quello stato adesso? (Discogs lo dice in next_status; se non lo dice, si prova.)
    private func puo(_ o: Order, _ stato: String) -> Bool { o.nextStatus?.contains(stato) ?? true }

    /// Discogs ha accettato «Shipped»: il furgoncino arriva in fondo, poi la scheda esce.
    private func spedito(_ o: Order) {
        Suoni.fatto()
        inUscita.insert(o.id)
        note[o.id] = "SPEDITO SU DISCOGS · TRACKING INVIATO A \(o.buyer.username.uppercased())"
        setStep(o, 3)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1300))
            _ = withAnimation(.easeInOut(duration: 0.45)) { inUscita.remove(o.id) }
            await load()
        }
    }

    /// Sollecita: un promemoria all'acquirente che non ha pagato (al massimo uno al giorno).
    private func sollecita(_ o: Order) async {
        let chiave = "sollecito-\(o.id)"
        if let ultimo = UserDefaults.standard.object(forKey: chiave) as? Date, Date().timeIntervalSince(ultimo) < 86_400 {
            Suoni.tocco()
            note[o.id] = "PROMEMORIA GIÀ INVIATO OGGI"
            return
        }
        Suoni.tocco()
        lavoro.insert(o.id)
        defer { lavoro.remove(o.id) }
        let testo = "Ciao \(o.buyer.username), ti ricordo il pagamento dell\u{2019}ordine \(o.id). Appena arriva lo spedisco. Grazie!"
        do {
            try await seller.client.postOrderMessage(o.id, message: testo)
            UserDefaults.standard.set(Date(), forKey: chiave)
            note[o.id] = "PROMEMORIA INVIATO · \(o.buyer.username.uppercased())"
        } catch {
            Suoni.nego()
            self.error = "Promemoria non inviato: " + error.localizedDescription
        }
    }

    /// Annulla con il motivo: «Non pagato» → il disco torna in vendita; «Non disponibile» → l'annuncio si toglie.
    private func annulla(_ o: Order, nonPagato: Bool) async {
        lavoro.insert(o.id)
        defer { lavoro.remove(o.id) }
        let stato = nonPagato ? "Cancelled (Non-Paying Buyer)" : "Cancelled (Item Unavailable)"
        guard puo(o, stato) else {
            Suoni.nego()
            note[o.id] = nonPagato ? "NON ANCORA POSSIBILE SU DISCOGS: L'ACQUIRENTE HA ANCORA TEMPO PER PAGARE"
                                   : "NON ANCORA POSSIBILE SU DISCOGS"
            return
        }
        do {
            try await seller.client.setOrderStatus(o.id, status: stato)
        } catch {
            Suoni.nego()
            self.error = "Ordine non annullato: " + error.localizedDescription
            return
        }
        Suoni.svuota()
        var problemi: [String] = []
        for item in o.items {
            let nome = item.release.description ?? "annuncio \(item.id)"
            if nonPagato {
                // deve tornare in vendita: se Discogs non l'ha già rimesso, lo rimettiamo noi
                let attuale = (try? await seller.client.listing(item.id))?.status
                if attuale == "For Sale" { continue }
                if attuale == "Draft" || attuale == "Expired" {
                    do { try await seller.client.editListing(item.id, changes: ["status": "For Sale"]) } catch { problemi.append(nome) }
                } else {
                    problemi.append(nome)
                }
            } else {
                do { try await seller.deleteListing(item.id, discs: discs) } catch { problemi.append(nome) }
            }
        }
        if problemi.isEmpty {
            avviso = nonPagato ? "Ordine annullato (non pagato). Il disco è di nuovo in vendita."
                               : "Ordine annullato (disco non disponibile). L'annuncio è stato tolto."
        } else {
            avviso = "Ordine annullato su Discogs. Da sistemare a mano su Discogs: " + problemi.joined(separator: ", ")
        }
        await load()
    }

    /// Dopo aver aperto la chat: il pallino rosso si riconta (i messaggi sono letti).
    private func ricontaNonLetti(_ o: Order) {
        nonLetti[o.id] = ChatOrdini.nonLetti(messaggi[o.id] ?? [], ordine: o)
        // la conversazione si rilegge al prossimo controllo (ci sono messaggi nuovi miei)
        attivitaLetta[o.id] = nil
    }

    /// Una lettura per volta: se ne arriva un'altra mentre legge, si rilegge una volta alla fine.
    @State private var rileggi = false

    private func load() async {
        guard !loading else { rileggi = true; return }
        loading = true
        defer {
            loading = false
            if rileggi { rileggi = false; Task { await load() } }
        }
        do {
            let page = try await seller.client.orders()
            // lo stato su Discogs è cambiato (per esempio ha pagato): la riga sotto la pista riparte pulita
            let vecchi = Dictionary(orders.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
            for o in page.orders where vecchi[o.id] != nil && vecchi[o.id] != o.status { note[o.id] = nil }
            await OrderWatcher.notifyNew(page.orders)
            let before = Set(orders.map(\.id))
            if !orders.isEmpty, page.orders.contains(where: { !before.contains($0.id) && !OrderStyle.closed($0.status) }) {
                Suoni.nuovoOrdine()                      // è arrivato un ordine mentre guardi la pagina
            }
            withAnimation(.snappy) { orders = page.orders }
            checkedAt = Date()
            error = nil
            await leggiMessaggi(page.orders)
        } catch {
            // lettura interrotta (cambio scheda, nuovo aggiornamento): non è un errore da mostrare
            if error.isCancellation { return }
            self.error = error.localizedDescription
        }
    }

    /// I messaggi degli ordini aperti: si rileggono solo quelli con novità (last_activity cambiata).
    private func leggiMessaggi(_ tutti: [Order]) async {
        let prima = nonLetti.values.reduce(0, +)
        for o in tutti where !OrderStyle.closed(o.status) {
            let attivita = o.lastActivity ?? o.created
            if messaggi[o.id] != nil && attivitaLetta[o.id] == attivita { continue }
            guard let m = try? await seller.client.orderMessages(o.id) else { continue }
            messaggi[o.id] = m
            attivitaLetta[o.id] = attivita
            nonLetti[o.id] = ChatOrdini.nonLetti(m, ordine: o)
        }
        if chatPronte && nonLetti.values.reduce(0, +) > prima { Suoni.nuovoOrdine() }   // l'acquirente ha scritto
        chatPronte = true
    }
}

extension Error {
    /// Una richiesta annullata (cambi scheda mentre carica): niente avviso.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

/// Lo stato del pagamento, come lo mostra la scheda (pastiglia in alto).
enum StatoPagamento: Equatable {
    case daPagare, pagato, inPreparazione, spedito, altro

    init(_ status: String) {
        if status.hasPrefix("Payment Received") { self = .pagato }
        else if status.hasPrefix("In Progress") { self = .inPreparazione }
        else if status.hasPrefix("Shipped") { self = .spedito }
        else if ["New Order", "Buyer Contacted", "Invoice Sent", "Payment Pending", "Order Changed"].contains(where: { status.hasPrefix($0) }) {
            self = .daPagare
        } else { self = .altro }
    }

    var etichetta: String {
        switch self {
        case .daPagare: return "DA PAGARE"
        case .pagato: return "PAGATO"
        case .inPreparazione: return "IN PREPARAZIONE"
        case .spedito: return "SPEDITO"
        case .altro: return "ORDINE"
        }
    }
    var testo: Color {
        switch self {
        case .daPagare: return Color(red: 0.10, green: 0.07, blue: 0)
        case .pagato, .spedito: return Color.black
        case .inPreparazione: return Theme.glow
        case .altro: return Theme.muted
        }
    }
    var fondo: Color {
        switch self {
        case .daPagare: return Color(hex: 0xFFD60A)
        case .pagato, .spedito: return Theme.money
        case .inPreparazione: return Theme.military
        case .altro: return Theme.panelHigh
        }
    }
}

/// Totale, commissione Discogs e netto di un ordine.
enum OrderCifre {
    static func totale(_ o: Order) -> Double { o.total?.value ?? 0 }
    static func commissione(_ o: Order) -> Double { o.fee?.value ?? 0 }
    static func netto(_ o: Order) -> Double { totale(o) - commissione(o) }
}

/// Un radar piccolo (come un'icona): il fascio gira piano, l'app sta controllando gli ordini.
struct MiniRadar: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let giro = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2) / 3.2 * 360
            ZStack {
                Circle().fill(Color(red: 0.04, green: 0.07, blue: 0.05))
                Circle().stroke(Theme.accent.opacity(0.35), lineWidth: 1)
                Circle().stroke(Theme.accent.opacity(0.2), lineWidth: 1).padding(8)
                Circle()
                    .fill(AngularGradient(colors: [Theme.glow.opacity(0.6), Theme.glow.opacity(0), .clear, .clear], center: .center))
                    .rotationEffect(.degrees(giro))
                Circle().fill(Theme.glow).frame(width: 4, height: 4).shadow(color: Theme.glow, radius: 3).offset(x: 6, y: -6)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Un ordine da evadere (come nel mock-up V60): stato del pagamento, totale / Discogs / netto,
/// «Preleva da …», la pista Preso → Imballato → Spedito con il furgoncino, la riga di Discogs
/// e i tasti Messaggi (con il pallino rosso), Sollecita e Annulla (solo se non ha pagato).
struct OpenOrderCard: View {
    let order: Order
    let box: String?
    let step: Int
    let currency: String
    let stato: StatoPagamento
    let nonLetti: Int
    let nota: String?
    let lavoro: Bool
    let onOpen: () -> Void
    let onStep: (Int) -> Void
    let onMessaggi: () -> Void
    let onSollecita: () -> Void
    let onAnnulla: (Bool) -> Void          // true = non pagato, false = disco non disponibile

    /// «Annulla» toccato: si chiede il motivo nella scheda stessa.
    @State private var chiediMotivo = false

    private var giorni: Int {
        guard let d = ChatOrdini.data(order.created) else { return 0 }
        return max(0, Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0)
    }
    private var riga: String? {
        if let nota { return nota }
        if stato == .daPagare {
            return "ATTESA PAGAMENTO · DA \(giorni) \(giorni == 1 ? "GIORNO" : "GIORNI") · SPEDITO BLOCCATO"
        }
        return nil
    }
    private var rigaGialla: Bool { stato == .daPagare && (nota == nil || nota?.hasPrefix("PRIMA") == true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    AsyncImage(url: order.items.first?.release.thumbnail.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                        .frame(width: 52, height: 52).clipShape(Circle())
                        .overlay(Circle().stroke(Theme.accent, lineWidth: 1.5))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(stato.etichetta).font(Theme.mono(9, .bold)).tracking(1.2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .foregroundStyle(stato.testo).background(stato.fondo, in: Capsule())
                        Text("\(OrderStyle.date(order.created)) · \(order.buyer.username)")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                        Text(order.items.first?.release.description ?? "Ordine \(order.id)")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        if order.items.count > 1 {
                            Text("+ altri \(order.items.count - 1) dischi").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer(minLength: 4)
                    if let t = order.total {
                        Text(soldiIT(t.value, t.currency ?? currency))
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.money)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let box {
                Label("Preleva da \(box)", systemImage: "shippingbox.fill")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            cifre

            PistaSpedizione(step: step, bloccato: stato == .daPagare, tocca: onStep)

            if riga != nil || lavoro {
                HStack(spacing: 6) {
                    if lavoro { ProgressView().controlSize(.mini).tint(Theme.glow) }
                    Text(lavoro ? "DISCOGS…" : (riga ?? ""))
                        .font(Theme.mono(9.5, .bold)).tracking(1.2)
                        .foregroundStyle(rigaGialla && !lavoro ? Color(hex: 0xFFD60A) : Theme.glow)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            azioni
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .stroke(Theme.glow.opacity(0.35), lineWidth: 1)
        )
    }

    /// TOTALE / DISCOGS / NETTO.
    private var cifre: some View {
        let tot = OrderCifre.totale(order), fee = OrderCifre.commissione(order)
        let valuta = order.total?.currency ?? currency
        return HStack(spacing: 6) {
            cifra("TOTALE", Text(soldiIT(tot, valuta)), Theme.text)
            cifra("DISCOGS", Text("−" + soldiIT(fee, valuta)), Color(hex: 0xFF9F0A))
            cifra("NETTO", Text(soldiIT(tot - fee, valuta)), Theme.money)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func cifra(_ titolo: String, _ valore: Text, _ colore: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(titolo).font(Theme.mono(8.5, .bold)).tracking(1.2).foregroundStyle(Theme.muted)
            valore.font(.system(size: 14, weight: .bold)).foregroundStyle(colore)
                .lineLimit(1).minimumScaleFactor(0.7).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var azioni: some View {
        if chiediMotivo {
            HStack(spacing: 8) {
                tasto("Non pagato", rosso: true) { chiediMotivo = false; onAnnulla(true) }
                tasto("Non disponibile", rosso: true) { chiediMotivo = false; onAnnulla(false) }
                tasto("Indietro") { Suoni.tocco(); chiediMotivo = false }
            }
        } else {
            HStack(spacing: 8) {
                Button(action: onMessaggi) {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left").font(.system(size: 14, weight: .semibold))
                        Text("Messaggi").font(.system(size: 14, weight: .semibold))
                        if nonLetti > 0 {
                            Text("\(nonLetti)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                                .background(Theme.warn, in: Capsule())
                        }
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.accent, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(nonLetti > 0 ? "Messaggi, \(nonLetti) da leggere" : "Messaggi")
                if stato == .daPagare {
                    tasto("Sollecita", action: onSollecita)
                    tasto("Annulla", rosso: true) { Suoni.tocco(); chiediMotivo = true }
                }
            }
            .disabled(lavoro)
        }
    }

    private func tasto(_ titolo: String, rosso: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(titolo).font(.system(size: 13, weight: .semibold))
                .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
                .foregroundStyle(rosso ? Theme.warn : Theme.accent)
                .frame(maxWidth: .infinity, minHeight: 40)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(rosso ? Theme.warn.opacity(0.6) : Theme.accent, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// La pista Preso → Imballato → Spedito (proposta 9): una linea che si riempie e il furgoncino che parte.
/// Spedito ha il lucchetto finché l'acquirente non ha pagato.
struct PistaSpedizione: View {
    let step: Int
    let bloccato: Bool
    let tocca: (Int) -> Void

    private let nomi = ["Preso", "Imballato", "Spedito"]

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let pista = max(0, w - 72)
            let fr: CGFloat = step <= 1 ? 0 : CGFloat(min(step, 3) - 1) / 2
            ZStack(alignment: .topLeading) {
                Capsule().fill(Theme.glow.opacity(0.15))
                    .frame(width: pista, height: 3).offset(x: 36, y: 13)
                Capsule().fill(Theme.glow).shadow(color: Theme.glow, radius: 3)
                    .frame(width: pista * fr, height: 3).offset(x: 36, y: 13)
                ForEach(0..<3, id: \.self) { k in
                    nodo(k).offset(x: CGFloat(k) * pista / 2, y: 0)
                }
                Image(systemName: "box.truck.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.glow)
                    .shadow(color: Theme.glow, radius: 4)
                    .offset(x: 36 + fr * pista - 13, y: -16)
                    .opacity(step >= 2 ? 1 : 0)
            }
            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 1.1), value: step)
        }
        .frame(height: 52)
        .padding(.top, 14)
    }

    private func nodo(_ k: Int) -> some View {
        let fatto = step > k
        let blocco = bloccato && k == 2
        return Button { tocca(k + 1) } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(fatto ? Theme.glow : Color(red: 0.043, green: 0.059, blue: 0.047))
                    Circle().stroke(fatto ? Theme.glow : Theme.glow.opacity(0.35), lineWidth: 2)
                    if fatto {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(Color.black)
                    } else if blocco {
                        Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                }
                .frame(width: 28, height: 28)
                .shadow(color: fatto ? Theme.glow.opacity(0.6) : .clear, radius: 5)
                Text(nomi[k]).font(.system(size: 11, weight: .semibold)).foregroundStyle(fatto ? Theme.glow : Theme.muted)
            }
            .opacity(blocco ? 0.45 : 1)
            .frame(width: 72, height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(nomi[k] + (fatto ? ": fatto" : (blocco ? ": bloccato, prima il pagamento" : "")))
    }
}

/// Il dettaglio di un ordine: dischi, da dove prelevarli, indirizzo da copiare, link a Discogs.
private struct OrderDetail: View {
    @Environment(Seller.self) private var seller
    let order: Order
    let box: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        let style = OrderStyle(order.status)
                        Text(style.label).font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .foregroundStyle(style.fg).background(style.bg, in: Capsule())
                        Spacer()
                        if let t = order.total {
                            Text(t.value, format: .currency(code: t.currency ?? seller.currency))
                                .font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.glow)
                        }
                    }
                    LabeledContent("Acquirente", value: order.buyer.username)
                    LabeledContent("Data", value: OrderStyle.date(order.created))
                    if let box { LabeledContent("Preleva da", value: box) }
                }
                Section("DISCHI") {
                    ForEach(order.items, id: \.id) { item in
                        HStack(spacing: 12) {
                            AsyncImage(url: item.release.thumbnail.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                                .frame(width: 44, height: 44).clipShape(Circle())
                            Text(item.release.description ?? "Release \(item.release.id)").font(.system(size: 15))
                            Spacer()
                            if let p = item.price {
                                Text(p.value, format: .currency(code: p.currency ?? seller.currency)).font(.system(size: 15, weight: .semibold))
                            }
                        }
                    }
                }
                if let address = order.shippingAddress, !address.isEmpty {
                    Section("SPEDIRE A") {
                        Text(address).font(.system(size: 15)).textSelection(.enabled)
                        Button(copied ? "Copiato" : "Copia l'indirizzo", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            // V56: solo su questo telefono (non sugli altri dispositivi Apple) e per 10 minuti
                            UIPasteboard.general.setItems([["public.utf8-plain-text": address]],
                                                          options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
                            Suoni.tocco()
                            copied = true
                        }
                    }
                }
                Section {
                    Link("Apri l'ordine su Discogs", destination: URL(string: "https://www.discogs.com/sell/order/\(order.id)")!)
                }
            }
            .themedBackground()
            .navigationTitle("Ordine \(order.id)")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Theme.accent)
        }
        .preferredColorScheme(.dark)
    }
}

/// Stato dell'ordine in italiano, con i colori delle pastiglie di Discosizer.
struct OrderStyle {
    let label: String
    let fg: Color
    let bg: Color

    init(_ status: String) {
        let v: (String, Color, Color)
        switch status {
        case let s where s.hasPrefix("New Order"): v = ("Nuovo", Theme.glow, Theme.glow.opacity(0.14))
        case let s where s.hasPrefix("Buyer Contacted"): v = ("Acquirente contattato", Theme.glow, Theme.glow.opacity(0.14))
        case let s where s.hasPrefix("Invoice Sent"): v = ("Fattura inviata", Theme.glow, Theme.glow.opacity(0.14))
        case let s where s.hasPrefix("Payment Pending"): v = ("Pagamento in attesa", Theme.warn, Theme.warnSoft)
        case let s where s.hasPrefix("Payment Received"): v = ("Pagato · da spedire", Theme.money, Theme.military)
        case let s where s.hasPrefix("In Progress"): v = ("In lavorazione", Theme.money, Theme.military)
        case let s where s.hasPrefix("Shipped"): v = ("Spedito", Theme.muted, Theme.panelHigh)
        case let s where s.hasPrefix("Merged"): v = ("Unito a un altro", Theme.muted, Theme.panelHigh)
        case let s where s.hasPrefix("Cancelled"): v = ("Annullato", Theme.warn, Theme.warnSoft)
        default: v = (status, Theme.muted, Theme.panelHigh)
        }
        label = v.0
        fg = v.1
        bg = v.2
    }

    static func closed(_ status: String) -> Bool {
        ["Shipped", "Cancelled", "Merged"].contains { status.hasPrefix($0) }
    }

    /// "2026-10-15T10:20:00-07:00" -> "15 ottobre 2026"
    static func date(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return String(iso.prefix(10)) }
        return d.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "it_IT")))
    }
}

/// Notifiche dei nuovi ordini (in primo piano e con l'aggiornamento in sottofondo di iOS).
enum OrderWatcher {
    static let taskID = "it.vinylhustler.app.orders"     // anche in Info.plist > BGTaskSchedulerPermittedIdentifiers
    private static let seenKey = "seenOrders"

    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func notifyNew(_ orders: [Order]) async {
        var seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        let firstRun = !UserDefaults.standard.bool(forKey: "ordersInitialized")
        for o in orders where !seen.contains(o.id) {
            seen.insert(o.id)
            guard !firstRun else { continue }       // al primo avvio non si notificano gli ordini vecchi
            let content = UNMutableNotificationContent()
            content.title = "Nuovo ordine"
            content.body = corpo(o)
            content.sound = .default
            // V60: la copertina del disco venduto nella notifica (se si scarica in tempo)
            if let allegato = await copertina(o) { content.attachments = [allegato] }
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: o.id, content: content, trigger: nil))
        }
        UserDefaults.standard.set(Array(seen), forKey: seenKey)
        UserDefaults.standard.set(true, forKey: "ordersInitialized")
    }

    /// «Artista – Titolo · 124,00 €» (con «+ altri N» se l'ordine ha più dischi).
    static func corpo(_ o: Order) -> String {
        var t = o.items.first?.release.description ?? "Ordine \(o.id)"
        if o.items.count > 1 { t += " + altri \(o.items.count - 1)" }
        if let tot = o.total {
            let prezzo = soldiIT(tot.value, tot.currency ?? "EUR")
            t += " · " + prezzo
        }
        return t
    }

    /// La copertina scaricata in un file temporaneo, come allegato della notifica (immagine pubblica di Discogs).
    static func copertina(_ o: Order) async -> UNNotificationAttachment? {
        guard let indirizzo = o.items.first?.release.thumbnail, let url = URL(string: indirizzo) else { return nil }
        var richiesta = URLRequest(url: url, timeoutInterval: 8)
        richiesta.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
        guard let risposta = try? await URLSession.shared.data(for: richiesta) else { return nil }
        let dati: Data = risposta.0
        guard !dati.isEmpty else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ordine-\(o.id)-\(UUID().uuidString).jpg")
        guard (try? dati.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "copertina", url: file, options: nil)
    }

    /// Da chiamare all'avvio (VinylHustlerApp) per registrare il controllo in sottofondo.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            schedule()
            let work = Task {
                let client = DiscogsClient()
                if let page = try? await client.orders() { await notifyNew(page.orders) }
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)   // iOS decide quando, di solito non prima
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// V61: soldi all'italiana sempre uguali (1.234,50 €), come nel Magazzino: il formattatore di sistema sotto i 10.000
/// non mette il punto delle migliaia e segue la lingua del telefono.
func soldiIT(_ valore: Double, _ valuta: String) -> String {
    // stessa regola di WarehouseView.italian, scritta qui: questa funzione si usa anche fuori dalle viste
    let centesimi = Int((abs(valore) * 100).rounded())
    var intero = String(centesimi / 100)
    var gruppi: [String] = []
    while intero.count > 3 {
        gruppi.insert(String(intero.suffix(3)), at: 0)
        intero.removeLast(3)
    }
    gruppi.insert(intero, at: 0)
    let testo = (valore < 0 ? "-" : "") + gruppi.joined(separator: ".") + "," + String(format: "%02d", centesimi % 100)
    return testo + (valuta == "EUR" ? " €" : " \(valuta)")
}
