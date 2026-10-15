import SwiftData
import SwiftUI

/// 03 / MAGAZZINO — l'inventario vero su Discogs, nello stesso ordine della pagina Discogs (dal più recente).
/// Verifica su Discogs, Cancella bozze, posizione fisica di ogni disco (scatola).
struct WarehouseView: View {
    @Environment(Seller.self) private var seller
    @Query private var discs: [Disc]
    @State private var listings: [Listing] = []
    @State private var search = ""
    @State private var loading = false
    @State private var confirmDelete = false
    @State private var message: String?

    private var shown: [Listing] {
        let q = search.lowercased()
        return q.isEmpty ? listings : listings.filter { ($0.release.description ?? "").lowercased().contains(q) }
    }

    private func disc(for l: Listing) -> Disc? { discs.first { $0.externalID == l.externalId } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        stat("\(listings.filter { $0.status == "For Sale" }.count)", "in vendita")
                        stat("\(listings.filter { $0.status == "Draft" }.count)", "bozze")
                        stat(total, "valore")
                    }
                }
                Section {
                    ForEach(shown) { l in row(l) }
                }
            }
            .themedBackground()
            .navigationTitle("Magazzino")
            .searchable(text: $search, prompt: "Cerca nel magazzino")
            .refreshable { await sync() }
            .overlay { if loading { ProgressView("Leggo Discogs…") } }
            .toolbar {
                Menu {
                    Button("Verifica su Discogs", systemImage: "arrow.triangle.2.circlepath") { Task { await sync() } }
                    Button("Cancella tutte le bozze", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    Link("Apri l'inventario su Discogs", destination: URL(string: "https://www.discogs.com/sell/manage")!)
                } label: { Image(systemName: "ellipsis.circle") }
            }
            .confirmationDialog("Cancellare DEFINITIVAMENTE tutte le bozze su Discogs? Gli annunci In vendita restano.",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Cancella le bozze", role: .destructive) {
                    Task {
                        loading = true
                        do {
                            let n = try await seller.deleteAllDrafts()
                            message = "Bozze cancellate: \(n)"
                        } catch { message = error.localizedDescription }
                        await sync()
                    }
                }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {}
            .task { if listings.isEmpty { await sync() } }
        }
    }

    private var total: String {
        let sum = listings.filter { $0.status == "For Sale" }.compactMap { $0.price?.value }.reduce(0, +)
        return sum.formatted(.currency(code: seller.currency).precision(.fractionLength(0)))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(Theme.display(34)).foregroundStyle(Theme.text)
            Text(label.uppercased()).font(Theme.mono(10, .semibold)).tracking(1.2).foregroundStyle(Theme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ l: Listing) -> some View {
        HStack(spacing: 12) {
            let local = disc(for: l)?.coverFile.flatMap { UIImage(contentsOfFile: AppFolders.covers.appendingPathComponent($0).path) }
            Group {
                if let local { Image(uiImage: local).resizable().scaledToFill() }
                else { AsyncImage(url: l.release.thumbnail.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) } }
            }
            .frame(width: 56, height: 56).clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(l.release.description ?? "Release \(l.release.id)").font(Theme.display(17, .bold)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(l.status == "Draft" ? "BOZZA" : "ONLINE").font(.caption2.monospaced())
                        .foregroundStyle(l.status == "Draft" ? Theme.warn : Theme.accent).bold()
                    if let d = disc(for: l) { BoxField(disc: d) }
                }
            }
            Spacer()
            if let p = l.price?.value {
                Text(p, format: .currency(code: l.price?.currency ?? seller.currency)).font(Theme.mono(14, .bold))
            }
        }
        .contextMenu {
            Link("Apri l'annuncio", destination: URL(string: "https://www.discogs.com/sell/item/\(l.id)")!)
            if l.status == "Draft" {
                Button("Conferma: metti in vendita") { Task { try? await seller.draftToSale(listingID: l.id); await sync() } }
            }
        }
    }

    private func sync() async {
        loading = true
        defer { loading = false }
        do { listings = try await seller.syncInventory(discs: discs) } catch { message = error.localizedDescription }
    }
}

/// Posizione fisica del disco (scatola / numero), modificabile al volo.
private struct BoxField: View {
    @Bindable var disc: Disc
    var body: some View {
        TextField("scatola", text: $disc.box).font(.caption2.monospaced()).frame(width: 80)
    }
}
