import SwiftData
import SwiftUI

/// Il disco riconosciuto in una riga: copertina Discogs, titolo e la decisione da prendere.
/// Lo stesso blocco sta nella fotocamera (sotto il mirino) e nella Sessione (Oggi).
struct DiscRow: View {
    @Environment(Seller.self) private var seller
    @Bindable var disc: Disc
    var onRetake: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                cover
                VStack(alignment: .leading, spacing: 5) {
                    StatusTag(status: disc.status)
                    Text(disc.releaseTitle.isEmpty ? "Disco senza nome" : disc.releaseTitle)
                        .font(Theme.display(19, .heavy)).foregroundStyle(Theme.text).lineLimit(3)
                    Text("\(disc.gradeText) · \(disc.box)".uppercased())
                        .font(Theme.mono(9, .semibold)).tracking(0.8).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            DiscActions(disc: disc, onRetake: onRetake)
        }
        .padding(12)
        .background(Theme.panel)
        .overlay(Rectangle().stroke(disc.status == .daConfermare ? Theme.accent.opacity(0.6) : Theme.line, lineWidth: 1))
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
        .frame(width: 76, height: 76)
        .clipped()
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
                    Text("STO GUARDANDO…").font(Theme.mono(12, .bold)).tracking(1.5).foregroundStyle(Theme.accent)
                }
            case .daConfermare:
                VStack(alignment: .leading, spacing: 8) {
                    Text("È QUESTO?").font(Theme.mono(11, .bold)).tracking(1.5).foregroundStyle(Theme.muted)
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
                            Text("PREZZO").font(Theme.mono(11, .bold)).tracking(1.5).foregroundStyle(Theme.muted)
                            Spacer()
                            Text(p, format: .currency(code: seller.currency)).font(Theme.display(26)).foregroundStyle(Theme.accent)
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
                    Label(disc.status == .inVendita ? "ONLINE SU DISCOGS" : "IN BOZZA SU DISCOGS", systemImage: "checkmark")
                        .font(Theme.mono(11, .bold)).tracking(1).foregroundStyle(Theme.accent)
                    Spacer()
                    if let p = disc.price {
                        Text(p, format: .currency(code: seller.currency)).font(Theme.mono(13, .bold)).foregroundStyle(Theme.text)
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
        Text(disc.reason).font(Theme.mono(11, .semibold)).foregroundStyle(Theme.warn)
            .padding(.leading, 10)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.warn).frame(width: 3) }
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
                    Text("Nessun'altra release trovata.").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                }
                ForEach(others) { c in
                    Button { done(.candidate(c)) } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: c.coverURL.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                                .frame(width: 56, height: 56).clipped()
                            Text(c.title).font(Theme.mono(12)).foregroundStyle(Theme.text).lineLimit(3)
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
                .font(Theme.mono(13, .semibold))
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Quale è?")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}
