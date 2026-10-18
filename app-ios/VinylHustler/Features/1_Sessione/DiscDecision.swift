import SwiftData
import SwiftUI

/// Il disco riconosciuto in una riga: copertina Discogs, titolo e la decisione da prendere.
/// Lo stesso blocco sta nella fotocamera (sotto il mirino) e nella Sessione (Oggi).
struct DiscRow: View {
    @Environment(Seller.self) private var seller
    @Bindable var disc: Disc
    var onRetake: (() -> Void)? = nil
    @State private var flash = false
    @State private var zap = false              // lampo verde: è appena andato su Discogs

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                cover
                VStack(alignment: .leading, spacing: 5) {
                    StatusTag(status: disc.status)
                    ReleaseTitle(disc: disc, size: 17)
                    Text("\(disc.gradeText) · \(disc.box)")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            DiscActions(disc: disc, onRetake: onRetake)
            DeleteDiscButton(disc: disc, wide: true)
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .stroke(flash ? Theme.glow : (disc.status == .daConfermare ? Theme.glow.opacity(0.45) : .clear),
                    lineWidth: flash ? 2.5 : 1))
        .shadow(color: Theme.glow.opacity(flash ? 0.55 : 0), radius: flash ? 18 : 0)
        .overlay {
            if zap {
                RadialGradient(colors: [Theme.glow.opacity(0.85), Theme.glow.opacity(0)], center: .bottom,
                               startRadius: 0, endRadius: 260)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: disc.statusRaw)
        .onChange(of: disc.statusRaw) { old, new in
            // appena online o in bozza: lampo verde che sale dal basso e si spegne
            if (new == DiscStatus.inVendita.rawValue || new == DiscStatus.bozza.rawValue) && old != new {
                withAnimation(.easeOut(duration: 0.12)) { zap = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(140))
                    withAnimation(.easeOut(duration: 0.6)) { zap = false }
                }
            }
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
        .overlay { if disc.status == .daConfermare { NeonRing().padding(-6) } }   // riconosciuto: anello neon che gira
    }
}

/// Il titolo del disco proposto: toccandolo si apre la release su Discogs, per controllare che la stampa sia quella.
struct ReleaseTitle: View {
    let disc: Disc
    var size: CGFloat = 17

    var body: some View {
        let title = disc.releaseTitle.isEmpty ? "Disco senza nome" : disc.releaseTitle
        if let rid = disc.releaseID, let url = URL(string: "https://www.discogs.com/release/\(rid)") {
            Link(destination: url) {
                (Text(title) + Text("  ") + Text(Image(systemName: "arrow.up.right.square")).foregroundColor(Theme.accent))
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .underline(color: Theme.accent.opacity(0.5))
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }
            .accessibilityHint("Apre la release su Discogs")
        } else {
            Text(title).font(.system(size: size, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(3)
        }
    }
}

/// I tasti, sempre gli stessi e sempre pochi:
///   riconosciuto      -> VENDI  /  BOZZA  /  VERSIONI  (e ELIMINA in fondo)
///   pronto col prezzo -> VENDI  /  BOZZA   (si decide subito)
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
    @State private var editor: EditorRequest?
    /// Console › Annunci › Vendi: "subito" = un tocco ed è online; "scheda" = prima si apre la scheda annuncio.
    @AppStorage("vendiModo") private var vendiModo = "subito"

    struct EditorRequest: Identifiable {
        let id = UUID()
        let status: String
    }

    var body: some View {
        Group {
            switch disc.status {
            case .inLavorazione:
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    Text("Sto guardando…").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.glow)
                }
            case .daConfermare:
                // uno sotto l'altro: Vendi, Bozza, Versioni (se ci sono altre stampe); Elimina è in fondo alla scheda
                VStack(spacing: 8) {
                    // Vendi: conferma, calcola il prezzo e lo mette subito online su Discogs
                    Button("Vendi") { decide(draft: false) }
                    .buttonStyle(SignalButtonStyle())
                    // Bozza: conferma, calcola il prezzo e lo salva come bozza su Discogs (va nella pagina Bozze)
                    Button("Bozza") { decide(draft: true) }
                    .buttonStyle(SignalButtonStyle(filled: false))
                    // solo se ci sono davvero altre stampe trovate oltre a quella proposta
                    if disc.candidates.contains(where: { $0.id != disc.releaseID }) {
                        Button("Versioni") { alternatives = true }
                            .buttonStyle(SignalButtonStyle(filled: false))
                    }
                    changeRelease
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
                        Button("Vendi") { run { Suoni.carica(); await seller.sell(disc); if disc.listingID != nil { Suoni.online() } } }
                            .buttonStyle(SignalButtonStyle())
                        Button("Bozza") { run { Suoni.carica(); await seller.sell(disc, draft: true); if disc.listingID != nil { Suoni.online() } } }
                            .buttonStyle(SignalButtonStyle(filled: false))
                    }
                    Button { editor = EditorRequest(status: "For Sale") } label: {
                        Label("Modifica annuncio", systemImage: "slider.horizontal.3")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    changeRelease
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
                        Button("Cerca") { releaseText = ""; askRelease = true }.buttonStyle(SignalButtonStyle(filled: false))
                        Button("Rifai", role: .destructive) { seller.discard(disc) }
                            .buttonStyle(SignalButtonStyle(filled: false))
                    }
                }
            case .bloccato:
                VStack(alignment: .leading, spacing: 8) {
                    reason
                    Button("Togli", role: .destructive) { run { await seller.remove(disc) } }
                        .buttonStyle(SignalButtonStyle(filled: false))
                    changeRelease
                }
            case .inVendita, .bozza:
                HStack {
                    Label(disc.status == .inVendita ? "Online su Discogs" : "In bozza su Discogs", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.money)
                    Spacer()
                    if let p = disc.price {
                        // tocco = scheda annuncio: si cambia prezzo, condizioni, descrizione… anche da online
                        Button { if disc.listingID != nil { editor = EditorRequest(status: "For Sale") } } label: {
                            HStack(spacing: 6) {
                                Text(p, format: .currency(code: seller.currency))
                                Image(systemName: "pencil").font(.system(size: 11, weight: .bold))
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .foregroundStyle(Theme.money).background(Theme.military, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            case .tolto:
                EmptyView()
            }
        }
        .disabled(busy)
        .opacity(busy ? 0.75 : 1)
        .overlay { if busy { ChargeSweep() } }          // si "carica" mentre lavora (prezzo, Discogs)
        .onChange(of: editor?.id) { _, id in if id != nil { Suoni.apri() } }
        .onChange(of: alternatives) { _, on in if on { Suoni.apri() } }
        .sheet(item: $editor) { req in
            if let lid = disc.listingID {
                ListingEditor(target: .listing(lid))
            } else {
                ListingEditor(target: .disc(disc), initialStatus: req.status)
            }
        }
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
        .alert("Cerca il disco su Discogs", isPresented: $askRelease) {
            TextField("release, catalogo, barcode, artista, titolo…", text: $releaseText)
                .keyboardType(.default)                         // tastiera completa: numeri, lettere, link incollati
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cerca") {
                let text = releaseText
                if let id = Self.releaseID(text) {
                    run { await seller.assign(disc, releaseID: id) }            // numero o link: va dritto
                } else {
                    run {                                                        // tutto il resto: ricerca su Discogs
                        if await seller.searchManual(disc, text: text) { alternatives = true }
                    }
                }
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Numero o link della release, oppure quello che leggi sul disco: numero di catalogo, barcode, etichetta, artista, titolo, anno.")
        }
    }

    /// Un numero di release: "1234567", "r1234567", "[r1234567]" o un link "discogs.com/release/1234567-Artista-Titolo".
    /// Tutto il resto (catalogo, barcode da 10+ cifre, nomi) non è una release: si cerca su Discogs.
    static func releaseID(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = t.range(of: "release/") {
            let digits = t[r.upperBound...].prefix { $0.isNumber }
            return Int(digits).flatMap { $0 > 0 ? $0 : nil }
        }
        let bare = t.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let core = bare.hasPrefix("r") ? String(bare.dropFirst()) : bare
        guard (1...9).contains(core.count), core.allSatisfy(\.isNumber) else { return nil }
        return Int(core).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Release sbagliata? Si riscrive il numero (anche dopo averlo inserito), finché il disco non è su Discogs.
    private var changeRelease: some View {
        Button {
            releaseText = disc.releaseID.map(String.init) ?? ""
            askRelease = true
        } label: {
            Label("Cambia release o cerca", systemImage: "pencil")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private var reason: some View {
        Text(disc.reason).font(.system(size: 14)).foregroundStyle(Theme.warn)
    }

    /// Vendi / Bozza su un disco riconosciuto: conferma e prezzo, poi online subito oppure la scheda annuncio
    /// (Console › Annunci › Vendi).
    private func decide(draft: Bool) {
        run {
            await seller.accept(disc)
            guard disc.status == .pronto else { return }
            if vendiModo == "scheda" {
                editor = EditorRequest(status: draft ? "Draft" : "For Sale")
            } else {
                Suoni.carica()
                await seller.sell(disc, draft: draft)
                if disc.listingID != nil { Suoni.online() }
            }
        }
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
                    HStack(spacing: 12) {
                        Button { done(.candidate(c)) } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: c.coverURL.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Text(c.title).font(.system(size: 15)).foregroundStyle(Theme.text).lineLimit(3)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // la vedo su Discogs prima di sceglierla
                        Link(destination: URL(string: "https://www.discogs.com/release/\(c.id)")!) {
                            Image(systemName: "arrow.up.right.square").font(.system(size: 20)).foregroundStyle(Theme.accent)
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.plain)
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
            .navigationTitle("Versioni")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}

/// Mentre Vendi / Bozza lavorano: una luce che scorre sui tasti, come una barra che si carica.
struct ChargeSweep: View {
    @State private var x: CGFloat = -1

    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, Theme.glow.opacity(0.55), .white.opacity(0.35), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.45)
                .offset(x: x * g.size.width)
                .blendMode(.plusLighter)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: false)) { x = 1.1 } }
    }
}

/// L'anello neon che gira attorno alla copertina del disco riconosciuto, come un vinile sul piatto.
struct NeonRing: View {
    @State private var giro = false

    var body: some View {
        Circle()
            .stroke(AngularGradient(colors: [Theme.glow, Theme.glow.opacity(0), Theme.glow.opacity(0), Theme.glow],
                                    center: .center),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .shadow(color: Theme.glow.opacity(0.8), radius: 5)
            .rotationEffect(.degrees(giro ? 360 : 0))
            .animation(.linear(duration: 1.6).repeatForever(autoreverses: false), value: giro)
            .onAppear { giro = true }
            .allowsHitTesting(false)
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
    /// true: tasto rosso largo "Elimina" in fondo alla scheda; false: cestino tondo.
    var wide = false
    @State private var ask = false
    @State private var busy = false
    @Environment(\.controlSize) private var size

    private var onDiscogs: Bool { disc.listingID != nil }

    var body: some View {
        Button { ask = true } label: {
            if wide {
                Label("Elimina", systemImage: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.warn)
                    .frame(maxWidth: .infinity, minHeight: size == .small ? 34 : 40)
                    .background(Theme.warnSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 36, height: 36)
                    .background(Theme.panelHigh, in: Circle())
            }
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
