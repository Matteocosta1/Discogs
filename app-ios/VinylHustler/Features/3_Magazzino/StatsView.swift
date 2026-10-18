import SwiftData
import SwiftUI

/// STATISTICHE (Magazzino › grafico in alto): come stanno andando le vendite e quali prezzi funzionano.
/// Dati: gli ordini Discogs (gli ultimi 100) e gli annunci in vendita. Due-tre richieste a Discogs, solo quando la apri.
struct StatsView: View {
    let listings: [Listing]                 // l'inventario già letto dal Magazzino

    @Environment(Seller.self) private var seller
    @Environment(\.dismiss) private var dismiss
    @Query private var discs: [Disc]
    @State private var orders: [Order] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if loading {
                        ProgressView("Leggo gli ordini…").tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        month
                        speed
                        bands
                        stale
                        Text("Calcolate sugli ultimi \(orders.count) ordini Discogs e sui \(forSale.count) annunci in vendita.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle("Statistiche")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fatto") { dismiss() } } }
            .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {}
            .task { await load() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Dati

    private var forSale: [Listing] { listings.filter { $0.status == "For Sale" } }
    private var sold: [Order] { orders.filter { !$0.status.hasPrefix("Cancelled") } }
    private var soldItems: [(order: Order, item: OrderItem)] { sold.flatMap { o in o.items.map { (o, $0) } } }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let first = try await seller.client.orders(page: 1)
            var all = first.orders
            if first.pagination.pages > 1, let second = try? await seller.client.orders(page: 2) { all += second.orders }
            withAnimation(.snappy) { orders = all }
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)
    }

    private func money(_ v: Double) -> String {
        WarehouseView.italian(v) + (seller.currency == "EUR" ? " €" : " \(seller.currency)")
    }

    // MARK: - Pezzi

    /// Questo mese: venduti, incasso, prezzo medio.
    private var month: some View {
        let cal = Calendar.current
        let now = Date()
        let items = soldItems.filter { pair in
            Self.date(pair.order.created).map { cal.isDate($0, equalTo: now, toGranularity: .month) } ?? false
        }
        let orderIDs = Set(items.map(\.order.id))
        let cashed = sold.filter { orderIDs.contains($0.id) }.compactMap { $0.total?.value }.reduce(0, +)
        let prices = items.compactMap { $0.item.price?.value }
        let avg = prices.isEmpty ? 0 : prices.reduce(0, +) / Double(prices.count)
        return card("QUESTO MESE") {
            HStack {
                stat("\(items.count)", "venduti")
                stat(money(cashed), "incasso")
                stat(prices.isEmpty ? "—" : money(avg), "prezzo medio")
            }
        }
    }

    /// Quanto ci mette un disco a vendersi: dalla foto all'ordine.
    private var speed: some View {
        let days: [Double] = soldItems.compactMap { pair in
            guard let d = discs.first(where: { $0.listingID == pair.item.id }),
                  let when = Self.date(pair.order.created) else { return nil }
            return max(0, when.timeIntervalSince(d.createdAt) / 86_400)
        }.sorted()
        let avg = days.isEmpty ? 0 : days.reduce(0, +) / Double(days.count)
        let median = days.isEmpty ? 0 : days[days.count / 2]
        return card("TEMPO PER VENDERE") {
            if days.isEmpty {
                Text("Ancora nessun disco fotografato con l'app è stato venduto.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
            } else {
                HStack {
                    stat(String(format: "%.0f gg", avg), "in media")
                    stat(String(format: "%.0f gg", median), "di solito")
                    stat("\(days.count)", "dischi misurati")
                }
            }
        }
    }

    /// Fasce di prezzo: quanti venduti e quanti ancora online. La barra = quanti si vendono su quanti ne metti.
    private var bands: some View {
        let limits: [(String, Double, Double)] = [("fino a 10 €", 0, 10), ("10–20 €", 10, 20), ("20–35 €", 20, 35),
                                                  ("35–60 €", 35, 60), ("oltre 60 €", 60, .infinity)]
        let soldPrices = soldItems.compactMap { $0.item.price?.value }
        let onlinePrices = forSale.compactMap { $0.price?.value }
        let rows: [(String, Int, Int)] = limits.map { band in
            let s = soldPrices.filter { $0 >= band.1 && $0 < band.2 }.count
            let o = onlinePrices.filter { $0 >= band.1 && $0 < band.2 }.count
            return (band.0, s, o)
        }
        let best = rows.max { rate($0.1, $0.2) < rate($1.1, $1.2) }?.0
        return card("QUALI PREZZI FUNZIONANO") {
            VStack(spacing: 12) {
                ForEach(rows, id: \.0) { row in
                    let label = row.0
                    let s = row.1
                    let o = row.2
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(label).font(.system(size: 14, weight: .semibold))
                            if label == best && s > 0 {
                                Text("FUNZIONA").font(Theme.mono(10, .bold)).tracking(1)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .foregroundStyle(Color.black).background(Theme.glow, in: Capsule())
                            }
                            Spacer()
                            Text("\(s) venduti · \(o) online").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.panelHigh)
                                Capsule().fill(Theme.accent)
                                    .frame(width: geo.size.width * rate(s, o))
                                    .shadow(color: Theme.glow.opacity(0.5), radius: 4)
                            }
                        }
                        .frame(height: 8)
                    }
                }
            }
        }
    }

    private func rate(_ sold: Int, _ online: Int) -> Double {
        sold + online == 0 ? 0 : Double(sold) / Double(sold + online)
    }

    /// Annunci fermi da più di 60 giorni: forse il prezzo è alto.
    private var stale: some View {
        let limit = Date().addingTimeInterval(-60 * 86_400)
        let old = forSale.filter { (Self.date($0.posted) ?? Date()) < limit }
        let value = old.compactMap { $0.price?.value }.reduce(0, +)
        return card("FERMI DA PIÙ DI 60 GIORNI") {
            HStack {
                stat("\(old.count)", "annunci")
                stat(money(value), "valore")
                stat(forSale.isEmpty ? "—" : "\(Int((Double(old.count) / Double(forSale.count) * 100).rounded()))%", "del magazzino")
            }
            if !old.isEmpty {
                Text("Prova ad abbassare un po' il prezzo: dalla scheda annuncio, tasto verde nel Magazzino.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.accent)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.glow)
                .lineLimit(1).minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
