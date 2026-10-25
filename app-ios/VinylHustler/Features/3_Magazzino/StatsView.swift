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
    @State private var bars = false                     // le barre si riempiono quando i conti sono pronti
    @State private var contaT: Date?                     // V60 · p10: i valori contano e il grafico si disegna da qui

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if loading {
                        ProgressView("Leggo gli ordini…").tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        month
                        grafico
                        speed
                        bands
                        stale
                        Text("Calcolate sugli ultimi \(orders.count) ordini Discogs e sui \(forSale.count) annunci in vendita.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                .padding()
            }
            .sfondoHUD()
            .navigationTitle("Statistiche")
            .navigationBarTitleDisplayMode(.large)
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
        Suoni.schedaApre()                                // V60 · p10: carica…
        defer { loading = false }
        do {
            let first = try await seller.client.orders(page: 1)
            var all = first.orders
            if first.pagination.pages > 1, let second = try? await seller.client.orders(page: 2) { all += second.orders }
            withAnimation(.snappy) { orders = all }
            withAnimation(.timingCurve(0.2, 0.9, 0.3, 1, duration: 1.1).delay(0.25)) { bars = true }
            contaT = Date()
            // … è pronto quando il grafico ha finito di disegnarsi
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(GraficoVendite.fine * 1000)))
                Suoni.schedaPronta()
            }
        } catch {
            Suoni.errore()
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
                statConta(Double(items.count), "venduti") { String(Int($0.rounded())) }
                statConta(cashed, "incasso") { money($0) }
                if prices.isEmpty { stat("—", "prezzo medio") } else { statConta(avg, "prezzo medio") { money($0) } }
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
                    stat("\(days.count)", "misurati")
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
                                Capsule().fill(LinearGradient(colors: [Theme.military, Theme.accent], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: geo.size.width * (bars ? rate(s, o) : 0))
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
                statConta(Double(old.count), "annunci") { String(Int($0.rounded())) }
                statConta(value, "valore") { money($0) }
                stat(forSale.isEmpty ? "—" : "\(Int((Double(old.count) / Double(forSale.count) * 100).rounded()))%", "del magazzino")
            }
            if !old.isEmpty {
                Text("Prova ad abbassare un po' il prezzo: tasto verde nel Magazzino.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
    }

    /// V60 · p10: le vendite degli ultimi 30 giorni (dischi venduti al giorno, dagli ordini), il grafico si disegna da sinistra.
    private var grafico: some View {
        let cal = Calendar.current
        let oggi = cal.startOfDay(for: Date())
        var conti = [Int](repeating: 0, count: 30)
        for pair in soldItems {
            guard let d = Self.date(pair.order.created) else { continue }
            let giorni = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: oggi).day ?? 99
            if giorni >= 0 && giorni < 30 { conti[29 - giorni] += 1 }
        }
        let inizio = cal.date(byAdding: .day, value: -29, to: oggi) ?? oggi
        let meta = cal.date(byAdding: .day, value: -15, to: oggi) ?? oggi
        return card("VENDITE · ULTIMI 30 GIORNI") {
            GraficoVendite(conti: conti, da: contaT)
                .frame(height: 150)
            HStack {
                Text(Self.giorno(inizio))
                Spacer()
                Text(Self.giorno(meta))
                Spacer()
                Text(Self.giorno(oggi))
            }
            .font(Theme.mono(9)).foregroundStyle(Theme.muted)
        }
    }

    /// "26 SET"
    static func giorno(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMM"
        return f.string(from: d).uppercased().replacingOccurrences(of: ".", with: "")
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

    /// V60 · p10: un valore che conta da zero quando i conti sono pronti.
    private func statConta(_ valore: Double, _ label: String, _ formato: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            NumeroConta(valore: valore, da: contaT, durata: 1.2, formato: formato)
                .font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.glow)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// V60 · p10: il grafico delle vendite (griglia leggera, area, linea verde e punto finale) che si disegna da sinistra.
struct GraficoVendite: View {
    let conti: [Int]
    let da: Date?
    /// Secondi dopo `da` in cui il grafico è finito.
    static let fine = 1.5
    @State private var finito = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: finito || da == nil)) { ctx in
            let k = avanzamento(ctx.date)
            Canvas { gc, size in disegna(gc, size, k) }
        }
        .task(id: da) {
            finito = false
            guard let da else { return }
            let resta = GraficoVendite.fine + 0.05 - Date().timeIntervalSince(da)
            if resta > 0 { try? await Task.sleep(for: .milliseconds(Int(resta * 1000))) }
            if !Task.isCancelled { finito = true }
        }
        .accessibilityLabel("Grafico delle vendite degli ultimi 30 giorni: \(conti.reduce(0, +)) dischi venduti")
    }

    private func avanzamento(_ ora: Date) -> Double {
        guard let da else { return 1 }
        let passato = max(ora.timeIntervalSince(da), Date().timeIntervalSince(da))
        return min(1, max(0, (passato - 0.2) / 1.3))
    }

    private func disegna(_ gc: GraphicsContext, _ size: CGSize, _ k: Double) {
        let n = conti.count
        guard n > 1 else { return }
        let w = Double(size.width), h = Double(size.height)
        let massimo = Double(max((conti.max() ?? 0) + 1, 3))
        // griglia
        var griglia = Path()
        for q in [0.25, 0.5, 0.75] {
            griglia.move(to: CGPoint(x: 0, y: h * q))
            griglia.addLine(to: CGPoint(x: w, y: h * q))
        }
        gc.stroke(griglia, with: .color(Theme.glow.opacity(0.10)), lineWidth: 1)
        // i punti
        var punti: [CGPoint] = []
        for i in 0..<n {
            let x = Double(i) * w / Double(n - 1)
            let y = h - 8 - Double(conti[i]) / massimo * (h - 20)
            punti.append(CGPoint(x: x, y: y))
        }
        // fin dove è arrivato il disegno
        let fin = k * Double(n - 1)
        let pieni = Int(fin.rounded(.down))
        var linea = Path()
        linea.move(to: punti[0])
        if pieni >= 1 {
            for i in 1...min(pieni, n - 1) { linea.addLine(to: punti[i]) }
        }
        var ultimo = punti[min(pieni, n - 1)]
        if pieni < n - 1 {
            let a = punti[pieni], b = punti[pieni + 1]
            let f = fin - Double(pieni)
            ultimo = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
            linea.addLine(to: ultimo)
        }
        var area = linea
        area.addLine(to: CGPoint(x: ultimo.x, y: h))
        area.addLine(to: CGPoint(x: 0, y: h))
        area.closeSubpath()
        gc.fill(area, with: .color(Theme.glow.opacity(0.10)))
        gc.stroke(linea, with: .color(Theme.glow), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        let punto = Path(ellipseIn: CGRect(x: ultimo.x - 4, y: ultimo.y - 4, width: 8, height: 8))
        gc.fill(punto, with: .color(Theme.glow))
    }
}
