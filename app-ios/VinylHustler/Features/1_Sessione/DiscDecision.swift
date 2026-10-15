import SwiftData
import SwiftUI

/// Il disco riconosciuto in una riga: copertina Discogs, titolo e la decisione da prendere.
/// Lo stesso blocco sta nella fotocamera (sotto il mirino) e nella Sessione (Oggi).
struct DiscRow: View {
    @Environment(Seller.self) private var seller
    @Bindable var disc: Disc
    var onRetake: (() -> Void)? = nil
    @State private var flash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                cover
                VStack(alignment: .leading, spacing: 5) {
                    StatusTag(status: disc.status)
                    Text(disc.releaseTitle.isEmpty ? "Disco senza nome" : disc.releaseTitle)
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(3)
                    Text("\(disc.gradeText) · \(disc.box)")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                DeleteDiscButton(disc: disc)
            }
            DiscActions(disc: disc, onRetake: onRetake)
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .stroke(flash ? Theme.glow : (disc.status == .daConfermare ? Theme.glow.opacity(0.45) : .clear),
                    lineWidth: flash ? 2.5 : 1))
        .shadow(color: Theme.glow.opacity(flash ? 0.55 : 0), radius: flash ? 18 : 0)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: disc.statusRaw)
        .onChange(of: disc.statusRaw) { _, new in
            // riconosciuto o prezzo pronto: la scheda si accende un attimo, come un'icona di JARVIS
            guard new == DiscStatus.daConfermare.rawValue || new == DiscStatus.pronto.rawValue else { return }
            flash = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                withAnimation(.easeOut(duration: 0.9)) { flash = false }
            }
        }
    }

    /// Copertina Discogs (pulita); la foto del venditore solo se Discogs non ne ha.
    private var cover: some View {
        let own = disc.photoFiles.first.flatMap { UIImage(contentsOfFile: AppFolders.photos.appendingPathComponent($0).path) }
        return AsyncImage(url: disc.coverURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else if let own {
                Image(uiImage: own).resizable().scaledToFill()
            } else {
                Theme.panelHigh
            }
        }
        .frame(width: 72, height: 72)
        .overlay { if disc.status == .inLavorazione { ScanSweep() } }
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.accent.opacity(0.8), lineWidth: 1.5))
    }
}

/// I tasti, sempre gli stessi e sempre pochi:
///   riconosciuto      -> SÌ, È QUESTO  /  NO
///   pronto col prezzo -> IN VENDITA  /  BOZZA  /  DOPO
///   non riconosciuto  -> ALTRA FOTO  /  NUMERO RELEASE  /  RIFAI
struct DiscActions: View {
    @Environment(Seller.self) private var seller
    @Environment(\.modelContext) private var context
    @Bindable var disc: Disc
    var onRetake: (() -> Void)? = nil
    @State private var busy = false
    @State private var alternatives = false
    @State private var askRelease = false
    @State private var releaseText = ""

    var body: some View {
        Group {
            switch disc.status {
            case .inLavorazione:
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    Text("Sto guardando…").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.glow)
                }
            case .daConfermare:
                VStack(alignment: .leading, spacing: 8) {
                    Text("È questo?").font(.system(size: 15)).foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        Button("Sì, è questo") { run { await seller.accept(disc) } }
                            .buttonStyle(SignalButtonStyle())
                        Button("No") { alternatives = true }
                            .buttonStyle(SignalButtonStyle(filled: false))
                            .frame(width: 90)
                    }
                }
            case .pronto:
                VStack(alignment: .leading, spacing: 8) {
                    if let p = disc.price {
                        HStack(alignment: .lastTextBaseline) {
                            Text("Prezzo").font(.system(size: 15)).foregroundStyle(Theme.muted)
                            Spacer()
                            Text(p, format: .currency(code: seller.currency)).font(.system(size: 28, weight: .bold))
                                .foregroundStyle(Theme.glow)
                                .contentTransition(.numericText(value: p))
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    HStack(spacing: 8) {
                        Button("In vendita") { run { await seller.sell(disc) } }.buttonStyle(SignalButtonStyle())
                        Button("Bozza") { run { await seller.sell(disc, draft: true) } }.buttonStyle(SignalButtonStyle(filled: false))
                        if !disc.parked {
                            Button("Dopo") { seller.park(disc) }.buttonStyle(SignalButtonStyle(filled: false))
                        }
                    }
                }
            case .daControllare:
                VStack(alignment: .leading, spacing: 8) {
                    reason
                    HStack(spacing: 8) {
                        if let onRetake {
                            Button("Altra foto") { onRetake() }.buttonStyle(SignalButtonStyle())
                        }
                        if !disc.candidates.isEmpty {
                            Button("Proposte") { alternatives = true }.buttonStyle(SignalButtonStyle(filled: onRetake == nil))
                        }
                        Button("N° release") { askRelease = true }.buttonStyle(SignalButtonStyle(filled: false))
                        Button("Rifai", role: .destructive) { seller.discard(disc) }
                            .buttonStyle(SignalButtonStyle(filled: false))
                    }
                }
            case .bloccato:
                VStack(alignment: .leading, spacing: 8) {
                    reason
                    Button("Togli", role: .destructive) { run { await seller.remove(disc) } }
                        .buttonStyle(SignalButtonStyle(filled: false))
                }
            case .inVendita, .bozza:
                HStack {
                    Label(disc.status == .inVendita ? "Online su Discogs" : "In bozza su Discogs", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.money)
                    Spacer()
                    if let p = disc.price {
                        Text(p, format: .currency(code: seller.currency)).font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .foregroundStyle(Theme.money).background(Theme.military, in: Capsule())
                    }
                }
            case .tolto:
                EmptyView()
            }
        }
        .disabled(busy)
        .opacity(busy ? 0.5 : 1)
        .overlay { if busy { ProgressView().tint(Theme.accent) } }
        .sheet(isPresented: $alternatives) {
            AlternativesSheet(disc: disc, onRetake: onRetake) { pick in
                alternatives = false
                switch pick {
                case .candidate(let c): run { await seller.pick(disc, candidate: c) }
                case .number: askRelease = true
                case .retake:
                    seller.discard(disc)
                }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Numero della release Discogs", isPresented: $askRelease) {
            TextField("discogs.com/release/NUMERO", text: $releaseText).keyboardType(.numberPad)
            Button("Conferma") {
                if let id = Int(releaseText.filter(\.isNumber)) { run { await seller.assign(disc, releaseID: id) } }
            }
            Button("Annulla", role: .cancel) {}
        }
    }

    private var reason: some View {
        Text(disc.reason).font(.system(size: 14)).foregroundStyle(Theme.warn)
    }

    private func run(_ job: @escaping () async -> Void) {
        busy = true
        Task {
            await job()
            busy = false
            try? context.save()
        }
    }
}

/// "No, non è questo": le altre release trovate, con la copertina. Tocchi quella giusta.
struct AlternativesSheet: View {
    enum Pick { case candidate(Candidate), number, retake }
    let disc: Disc
    var onRetake: (() -> Void)?
    let done: (Pick) -> Void

    var body: some View {
        NavigationStack {
            List {
                let others = disc.candidates.filter { $0.id != disc.releaseID }
                if others.isEmpty {
                    Text("Nessun'altra release trovata.").font(.system(size: 15)).foregroundStyle(Theme.muted)
                }
                ForEach(others) { c in
                    Button { done(.candidate(c)) } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: c.coverURL.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text(c.title).font(.system(size: 15)).foregroundStyle(Theme.text).lineLimit(3)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                        }
                    }
                    .listRowBackground(Theme.panel)
                }
                Section {
                    Button("Scrivo il numero della release") { done(.number) }
                    Button(onRetake == nil ? "Nessuno: lo tolgo" : "Nessuno: rifaccio la foto", role: .destructive) { done(.retake) }
                }
                .listRowBackground(Theme.panel)
                .font(.system(size: 16))
                .tint(Theme.accent)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Quale è?")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}

/// La riga di scansione che passa sulla copertina mentre l'app sta guardando il disco.
struct ScanSweep: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let p = (sin(t * 3) + 1) / 2                     // su e giù, morbido
            GeometryReader { geo in
                let y = geo.size.height * p
                ZStack(alignment: .top) {
                    Theme.glow.opacity(0.10)
                    LinearGradient(colors: [Theme.glow.opacity(0), Theme.glow.opacity(0.35)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 22)
                        .offset(y: y - 22)
                    Rectangle().fill(Theme.glow).frame(height: 2)
                        .shadow(color: Theme.glow, radius: 4)
                        .offset(y: y - 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Il cestino, su ogni disco e in ogni stato. Se il disco è già su Discogs (online o in bozza)
/// lo toglie anche da lì; poi sparisce dall'app con le sue foto. Chiede sempre conferma.
struct DeleteDiscButton: View {
    @Environment(Seller.self) private var seller
    let disc: Disc
    @State private var ask = false
    @State private var busy = false

    private var onDiscogs: Bool { disc.listingID != nil }

    var body: some View {
        Button { ask = true } label: {
            Image(systemName: "trash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .frame(width: 36, height: 36)
                .background(Theme.panelHigh, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel("Elimina il disco")
        .confirmationDialog(onDiscogs ? "Eliminare il disco? Lo tolgo anche da Discogs."
                                      : "Eliminare il disco? Sparisce dall'app con le sue foto.",
                            isPresented: $ask, titleVisibility: .visible) {
            Button("Elimina", role: .destructive) {
                busy = true
                Task {
                    await seller.deleteDisc(disc)
                    busy = false
                }
            }
        }
    }
}
