import BackgroundTasks
import SwiftData
import SwiftUI
import UserNotifications

/// 04 / ORDINI — come le serate in Discosizer: in alto i numeri, poi le schede degli ordini da evadere
/// (copertina, cosa, a chi, quanto, da dove prelevarlo), sotto quelli spediti e chiusi.
/// Tocchi una scheda e si apre il dettaglio con indirizzo da copiare e link a Discogs.
/// Discogs non ha webhook: l'app controlla gli ordini ogni 3 minuti mentre è aperta,
/// e in sottofondo quando iOS lo permette (BGAppRefreshTask), con notifica "Nuovo ordine".
struct OrdersView: View {
    @Environment(Seller.self) private var seller
    @Query private var discs: [Disc]
    @State private var orders: [Order] = []
    @State private var error: String?
    @State private var loading = false
    @State private var detail: Order?
    private let timer = Timer.publish(every: 180, on: .main, in: .common).autoconnect()

    private var open: [Order] { orders.filter { !OrderStyle.closed($0.status) } }
    private var closed: [Order] { orders.filter { OrderStyle.closed($0.status) } }
    private var cashed: Double { orders.filter { !$0.status.hasPrefix("Cancelled") }.compactMap { $0.total?.value }.reduce(0, +) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        stat("\(open.count)", "da evadere", highlight: !open.isEmpty)
                        stat("\(closed.count)", "spediti e chiusi")
                        stat(cashed.formatted(.currency(code: seller.currency).precision(.fractionLength(0))), "incassato")
                    }
                    .padding(16)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))

                    section("DA EVADERE", open, empty: "Nessun ordine da spedire. Quando arriva, ti avviso.")
                    section("SPEDITI E CHIUSI", closed, empty: nil)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.bg)
            .navigationTitle("Ordini")
            .refreshable { await Task { await load() }.value }   // Task a parte: il gesto non la interrompe
            .overlay { if loading && orders.isEmpty { ProgressView("Leggo gli ordini…").tint(Theme.accent) } }
            .task { await Task { await load() }.value; await OrderWatcher.requestPermission() }
            .onReceive(timer) { _ in Task { await load() } }
            .sheet(item: $detail) { o in
                OrderDetail(order: o, box: box(for: o))
                    .presentationDetents([.medium, .large])
            }
            .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {}
        }
    }

    private func stat(_ value: String, _ label: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 28, weight: .bold)).foregroundStyle(highlight ? Theme.glow : Theme.text)
                .contentTransition(.numericText())
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func section(_ title: String, _ list: [Order], empty: String?) -> some View {
        if !list.isEmpty || empty != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.leading, 16)
                VStack(spacing: 0) {
                    if list.isEmpty, let empty {
                        Text(empty).font(.system(size: 15)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, o in
                        Button { Suoni.tocco(); detail = o } label: { card(o) }
                            .buttonStyle(.plain)
                        if i < list.count - 1 { Divider().overlay(Theme.line).padding(.leading, 84) }
                    }
                }
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
        }
    }

    /// Una scheda: copertina tonda, cosa e a chi, importo in pastiglia, da dove prelevarlo.
    private func card(_ o: Order) -> some View {
        let style = OrderStyle(o.status)
        let first = o.items.first
        return HStack(spacing: 14) {
            AsyncImage(url: first?.release.thumbnail.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                .frame(width: 54, height: 54)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.accent.opacity(0.8), lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 4) {
                Text(first?.release.description ?? "Ordine \(o.id)")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                if o.items.count > 1 {
                    Text("+ altri \(o.items.count - 1) dischi").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                Text("\(o.buyer.username) · \(OrderStyle.date(o.created))").font(.system(size: 14)).foregroundStyle(Theme.muted)
                HStack(spacing: 6) {
                    Text(style.label).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .foregroundStyle(style.fg).background(style.bg, in: Capsule())
                    if let box = box(for: o), !OrderStyle.closed(o.status) {
                        Label(box, systemImage: "archivebox.fill").font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .foregroundStyle(Color.black).background(Theme.accent, in: Capsule())
                    }
                }
            }
            Spacer(minLength: 4)
            if let t = o.total {
                Text(t.value, format: .currency(code: t.currency ?? seller.currency))
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .foregroundStyle(Theme.money).background(Theme.military, in: Capsule())
            }
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
        }
        .padding(14)
        .contentShape(Rectangle())
        .opacity(OrderStyle.closed(o.status) ? 0.75 : 1)
    }

    /// Da dove prelevare: il posto del primo disco dell'ordine (scatola, casa…).
    private func box(for o: Order) -> String? {
        let boxes = o.items.compactMap { item in discs.first(where: { $0.listingID == item.id })?.box }.filter { !$0.isEmpty }
        return boxes.isEmpty ? nil : Array(Set(boxes)).sorted().joined(separator: ", ")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let page = try await seller.client.orders()
            await OrderWatcher.notifyNew(page.orders)
            let before = Set(orders.map(\.id))
            if !orders.isEmpty, page.orders.contains(where: { !before.contains($0.id) && !OrderStyle.closed($0.status) }) {
                Suoni.nuovoOrdine()                      // è arrivato un ordine mentre guardi la pagina
            }
            withAnimation(.snappy) { orders = page.orders }
            error = nil
        } catch {
            // lettura interrotta (cambio scheda, nuovo aggiornamento): non è un errore da mostrare
            if error.isCancellation { return }
            self.error = error.localizedDescription
        }
    }
}

extension Error {
    /// Una richiesta annullata (cambi scheda mentre carica): niente avviso.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
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
                            UIPasteboard.general.string = address
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
            content.body = o.items.map { $0.release.description ?? "" }.joined(separator: ", ")
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: o.id, content: content, trigger: nil))
        }
        UserDefaults.standard.set(Array(seen), forKey: seenKey)
        UserDefaults.standard.set(true, forKey: "ordersInitialized")
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
