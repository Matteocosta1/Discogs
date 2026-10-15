import BackgroundTasks
import SwiftData
import SwiftUI
import UserNotifications

/// 04 / ORDINI — ordini da evadere, con la scatola da cui prelevare il disco.
/// Discogs non ha webhook: l'app controlla gli ordini ogni 3 minuti mentre è aperta,
/// e in sottofondo quando iOS lo permette (BGAppRefreshTask), con notifica "Nuovo ordine".
struct OrdersView: View {
    @Environment(Seller.self) private var seller
    @Query private var discs: [Disc]
    @State private var orders: [Order] = []
    @State private var error: String?
    private let timer = Timer.publish(every: 180, on: .main, in: .common).autoconnect()

    private var open: [Order] { orders.filter { order in !["Shipped", "Cancelled", "Merged"].contains { order.status.hasPrefix($0) } } }

    var body: some View {
        NavigationStack {
            List {
                Section("Da evadere · \(open.count)") {
                    ForEach(open) { order in orderRow(order) }
                }
                Section("Spediti e chiusi") {
                    ForEach(orders.filter { o in !open.contains(o) }) { order in orderRow(order) }
                }
            }
            .themedBackground()
            .navigationTitle("Ordini")
            .refreshable { await load() }
            .task { await load(); await OrderWatcher.requestPermission() }
            .onReceive(timer) { _ in Task { await load() } }
            .overlay { if let error { Text(error).foregroundStyle(Theme.warn).padding() } }
        }
    }

    private func orderRow(_ o: Order) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("#\(o.id)").font(.caption.monospaced())
                Spacer()
                Text(o.status.uppercased()).font(.caption2.monospaced()).foregroundStyle(Theme.accent)
            }
            ForEach(o.items, id: \.id) { item in
                Text(item.release.description ?? "Release \(item.release.id)").font(Theme.display(18, .bold))
                if let box = discs.first(where: { $0.listingID == item.id })?.box, !box.isEmpty {
                    Text("PRELEVA DA \(box)").font(Theme.mono(11, .bold)).foregroundStyle(Color.black)
                        .padding(.horizontal, 6).padding(.vertical, 3).background(Theme.accent)
                }
            }
            Text("Acquirente: \(o.buyer.username)").font(.caption)
            if let address = o.shippingAddress { Text(address).font(.caption).foregroundStyle(.secondary) }
            Link("Apri l'ordine su Discogs", destination: URL(string: "https://www.discogs.com/sell/order/\(o.id)")!).font(.caption)
        }
    }

    private func load() async {
        do {
            let page = try await seller.client.orders()
            await OrderWatcher.notifyNew(page.orders)
            orders = page.orders
            error = nil
        } catch { self.error = error.localizedDescription }
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
