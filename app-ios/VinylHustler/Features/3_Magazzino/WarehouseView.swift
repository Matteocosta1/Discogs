import SwiftData
import SwiftUI

/// 03 / MAGAZZINO — l'inventario vero su Discogs, nello stesso ordine della pagina Discogs (dal più recente).
/// Filtro Tutti / Online / Bozze, posizione fisica di ogni disco, bozze da eliminare una per una
/// (scorri a sinistra) o selezionandone tante insieme (Seleziona).
struct WarehouseView: View {
    @Environment(Seller.self) private var seller
    @Query private var discs: [Disc]
    @State private var listings: [Listing] = []
    @State private var search = ""
    @State private var filter = Filter.all
    @State private var loading = false
    @State private var confirmDeleteAll = false
    @State private var selecting = false
    @State private var selected: Set<Int> = []
    @State private var toDelete: [Int] = []          // bozze in attesa di conferma
    @State private var message: String?

    enum Filter: String, CaseIterable { case all = "Tutti", online = "Online", drafts = "Bozze" }

    private var shown: [Listing] {
        let q = search.lowercased()
        return listings.filter { l in
            let inFilter = filter == .all || (filter == .online ? l.status == "For Sale" : l.status == "Draft")
            return inFilter && (q.isEmpty || (l.release.description ?? "").lowercased().contains(q))
        }
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
                    Picker("Mostra", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    ForEach(shown) { l in row(l) }
                } footer: {
                    if !selecting && listings.contains(where: { $0.status == "Draft" }) {
                        Text("Per eliminare una bozza scorrila verso sinistra, oppure tocca Seleziona e scegline tante.")
                    }
                }
            }
            .themedBackground()
            .navigationTitle("Magazzino")
            .searchable(text: $search, prompt: "Cerca nel magazzino")
            .refreshable { await sync() }
            .overlay { if loading { ProgressView("Leggo Discogs…").tint(Theme.accent) } }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selecting ? "Fine" : "Seleziona") {
                        selecting.toggle()
                        selected = []
                        if selecting { filter = .drafts }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Verifica su Discogs", systemImage: "arrow.triangle.2.circlepath") { Task { await sync() } }
                        Button("Cancella tutte le bozze", systemImage: "trash", role: .destructive) { confirmDeleteAll = true }
                        Link("Apri l'inventario su Discogs", destination: URL(string: "https://www.discogs.com/sell/manage")!)
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting && !selected.isEmpty {
                    Button(role: .destructive) { toDelete = Array(selected) } label: {
                        Label("Elimina \(selected.count) \(selected.count == 1 ? "bozza" : "bozze")", systemImage: "trash")
                    }
                    .buttonStyle(SignalButtonStyle())
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: selected.isEmpty)
            .confirmationDialog(toDelete.count == 1 ? "Eliminare questa bozza da Discogs?" : "Eliminare \(toDelete.count) bozze da Discogs?",
                                isPresented: Binding(get: { !toDelete.isEmpty }, set: { if !$0 { toDelete = [] } }),
                                titleVisibility: .visible) {
                Button("Elimina", role: .destructive) {
                    let ids = toDelete
                    Task { await deleteDrafts(ids) }
                }
            } message: {
                Text("Gli annunci online non si toccano.")
            }
            .confirmationDialog("Cancellare DEFINITIVAMENTE tutte le bozze su Discogs? Gli annunci In vendita restano.",
                                isPresented: $confirmDeleteAll, titleVisibility: .visible) {
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
            Text(value).font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.glow)
                .contentTransition(.numericText())
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func row(_ l: Listing) -> some View {
        let draft = l.status == "Draft"
        let isSelected = selected.contains(l.id)
        HStack(spacing: 12) {
            if selecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(draft ? (isSelected ? Theme.accent : Theme.muted) : Theme.muted.opacity(0.3))
            }
            let local = disc(for: l)?.coverFile.flatMap { UIImage(contentsOfFile: AppFolders.covers.appendingPathComponent($0).path) }
            Group {
                if let local { Image(uiImage: local).resizable().scaledToFill() }
                else { AsyncImage(url: l.release.thumbnail.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh } }
            }
            .frame(width: 52, height: 52)
            .clipShape(Circle())
            .overlay(Circle().stroke(Theme.accent.opacity(0.8), lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 4) {
                Text(l.release.description ?? "Release \(l.release.id)").font(.system(size: 16, weight: .semibold)).lineLimit(2)
                HStack(spacing: 8) {
                    Text(draft ? "Bozza" : "Online")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .foregroundStyle(draft ? Theme.warn : Theme.money)
                        .background(draft ? Theme.warnSoft : Theme.military, in: Capsule())
                    if let d = disc(for: l) { BoxField(disc: d) }
                }
            }
            Spacer()
            if let p = l.price?.value {
                Text(p, format: .currency(code: l.price?.currency ?? seller.currency)).font(.system(size: 15, weight: .semibold))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard selecting, draft else { return }
            if isSelected { selected.remove(l.id) } else { selected.insert(l.id) }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        .swipeActions(edge: .trailing) {
            if draft && !selecting {
                Button("Elimina", systemImage: "trash", role: .destructive) { toDelete = [l.id] }
            }
        }
        .contextMenu {
            Link("Apri l'annuncio", destination: URL(string: "https://www.discogs.com/sell/item/\(l.id)")!)
            if draft {
                Button("Metti in vendita", systemImage: "arrow.up.circle") {
                    Task { try? await seller.draftToSale(listingID: l.id); await sync() }
                }
                Button("Elimina la bozza", systemImage: "trash", role: .destructive) { toDelete = [l.id] }
            }
        }
    }

    private func deleteDrafts(_ ids: [Int]) async {
        loading = true
        var done = 0
        var failed: [String] = []
        for id in ids {
            do {
                try await seller.deleteDraft(id, discs: discs)
                done += 1
                listings.removeAll { $0.id == id }
            } catch { failed.append(error.localizedDescription) }
        }
        loading = false
        selected = []
        selecting = false
        toDelete = []
        Suoni.riconosciuto()
        message = failed.isEmpty ? (done == 1 ? "Bozza eliminata" : "Bozze eliminate: \(done)")
                                 : "Eliminate \(done), non riuscite \(failed.count): \(failed.first ?? "")"
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
        TextField("posto", text: $disc.box).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 90)
    }
}
