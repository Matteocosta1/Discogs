import SwiftData
import SwiftUI

/// 03 / BOZZE — il deposito: le bozze su Discogs (quelle salvate con "Bozza" dall'app e quelle fatte fuori).
/// Vendi, Elimina, tocco = apre su Discogs; "Pubblica N" le mette tutte online.
/// In cima i dischi fotografati ancora da sistemare (non riconosciuti o non ancora caricati): restano qui
/// finché non li sistemi. Quelli in vendita stanno nel Magazzino.
struct DraftsView: View {
    @Environment(Seller.self) private var seller
    @Query(sort: \Disc.createdAt, order: .reverse) private var discs: [Disc]
    @State private var drafts: [Listing] = []          // le bozze su Discogs
    @State private var loading = false
    @State private var search = ""
    @State private var askPublish = false
    @State private var publishing = false
    @State private var toDelete: Listing?

    private var shownDrafts: [Listing] {
        let q = search.lowercased()
        return drafts.filter { q.isEmpty || ($0.release.description ?? "").lowercased().contains(q) }
    }
    /// Dischi dell'app non ancora su Discogs (da sistemare, o col prezzo ma non caricati).
    private var local: [Disc] {
        let states: [DiscStatus] = [.daConfermare, .daControllare, .bloccato, .pronto]
        let q = search.lowercased()
        return discs.filter { d in
            states.contains(d.status) && (q.isEmpty || "\(d.releaseTitle) \(d.lot) \(d.reason)".lowercased().contains(q))
        }
    }
    private var ready: [Disc] { local.filter { $0.status == .pronto } }
    private var publishCount: Int { ready.count + shownDrafts.count }

    var body: some View {
        Group {
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
                Text("Vanno online subito su Discogs.")
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

