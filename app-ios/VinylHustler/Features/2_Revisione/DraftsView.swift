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
    @State private var editing: Listing?
    @State private var lit: Set<Int> = []              // bozze appena messe in vendita: si accendono e poi scivolano via
    @State private var done = 0                         // per la barra di "Pubblica"
    @State private var total = 0

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
                    ForEach(Array(shownDrafts.enumerated()), id: \.element.id) { i, l in
                        DraftRow(listing: l, lit: lit.contains(l.id), currency: seller.currency, index: i,
                                 onEdit: { editing = l }, onSell: { Suoni.click(); Task { await sell(l) } },
                                 onDelete: { Suoni.click(); toDelete = l })
                            .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
                    }
                    if local.isEmpty && shownDrafts.isEmpty && !loading {
                        VStack(spacing: 18) {
                            VinylMark(size: 110, spinning: true)
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
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .background(alignment: .leading) {
                                // la barra si riempie man mano che pubblica
                                GeometryReader { g in
                                    Color.black.opacity(0.18)
                                        .frame(width: total == 0 ? 0 : g.size.width * CGFloat(done) / CGFloat(total))
                                        .animation(.easeOut(duration: 0.3), value: done)
                                }
                            }
                    }
                    .buttonStyle(SignalButtonStyle())
                    .controlSize(.small)                       // V51: più piccolo, in proporzione al resto
                    .frame(width: 210)
                    .shadow(color: Theme.accent.opacity(0.25), radius: 8)
                    .disabled(publishing)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
                }
            }
            .confirmationDialog(publishCount == 1 ? "Mettere in vendita 1 disco su Discogs?" : "Mettere in vendita \(publishCount) dischi su Discogs?",
                                isPresented: $askPublish, titleVisibility: .visible) {
                Button("Pubblica \(publishCount)") { Task { await publishAll() } }
            } message: {
                Text("Vanno online subito su Discogs.")
            }
            .onChange(of: editing?.id) { _, id in if id != nil { Suoni.apri() } }
            .sheet(item: $editing) { l in
                ListingEditor(target: .listing(l.id)) { after in
                    if after.status == "Draft", let i = drafts.firstIndex(where: { $0.id == after.id }) {
                        drafts[i] = after
                    } else {
                        moved(l)                                 // messa in vendita dalla scheda
                    }
                }
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

    /// La bozza è andata online: sparisce da qui, e il disco dell'app (se c'è) risulta in vendita.
    private func moved(_ l: Listing) {
        withAnimation(.easeIn(duration: 0.4)) {
            drafts.removeAll { $0.id == l.id }
            lit.remove(l.id)
        }
        for d in discs where d.listingID == l.id { d.status = .inVendita }
    }

    /// Vendi su una bozza: si accende (bordo verde, copertina a colori, scintille), poi scivola via.
    private func sell(_ l: Listing) async {
        do {
            try await seller.draftToSale(listingID: l.id)
            Suoni.online()
            withAnimation(.spring(duration: 0.4, bounce: 0.3)) { _ = lit.insert(l.id) }
            try? await Task.sleep(for: .milliseconds(700))
            moved(l)
            done += 1
        } catch { seller.lastError = error.localizedDescription }
    }

    private func publishAll() async {
        publishing = true
        defer { publishing = false; done = 0; total = 0 }
        let list = shownDrafts
        total = ready.count + list.count
        done = 0
        Suoni.pubblico()
        await seller.publishReady(ready)
        done = ready.count
        for l in list { await sell(l) }
        Suoni.fine()
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

/// Una bozza: "dorme" (copertina spenta, lucina rossa di standby).
/// Toccando Vendi si accende: bordo verde, copertina a colori, un riflesso di luce e le scintille.
/// Titolo = apre su Discogs; tasto verde tondo = scheda annuncio; cestino = elimina.
struct DraftRow: View {
    let listing: Listing
    let lit: Bool
    let currency: String
    let index: Int
    let onEdit: () -> Void
    let onSell: () -> Void
    let onDelete: () -> Void

    @State private var shown = false
    @State private var standby = false
    @State private var sheen = false

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: listing.release.thumbnail.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                .frame(width: 50, height: 50)
                .clipShape(Circle())
                .saturation(lit ? 1 : 0.15)
                .brightness(lit ? 0 : -0.15)
                .overlay(Circle().stroke(lit ? Theme.glow : Color.clear, lineWidth: 2))
                .shadow(color: Theme.glow.opacity(lit ? 0.7 : 0), radius: 8)
            VStack(alignment: .leading, spacing: 4) {
                Link(destination: URL(string: "https://www.discogs.com/sell/item/\(listing.id)")!) {
                    (Text(listing.release.description ?? "Release \(listing.release.id)") + Text(" ↗").foregroundColor(Theme.accent))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(lit ? "Online" : "Bozza")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .foregroundStyle(lit ? Theme.money : Theme.warn)
                        .background(lit ? Theme.military : Theme.warnSoft, in: Capsule())
                    Text([ListingRow.short(listing.condition), ListingRow.short(listing.sleeveCondition)].filter { !$0.isEmpty }.joined(separator: " / "))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.glow)
                    if !lit {
                        Circle().fill(Theme.warn).frame(width: 6, height: 6)
                            .shadow(color: Theme.warn, radius: 3)
                            .opacity(standby ? 1 : 0.25)
                            .animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true), value: standby)
                    }
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                if let p = listing.price?.value {
                    Text(p, format: .currency(code: listing.price?.currency ?? currency)).font(.system(size: 14, weight: .bold))
                }
                HStack(spacing: 6) {
                    Button(action: onDelete) {
                        Image(systemName: "trash").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warn)
                            .frame(width: 30, height: 30).background(Theme.warnSoft, in: Circle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Elimina la bozza")
                    Button(action: onEdit) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                            .frame(width: 30, height: 30).background(Theme.military, in: Circle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Modifica l'annuncio")
                    Button(action: onSell) {
                        Text("Vendi").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 12).frame(height: 30)
                            .overlay(Capsule().stroke(Theme.accent, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(lit)
                }
            }
        }
        .padding(12)
        .background(lit ? Color(red: 0.086, green: 0.125, blue: 0.102) : Theme.panel,
                    in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay {
            // come sempre: nessun bordo; verde solo quando la metti in vendita
            if lit {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1)
            }
        }
        .overlay {
            // riflesso di luce che attraversa la scheda quando si accende
            if lit {
                LinearGradient(colors: [.clear, .white.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 120)
                    .offset(x: sheen ? 260 : -260)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .allowsHitTesting(false)
                    .onAppear { withAnimation(.easeOut(duration: 0.6)) { sheen = true } }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { if lit { SparkBurst() } }
        .shadow(color: Theme.glow.opacity(lit ? 0.35 : 0), radius: 14)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 22)
        .onAppear {
            withAnimation(.spring(duration: 0.5, bounce: 0.25).delay(Double(index) * 0.07)) { shown = true }
            standby = true
        }
    }
}

/// Scintille verdi che partono dal centro e si spengono (quando una bozza va online).
struct SparkBurst: View {
    @State private var go = false

    var body: some View {
        ZStack {
            ForEach(0..<14, id: \.self) { k in
                let a = Double(k) / 14 * 2 * .pi
                let r = 70.0 + Double(k % 3) * 40
                Circle().fill(Theme.glow).frame(width: 6, height: 6)
                    .shadow(color: Theme.glow, radius: 4)
                    .offset(x: go ? cos(a) * r * 1.6 : 0, y: go ? sin(a) * r * 0.6 : 0)
                    .scaleEffect(go ? 0.2 : 1)
                    .opacity(go ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.timingCurve(0.1, 0.8, 0.3, 1, duration: 0.7)) { go = true } }
    }
}
