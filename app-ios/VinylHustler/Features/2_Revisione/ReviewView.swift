import SwiftData
import SwiftUI

/// 02 / REVISIONE — una scheda sola: BOZZE. Un solo tipo di bozza:
///   • i dischi fotografati ma non ancora su Discogs (non riconosciuti, da confermare, col prezzo pronto):
///     restano qui finché non li sistemi; un disco non riconosciuto non si può caricare su Discogs;
///   • le bozze vere su Discogs (anche quelle fatte fuori dall'app).
/// I dischi in vendita non stanno qui: stanno nel Magazzino.
struct ReviewView: View {
    @Environment(Seller.self) private var seller
    @Query(sort: \Disc.createdAt, order: .reverse) private var discs: [Disc]
    @State private var drafts: [Listing] = []          // le bozze su Discogs
    @State private var loading = false
    @State private var search = ""
    @State private var askPublish = false
    @State private var publishing = false
    @State private var toDelete: Listing?

    /// Dischi dell'app non ancora su Discogs.
    private var local: [Disc] {
        let states: [DiscStatus] = [.daConfermare, .daControllare, .bloccato, .pronto]
        let q = search.lowercased()
        return discs.filter { d in
            states.contains(d.status) && (q.isEmpty || "\(d.releaseTitle) \(d.lot) \(d.reason)".lowercased().contains(q))
        }
    }
    private var shownDrafts: [Listing] {
        let q = search.lowercased()
        return drafts.filter { q.isEmpty || ($0.release.description ?? "").lowercased().contains(q) }
    }
    private var ready: [Disc] { local.filter { $0.status == .pronto } }
    /// Quanti ne mette in vendita "Pubblica": i pronti dell'app più le bozze su Discogs.
    private var publishCount: Int { ready.count + shownDrafts.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(local) { disc in
                        DiscCard(disc: disc)
                    }
                    ForEach(shownDrafts) { l in
                        draftCard(l)
                    }
                    if local.isEmpty && shownDrafts.isEmpty && !loading {
                        VStack(spacing: 18) {
                            VinylMark(size: 110)
                            Text("Nessuna bozza").font(.system(size: 15)).foregroundStyle(Theme.muted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle("Bozze")
            .searchable(text: $search, prompt: "Titolo, artista, scatola…")
            .overlay { if loading && drafts.isEmpty { ProgressView("Leggo Discogs…").tint(Theme.accent) } }
            .refreshable { await Task { await loadDrafts() }.value }
            .task { await Task { await loadDrafts() }.value }
            .safeAreaInset(edge: .bottom) {
                if publishCount > 0 {
                    Button { askPublish = true } label: {
                        Text(publishing ? "Pubblico…" : "Pubblica \(publishCount)")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(SignalButtonStyle())
                    .disabled(publishing)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
            .confirmationDialog(publishCount == 1 ? "Mettere in vendita 1 disco su Discogs?" : "Mettere in vendita \(publishCount) dischi su Discogs?",
                                isPresented: $askPublish, titleVisibility: .visible) {
                Button("Pubblica \(publishCount)") { Task { await publishAll() } }
            } message: {
                Text("Vanno online subito. Quelli ancora da sistemare restano qui.")
            }
            .confirmationDialog("Eliminare questa bozza da Discogs?",
                                isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Elimina", role: .destructive) {
                    if let l = toDelete { Task { await delete(l) } }
                }
            }
        }
    }

    /// Una bozza su Discogs: copertina, titolo (tocco = apre su Discogs), Vendi, Elimina.
    private func draftCard(_ l: Listing) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Link(destination: URL(string: "https://www.discogs.com/sell/item/\(l.id)")!) {
                ListingRow(listing: l, disc: discs.first { $0.externalID == l.externalId },
                           selecting: false, isSelected: false, currency: seller.currency)
                    .foregroundStyle(Theme.text)
            }
            .buttonStyle(.plain)
            Button("Vendi") {
                Task {
                    do { try await seller.draftToSale(listingID: l.id); moved(l) }
                    catch { seller.lastError = error.localizedDescription }
                }
            }
            .buttonStyle(SignalButtonStyle())
            Button { toDelete = l } label: {
                Label("Elimina", systemImage: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.warn)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Theme.warnSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    /// La bozza è andata online: sparisce da qui, e il disco dell'app (se c'è) risulta in vendita.
    private func moved(_ l: Listing) {
        drafts.removeAll { $0.id == l.id }
        for d in discs where d.listingID == l.id { d.status = .inVendita }
    }

    private func publishAll() async {
        publishing = true
        defer { publishing = false }
        await seller.publishReady(ready)
        for l in shownDrafts {
            do { try await seller.draftToSale(listingID: l.id); moved(l) }
            catch { seller.lastError = error.localizedDescription }
        }
        Suoni.riconosciuto()
    }

    private func delete(_ l: Listing) async {
        do {
            try await seller.deleteListing(l.id, discs: discs)
            drafts.removeAll { $0.id == l.id }
        } catch { seller.lastError = error.localizedDescription }
    }

    private func loadDrafts() async {
        loading = true
        defer { loading = false }
        if let all = try? await seller.syncInventory(discs: discs) {
            drafts = all.filter { $0.status == "Draft" }
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
                ReleaseTitle(disc: disc, size: 22)
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
                DeleteDiscButton(disc: disc, wide: true)
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
