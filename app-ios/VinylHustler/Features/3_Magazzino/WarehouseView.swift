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
    @AppStorage("selectedTab") private var selectedTab = 0
    @AppStorage("reviewPane") private var reviewPane = "Revisione"
    @State private var loading = false
    @State private var confirmDeleteAll = false
    @State private var selecting = false
    @State private var selected: Set<Int> = []
    @State private var toDelete: [Int] = []          // bozze in attesa di conferma
    @State private var message: String?
    @State private var askPlace = false
    @State private var newPlace = "Scatola 1"
    @State private var editing: Listing?                // scheda annuncio aperta
    /// Annunci (online e bozze) senza posizione.
    private var noPlaceCount: Int {
        listings.filter { ($0.location ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.count
    }
    @Environment(\.openURL) private var openURL

    private var shown: [Listing] {
        let q = search.lowercased()
        return listings.filter { l in
            return l.status == "For Sale" && (q.isEmpty || (l.release.description ?? "").lowercased().contains(q))
        }
    }

    private func disc(for l: Listing) -> Disc? { discs.first { $0.externalID == l.externalId } }

    // Il corpo è diviso in pezzi piccoli: tutto insieme era troppo per il compilatore di Swift.
    var body: some View {
        NavigationStack {
            dialogs(chrome(list))
        }
    }

    private var forSaleCount: Int { listings.filter { $0.status == "For Sale" }.count }
    /// Le stesse della pagina Bozze: le bozze su Discogs.
    private var draftCount: Int { listings.filter { $0.status == "Draft" }.count }
    /// Quanti dei dischi da eliminare sono in vendita (non bozze): per loro la conferma è più netta.
    private var onlineToDelete: Int {
        listings.filter { toDelete.contains($0.id) && $0.status == "For Sale" }.count
    }
    private var deleteTitle: String {
        toDelete.count == 1 ? "Eliminare questo disco da Discogs?" : "Eliminare \(toDelete.count) dischi da Discogs?"
    }
    private var deleteMessage: String {
        if onlineToDelete == 0 { return "Sono bozze: nessuno le vede ancora." }
        return onlineToDelete == 1 ? "Attenzione: 1 è IN VENDITA. L'annuncio sparisce da Discogs e non si recupera."
                                   : "Attenzione: \(onlineToDelete) sono IN VENDITA. Gli annunci spariscono da Discogs e non si recuperano."
    }
    private var deleteLabel: String {
        selected.count == 1 ? "Elimina 1 disco" : "Elimina \(selected.count) dischi"
    }
    private var askingDelete: Binding<Bool> {
        Binding(get: { !toDelete.isEmpty }, set: { if !$0 { toDelete = [] } })
    }
    private var showingMessage: Binding<Bool> {
        Binding(get: { message != nil }, set: { if !$0 { message = nil } })
    }

    private var list: some View {
        List {
            Section {
                HStack {
                    stat(String(forSaleCount), "Online")
                    Button { selectedTab = 1 } label: {        // porta alla pagina Bozze
                        stat(String(draftCount), "Bozze")
                    }
                    .buttonStyle(.plain)
                    stat(total, "Euro")
                }
            }
            Section {
                ForEach(shown) { l in row(l) }
            } footer: {
                if !selecting && !listings.isEmpty {
                    Text("Tocca un disco per cambiare prezzo, condizioni, descrizione e posizione.\nPer toglierlo dalla vendita scorrilo verso sinistra, oppure tocca Seleziona e scegline tanti.\nLe bozze sono nella pagina Bozze.")
                }
            }
        }
    }

    private func chrome<V: View>(_ content: V) -> some View {
        content
            .themedBackground()
            .navigationTitle("Magazzino")
            .searchable(text: $search, prompt: "Cerca nel magazzino")
            .refreshable { await Task { await sync() }.value }
            .overlay { if loading { ProgressView("Leggo Discogs…").tint(Theme.accent) } }
            .toolbar { toolbarItems }
            .safeAreaInset(edge: .bottom) { deleteBar }
            .animation(.snappy, value: selected.isEmpty)
            .task { if listings.isEmpty { await Task { await sync() }.value } }
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(selecting ? "Fine" : "Seleziona") {
                selecting.toggle()
                selected = []
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Verifica su Discogs", systemImage: "arrow.triangle.2.circlepath") { Task { await sync() } }
                Button("Posizione a chi non ce l'ha (\(noPlaceCount))", systemImage: "archivebox") {
                    newPlace = "Scatola 1"
                    askPlace = true
                }
                .disabled(noPlaceCount == 0)
                Button("Cancella tutte le bozze", systemImage: "trash", role: .destructive) { confirmDeleteAll = true }
                Link("Apri l'inventario su Discogs", destination: URL(string: "https://www.discogs.com/sell/manage")!)
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    @ViewBuilder private var deleteBar: some View {
        if selecting && !selected.isEmpty {
            Button(role: .destructive) { toDelete = Array(selected) } label: {
                Label(deleteLabel, systemImage: "trash")
            }
            .buttonStyle(SignalButtonStyle())
            .padding(.horizontal)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func dialogs<V: View>(_ content: V) -> some View {
        content
            .confirmationDialog(deleteTitle, isPresented: askingDelete, titleVisibility: .visible) {
                Button("Elimina", role: .destructive) {
                    let ids = toDelete
                    Task { await deleteListings(ids) }
                }
            } message: {
                Text(deleteMessage)
            }
            .confirmationDialog("Cancellare DEFINITIVAMENTE tutte le bozze su Discogs? Gli annunci In vendita restano.",
                                isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Cancella le bozze", role: .destructive) { Task { await deleteAll() } }
            }
            .alert(message ?? "", isPresented: showingMessage) {}
            .sheet(item: $editing) { l in
                ListingEditor(target: .listing(l.id)) { after in
                    if after.status == "For Sale" || after.status == "Draft",
                       let i = listings.firstIndex(where: { $0.id == after.id }) { listings[i] = after }
                }
            }
            .alert("Posizione per \(noPlaceCount) annunci senza posizione", isPresented: $askPlace) {
                TextField("es. Scatola 1", text: $newPlace)
                Button("Scrivi su Discogs") {
                    let place = newPlace.trimmingCharacters(in: .whitespaces)
                    guard !place.isEmpty else { return }
                    Task { await fillPlace(place) }
                }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Solo quelli senza posizione: gli altri restano come sono. Cambia solo la posizione, niente prezzi o condizioni.")
            }
    }

    private func deleteAll() async {
        loading = true
        do {
            let n = try await seller.deleteAllDrafts()
            message = "Bozze cancellate: \(n)"
        } catch { message = error.localizedDescription }
        await sync()
    }

    private var total: String {
        let sum = listings.filter { $0.status == "For Sale" }.compactMap { $0.price?.value }.reduce(0, +)
        // formato italiano fatto a mano: punto per le migliaia, virgola per i decimali (2.345,50 €).
        // NumberFormatter in italiano non mette il punto sotto i 10.000 (regola delle "cifre minime"): quindi niente formatter.
        return Self.italian(sum) + (seller.currency == "EUR" ? " €" : " \(seller.currency)")
    }

    /// 2345.5 -> "2.345,50"
    static func italian(_ value: Double) -> String {
        let cents = Int((abs(value) * 100).rounded())
        var whole = String(cents / 100)
        var groups: [String] = []
        while whole.count > 3 {
            groups.insert(String(whole.suffix(3)), at: 0)
            whole.removeLast(3)
        }
        groups.insert(whole, at: 0)
        let decimals = String(format: "%02d", cents % 100)
        return (value < 0 ? "-" : "") + groups.joined(separator: ".") + "," + decimals
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.glow)
                .lineLimit(1).minimumScaleFactor(0.5)          // sempre su una riga: € compreso
                .contentTransition(.numericText())
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ l: Listing) -> some View {
        let draft = l.status == "Draft"
        let isSelected = selected.contains(l.id)
        return ListingRow(listing: l, disc: disc(for: l), selecting: selecting, isSelected: isSelected,
                          currency: seller.currency)
        .contentShape(Rectangle())
        .onTapGesture {
            guard selecting else {                       // fuori da Seleziona: apre la scheda annuncio
                editing = l
                return
            }
            if isSelected { selected.remove(l.id) } else { selected.insert(l.id) }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        .swipeActions(edge: .trailing) {
            if !selecting {
                Button("Elimina", systemImage: "trash", role: .destructive) { toDelete = [l.id] }
            }
        }
        .contextMenu {
            Link("Apri l'annuncio", destination: URL(string: "https://www.discogs.com/sell/item/\(l.id)")!)
            if draft {
                Button("Metti in vendita", systemImage: "arrow.up.circle") {
                    Task { try? await seller.draftToSale(listingID: l.id); await sync() }
                }
            }
            Button(draft ? "Elimina la bozza" : "Togli dalla vendita", systemImage: "trash", role: .destructive) { toDelete = [l.id] }
        }
    }

    private func deleteListings(_ ids: [Int]) async {
        loading = true
        var done = 0
        var failed: [String] = []
        for id in ids {
            do {
                try await seller.deleteListing(id, discs: discs)
                done += 1
                listings.removeAll { $0.id == id }
            } catch { failed.append(error.localizedDescription) }
        }
        loading = false
        selected = []
        selecting = false
        toDelete = []
        Suoni.riconosciuto()
        message = failed.isEmpty ? (done == 1 ? "Disco eliminato da Discogs" : "Dischi eliminati da Discogs: \(done)")
                                 : "Eliminate \(done), non riuscite \(failed.count): \(failed.first ?? "")"
    }

    private func fillPlace(_ place: String) async {
        loading = true
        let r = await seller.fillMissingLocation(listings, place: place, discs: discs)
        await sync()
        message = r.failed == 0 ? "Posizione \"\(place)\" scritta su \(r.done) annunci"
                                : "Scritta su \(r.done) annunci, non riuscita su \(r.failed): riprova"
    }

    private func sync() async {
        loading = true
        defer { loading = false }
        do { listings = try await seller.syncInventory(discs: discs) } catch {
            if !error.isCancellation { message = error.localizedDescription }
        }
    }
}

/// Una riga del magazzino: copertina tonda, titolo, Online/Bozza, posto, prezzo.
struct ListingRow: View {
    let listing: Listing
    let disc: Disc?
    let selecting: Bool
    let isSelected: Bool
    let currency: String

    private var draft: Bool { listing.status == "Draft" }
    private var checkColor: Color {
        return isSelected ? Theme.accent : Theme.muted
    }
    private var localCover: UIImage? {
        guard let file = disc?.coverFile else { return nil }
        return UIImage(contentsOfFile: AppFolders.covers.appendingPathComponent(file).path)
    }

    var body: some View {
        HStack(spacing: 12) {
            if selecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(checkColor)
            }
            cover
            VStack(alignment: .leading, spacing: 4) {
                Text(listing.release.description ?? "Release \(listing.release.id)")
                    .font(.system(size: 16, weight: .semibold)).lineLimit(2)
                // Uguale per tutti, sempre una riga: Online · condizioni (vinile / copertina) · posizione.
                HStack(spacing: 8) { tag; grades; placeText }
                    .lineLimit(1)
            }
            Spacer()
            if let p = listing.price?.value {
                Text(p, format: .currency(code: listing.price?.currency ?? currency))
                    .font(.system(size: 15, weight: .semibold))
            }
            if !selecting {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            }
        }
    }

    @ViewBuilder private var cover: some View {
        Group {
            if let localCover {
                Image(uiImage: localCover).resizable().scaledToFill()
            } else {
                AsyncImage(url: listing.release.thumbnail.flatMap(URL.init(string:))) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Theme.panelHigh
                }
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.accent.opacity(0.8), lineWidth: 1.5))
    }

    /// La posizione: quella scritta su Discogs, altrimenti quella dell'app.
    private var place: String {
        let fromDiscogs = (listing.location ?? "").trimmingCharacters(in: .whitespaces)
        return fromDiscogs.isEmpty ? (disc?.box ?? "").trimmingCharacters(in: .whitespaces) : fromDiscogs
    }

    private var placeText: some View {
        Text(place.isEmpty ? "—" : place)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    /// Condizioni dell'annuncio, solo le sigle: "NM / VG+" (vinile / copertina).
    @ViewBuilder private var grades: some View {
        let parts = [Self.short(listing.condition), Self.short(listing.sleeveCondition)].filter { !$0.isEmpty }
        if !parts.isEmpty {
            Text(parts.joined(separator: " / "))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.glow)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// "Near Mint (NM or M-)" -> "NM"; "Very Good Plus (VG+)" -> "VG+"; "Generic" resta "Generic".
    static func short(_ condition: String?) -> String {
        guard let c = condition, !c.isEmpty else { return "" }
        if let open = c.lastIndex(of: "("), let close = c.lastIndex(of: ")"), open < close {
            let inside = c[c.index(after: open)..<close]
            return String(inside.split(separator: " ").first ?? Substring(inside))
        }
        return c
    }

    private var tag: some View {
        let fg: Color = draft ? Theme.warn : Theme.money
        let bg: Color = draft ? Theme.warnSoft : Theme.military
        return Text(draft ? "Bozza" : "Online")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(fg)
            .background(bg, in: Capsule())
            .fixedSize()
    }
}

/// Posizione fisica del disco (scatola / numero), modificabile al volo.
struct BoxField: View {
    @Bindable var disc: Disc
    var body: some View {
        TextField("posto", text: $disc.box).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 90)
    }
}
