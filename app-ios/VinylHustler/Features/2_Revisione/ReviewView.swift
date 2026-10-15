import SwiftData
import SwiftUI

/// 02 / REVISIONE — il pannello dello script: due schede, In vendita e Da controllare.
/// Su ogni disco da controllare: Conferma (un click = in vendita), È questo, Altra release, Togli.
struct ReviewView: View {
    @Environment(Seller.self) private var seller
    @Query(sort: \Disc.createdAt, order: .reverse) private var discs: [Disc]
    @State private var tab = Tab.check
    @State private var search = ""
    @State private var lot = ""

    enum Tab: String, CaseIterable { case sale = "In vendita", check = "Da controllare" }

    private var lots: [String] { Array(Set(discs.map(\.lot))).sorted() }

    private func visible(_ tab: Tab) -> [Disc] {
        discs.filter { d in
            let saleStates: [DiscStatus] = [.pronto, .inVendita, .bozza]
            let checkStates: [DiscStatus] = [.daControllare, .bloccato]
            let inTab = tab == .sale ? saleStates.contains(d.status) : checkStates.contains(d.status)
            let inLot = lot.isEmpty || d.lot == lot
            let q = search.lowercased()
            let match = q.isEmpty || "\(d.releaseTitle) \(d.lot) \(d.reason)".lowercased().contains(q)
            return inTab && inLot && match
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { t in Text("\(t.rawValue) \(visible(t).count)").tag(t) }
                }
                .pickerStyle(.segmented).padding()
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if tab == .sale, visible(.sale).contains(where: { $0.status == .pronto }) {
                            Button {
                                Task { await seller.publishReady(visible(.sale)) }
                            } label: {
                                Text("Pubblica pronti · \(visible(.sale).filter { $0.status == .pronto }.count)")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(SignalButtonStyle())
                        }
                        ForEach(visible(tab)) { disc in
                            DiscCard(disc: disc)
                        }
                        if visible(tab).isEmpty {
                            VStack(spacing: 18) {
                                VinylMark(size: 110)
                                Text(tab == .sale ? "NESSUN DISCO IN VENDITA" : "TUTTO IN ORDINE")
                                    .font(Theme.mono(12, .semibold)).tracking(1.5).foregroundStyle(Theme.muted)
                            }
                            .padding(.top, 60)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .background(Theme.bg)
            .navigationTitle("Revisione")
            .searchable(text: $search, prompt: "Titolo, artista, scatola…")
            .toolbar {
                Menu {
                    Picker("Dove", selection: $lot) {
                        Text("Ovunque").tag("")
                        ForEach(lots, id: \.self) { Text($0).tag($0) }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            }
        }
    }
}

/// La scheda di un disco: copertina Discogs in grande (pulita), le foto del disco in miniatura.
struct DiscCard: View {
    @Environment(Seller.self) private var seller
    @Bindable var disc: Disc
    @State private var busy = false
    @State private var askRelease = false
    @State private var releaseText = ""
    @State private var zoom: ZoomImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pictures
                .overlay(alignment: .topLeading) { StatusTag(status: disc.status).padding(10) }
            VStack(alignment: .leading, spacing: 12) {
                if disc.status == .daControllare || disc.status == .bloccato {
                    Text(disc.reason).font(Theme.mono(12, .semibold)).foregroundStyle(Theme.warn)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.warn).frame(width: 3) }
                }
                Text(disc.releaseTitle.isEmpty ? "Nessun disco proposto" : disc.releaseTitle)
                    .font(Theme.display(24, .heavy)).foregroundStyle(Theme.text)
                HStack(alignment: .lastTextBaseline) {
                    Text(disc.gradeText.uppercased()).font(Theme.mono(10, .bold)).tracking(1)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(Theme.military).foregroundStyle(Theme.text)
                    Text(disc.lot.uppercased()).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                    Spacer()
                    if let p = disc.price {
                        Text(p, format: .currency(code: seller.currency))
                            .font(Theme.display(30)).foregroundStyle(Theme.accent)
                    }
                }
                if !disc.priceCalculation.isEmpty {
                    DisclosureGroup {
                        Text(disc.priceCalculation).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    } label: {
                        Text("COME È STATO CALCOLATO").font(Theme.mono(11, .semibold)).foregroundStyle(Theme.muted)
                    }
                }
                if disc.status == .daControllare { candidates }
                actions
                links
            }
            .padding(14)
        }
        .background(Theme.panel)
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
        .disabled(busy)
        .overlay { if busy { ProgressView() } }
        .alert("Numero della release Discogs", isPresented: $askRelease) {
            TextField("discogs.com/release/NUMERO", text: $releaseText).keyboardType(.numberPad)
            Button("Conferma") {
                if let id = Int(releaseText.filter(\.isNumber)) { run { await seller.assign(disc, releaseID: id) } }
            }
            Button("Annulla", role: .cancel) {}
        }
        .sheet(item: $zoom) { z in
            Image(uiImage: z.image).resizable().scaledToFit().padding()
        }
    }

    private var pictures: some View {
        let own = seller.photos(of: disc)
        let cover = disc.coverFile.flatMap { UIImage(contentsOfFile: AppFolders.covers.appendingPathComponent($0).path) }
        let main = cover ?? own.first
        return ZStack(alignment: .bottomTrailing) {
            if let main {
                Image(uiImage: main).resizable().scaledToFill()
                    .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit).clipped()
                    .onTapGesture { zoom = ZoomImage(image: main) }
            } else {
                Rectangle().fill(.quaternary).aspectRatio(1, contentMode: .fit)
            }
            HStack(spacing: 4) {
                ForEach(Array((cover == nil ? Array(own.dropFirst()) : []).enumerated()), id: \.offset) { _, img in
                    Image(uiImage: img).resizable().scaledToFill().frame(width: 44, height: 44).clipped()
                        .border(.background, width: 2).onTapGesture { zoom = ZoomImage(image: img) }
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder private var candidates: some View {
        let others = disc.candidates.filter { $0.id != disc.releaseID }
        if !others.isEmpty {
            DisclosureGroup("ALTRE RELEASE POSSIBILI · \(others.count)") {
                ForEach(others) { c in
                    HStack {
                        AsyncImage(url: c.coverURL.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                            .frame(width: 44, height: 44).clipped()
                        Text(c.title).font(Theme.mono(11)).foregroundStyle(Theme.text).lineLimit(2)
                        Spacer()
                        Link("vedi", destination: URL(string: "https://www.discogs.com/release/\(c.id)")!).font(.caption)
                        Button("È questo") { run { await seller.choose(disc, candidate: c) } }
                            .buttonStyle(SignalButtonStyle(filled: false)).frame(width: 100)
                    }
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack {
            switch disc.status {
            case .daControllare:
                if disc.releaseID != nil {
                    Button("Conferma") { run { await seller.confirm(disc) } }.buttonStyle(SignalButtonStyle())
                }
                Button("Altra release") { askRelease = true }.buttonStyle(SignalButtonStyle(filled: false))
                Button("Togli", role: .destructive) { run { await seller.remove(disc) } }.buttonStyle(SignalButtonStyle(filled: false))
            case .pronto:
                Button("Pubblica") { run { await seller.publish(disc) } }.buttonStyle(SignalButtonStyle())
                Button("Togli", role: .destructive) { run { await seller.remove(disc) } }.buttonStyle(SignalButtonStyle(filled: false))
            case .bozza:
                Button("Conferma") {
                    run {
                        if let lid = disc.listingID {
                            do { try await seller.draftToSale(listingID: lid); disc.status = .inVendita }
                            catch { seller.lastError = error.localizedDescription }
                        }
                    }
                }.buttonStyle(SignalButtonStyle())
            case .inVendita:
                Button("Togli da Discogs", role: .destructive) { run { await seller.remove(disc) } }.buttonStyle(SignalButtonStyle(filled: false))
            default:
                EmptyView()
            }
        }
    }

    private var links: some View {
        HStack(spacing: 16) {
            if let rid = disc.releaseID {
                Link("Release su Discogs", destination: URL(string: "https://www.discogs.com/release/\(rid)")!)
            }
            if let lid = disc.listingID {
                Link("Annuncio", destination: URL(string: "https://www.discogs.com/sell/item/\(lid)")!)
            }
        }
        .font(Theme.mono(11, .semibold))
        .tint(Theme.muted)
    }

    private func run(_ job: @escaping () async -> Void) {
        busy = true
        Task { await job(); busy = false }
    }
}

struct ZoomImage: Identifiable {
    let id = UUID()
    let image: UIImage
}
