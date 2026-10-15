import SwiftData
import SwiftUI

/// 02 / REVISIONE — tutti i dischi in due schede: Da decidere (sì / no, non riconosciuti, bloccati)
/// e In vendita (pronti, online, bozze). Gli stessi tasti della Sessione.
struct ReviewView: View {
    @Environment(Seller.self) private var seller
    @Query(sort: \Disc.createdAt, order: .reverse) private var discs: [Disc]
    @State private var tab = Tab.check
    @State private var search = ""
    @State private var lot = ""

    enum Tab: String, CaseIterable { case sale = "In vendita", check = "Da decidere" }

    private var lots: [String] { Array(Set(discs.map(\.lot))).sorted() }

    private func visible(_ tab: Tab) -> [Disc] {
        discs.filter { d in
            let saleStates: [DiscStatus] = [.pronto, .inVendita, .bozza]
            let checkStates: [DiscStatus] = [.daConfermare, .daControllare, .bloccato]
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
                                Text(tab == .sale ? "Nessun disco in vendita" : "Tutto in ordine")
                                    .font(.system(size: 15)).foregroundStyle(Theme.muted)
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
    @State private var zoom: ZoomImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pictures
                .overlay(alignment: .topLeading) { StatusTag(status: disc.status).padding(10) }
            VStack(alignment: .leading, spacing: 12) {
                Text(disc.releaseTitle.isEmpty ? "Nessun disco proposto" : disc.releaseTitle)
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                HStack(alignment: .lastTextBaseline) {
                    Text(disc.gradeText).font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.military, in: Capsule()).foregroundStyle(Theme.money)
                    Text(disc.lot).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Spacer()
                }
                if !disc.priceCalculation.isEmpty {
                    DisclosureGroup {
                        Text(disc.priceCalculation).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    } label: {
                        Text("Come è stato calcolato").font(.system(size: 14)).foregroundStyle(Theme.muted)
                    }
                }
                DiscActions(disc: disc)
                if disc.status == .bozza { draftToSale }
                links
            }
            .padding(14)
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .sheet(item: $zoom) { z in
            Image(uiImage: z.image).resizable().scaledToFit().padding()
        }
    }

    private var pictures: some View {
        let own = seller.photos(of: disc)
        let cover = disc.coverFile.flatMap { UIImage(contentsOfFile: AppFolders.covers.appendingPathComponent($0).path) }
        let main = cover ?? own.first
        return ZStack(alignment: .bottomTrailing) {
            if cover == nil, let url = disc.coverURL {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                    .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit).clipped()
            } else if let main {
                Image(uiImage: main).resizable().scaledToFill()
                    .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit).clipped()
                    .onTapGesture { zoom = ZoomImage(image: main) }
            } else {
                Rectangle().fill(.quaternary).aspectRatio(1, contentMode: .fit)
            }
            HStack(spacing: 4) {
                ForEach(Array((cover == nil && disc.coverURL == nil ? Array(own.dropFirst()) : []).enumerated()), id: \.offset) { _, img in
                    Image(uiImage: img).resizable().scaledToFill().frame(width: 44, height: 44).clipped()
                        .border(.background, width: 2).onTapGesture { zoom = ZoomImage(image: img) }
                }
            }
            .padding(6)
        }
    }

    /// Una bozza su Discogs: un tocco e torna in vendita.
    private var draftToSale: some View {
        Button("Metti in vendita") {
            Task {
                guard let lid = disc.listingID else { return }
                do { try await seller.draftToSale(listingID: lid); disc.status = .inVendita }
                catch { seller.lastError = error.localizedDescription }
            }
        }
        .buttonStyle(SignalButtonStyle())
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
        .font(.system(size: 14))
        .tint(Theme.accent)
    }
}

struct ZoomImage: Identifiable {
    let id = UUID()
    let image: UIImage
}
