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
    /// Preso / Imballato / Spedito, segnati nell'app (sul telefono): 0 = niente, 3 = spedito.
    @State private var checkedAt: Date?
    @State private var steps: [String: Int] = (UserDefaults.standard.dictionary(forKey: "orderSteps") as? [String: Int]) ?? [:]

    private func step(_ o: Order) -> Int { steps[o.id] ?? 0 }
    private var open: [Order] { orders.filter { !OrderStyle.closed($0.status) && step($0) < 3 } }
    private var closed: [Order] { orders.filter { OrderStyle.closed($0.status) || step($0) >= 3 } }

    private func setStep(_ o: Order, _ v: Int) {
        steps[o.id] = v
        UserDefaults.standard.set(steps, forKey: "orderSteps")
    }
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

                    if open.isEmpty && !loading {
                        // niente ordini da spedire: una riga sola, con l'ora dell'ultimo controllo
                        HStack(spacing: 10) {
                            MiniRadar()                       // piccolo: dice solo "sto controllando"
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
                        VStack(alignment: .leading, spacing: 10) {
                            Text("DA EVADERE").font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.leading, 16)
                            ForEach(open) { o in
                                OpenOrderCard(order: o, box: box(for: o), step: step(o), currency: seller.currency,
                                              onOpen: { Suoni.tocco(); detail = o },
                                              onStep: { v in withAnimation(.spring(duration: 0.4)) { setStep(o, v) } })
                                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                            removal: .move(edge: .trailing).combined(with: .opacity)))
                            }
                        }
                    }
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
        // spedito nell'app (Preso → Imballato → Spedito) ma su Discogs ancora da spedire
        let style = OrderStyle(step(o) >= 3 && !OrderStyle.closed(o.status) ? "Shipped" : o.status)
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
            checkedAt = Date()
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

/// Un radar piccolo (come un'icona): il fascio gira piano, l'app sta controllando gli ordini.
struct MiniRadar: View {
    @State private var giro = false

    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.04, green: 0.07, blue: 0.05))
            Circle().stroke(Theme.accent.opacity(0.35), lineWidth: 1)
            Circle().stroke(Theme.accent.opacity(0.2), lineWidth: 1).padding(8)
            Circle()
                .fill(AngularGradient(colors: [Theme.glow.opacity(0.6), Theme.glow.opacity(0), .clear, .clear], center: .center))
                .rotationEffect(.degrees(giro ? 360 : 0))
                .animation(.linear(duration: 3.2).repeatForever(autoreverses: false), value: giro)
            Circle().fill(Theme.glow).frame(width: 4, height: 4).shadow(color: Theme.glow, radius: 3).offset(x: 6, y: -6)
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
        .onAppear { giro = true }
        .accessibilityHidden(true)
    }
}

/// Un ordine da evadere: NUOVO che lampeggia, bordo che respira, "Preleva da …" in grande,
/// e i tre passi Preso → Imballato → Spedito. Su Spedito parte il furgoncino.
struct OpenOrderCard: View {
    let order: Order
    let box: String?
    let step: Int
    let currency: String
    let onOpen: () -> Void
    let onStep: (Int) -> Void

    @State private var respiro = false
    @State private var furgone = false

    private let labels = ["Preso", "Imballato", "Spedito"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    AsyncImage(url: order.items.first?.release.thumbnail.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                        .frame(width: 52, height: 52).clipShape(Circle())
                        .overlay(Circle().stroke(Theme.accent, lineWidth: 1.5))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("NUOVO").font(Theme.mono(10, .heavy)).tracking(1.5)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .foregroundStyle(Color.black).background(Theme.glow, in: Capsule())
                                .opacity(respiro ? 1 : 0.45)
                            Text("\(OrderStyle.date(order.created)) · \(order.buyer.username)")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Text(order.items.first?.release.description ?? "Ordine \(order.id)")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        if order.items.count > 1 {
                            Text("+ altri \(order.items.count - 1) dischi").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer(minLength: 4)
                    if let t = order.total {
                        Text(t.value, format: .currency(code: t.currency ?? currency))
                            .font(.system(size: 15, weight: .bold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .foregroundStyle(Theme.money).background(Theme.military, in: Capsule())
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

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.panelHigh)
                    Capsule().fill(Theme.accent).shadow(color: Theme.glow, radius: 4)
                        .frame(width: g.size.width * CGFloat(min(step, 3)) / 3)
                }
            }
            .frame(height: 4)
            .animation(.spring(duration: 0.45), value: step)

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { k in
                    let done = step > k
                    let next = step == k
                    Button {
                        guard next else { Suoni.click(); return }
                        if k < 2 {
                            Suoni.seleziona()
                            onStep(k + 1)
                        } else {
                            Suoni.carica()
                            withAnimation(.easeIn(duration: 1.0)) { furgone = true }
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(1000))
                                Suoni.online()
                                onStep(3)
                            }
                        }
                    } label: {
                        Text((done ? "✓ " : "") + labels[k])
                            .font(.system(size: 13, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(done ? Theme.money : (next ? Color.black : Theme.muted))
                            .background(done ? Theme.military : (next ? Theme.accent : Theme.panelHigh),
                                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            // il furgoncino che attraversa la scheda quando si spedisce
            Image(systemName: "box.truck.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.glow)
                .shadow(color: Theme.glow, radius: 6)
                .offset(x: furgone ? 420 : -40, y: -6)
                .opacity(furgone ? 1 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .stroke(Theme.glow.opacity(respiro ? 0.9 : 0.4), lineWidth: 1)
        )
        .shadow(color: Theme.glow.opacity(respiro ? 0.45 : 0.15), radius: respiro ? 14 : 6)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { respiro = true }
        }
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
