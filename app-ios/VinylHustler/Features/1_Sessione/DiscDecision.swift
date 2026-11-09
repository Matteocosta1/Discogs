import SwiftData
import SwiftUI
import UIKit

/// Il disco riconosciuto in una riga: copertina Discogs, titolo e la decisione da prendere.
/// Lo stesso blocco sta nella fotocamera (sotto il mirino) e nella Sessione (Oggi).
struct DiscRow: View {
    @Environment(Seller.self) private var seller
    @Bindable var disc: Disc
    var onRetake: (() -> Void)? = nil
    /// Nella fotocamera: scheda bassa, tasti in fila e cestino sempre in vista in alto a destra.
    var compact = false
    @State private var flash = false
    @State private var zap = false              // lampo verde: è appena andato su Discogs
    // V60: la scheda si stampa dall'alto dietro la riga verde quando il disco è riconosciuto…
    @State private var stampaDa: Date?
    @State private var acquisisco = false       // …e intanto il cartellino dice «ACQUISIZIONE DATI»
    // V60: Vendi / Bozza nella fotocamera: la scheda si ritira dietro una riga verde verticale (da destra a sinistra)
    @State private var ritiroDa: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                cover
                VStack(alignment: .leading, spacing: 5) {
                    if acquisisco {
                        Text("ACQUISIZIONE DATI")
                            .font(Theme.mono(10, .bold)).tracking(1.2)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .foregroundStyle(Theme.money).background(Theme.military, in: Capsule())
                    } else {
                        StatusTag(status: disc.status)
                    }
                    ReleaseTitle(disc: disc, size: compact ? 15 : 17, lines: compact ? 1 : 3)
                    Text("\(disc.gradeText) · \(disc.box)")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if compact { DeleteDiscButton(disc: disc, wide: false) }     // Elimina sempre in vista
            }
            DiscActions(disc: disc, onRetake: onRetake, compact: compact, onRitiro: ritiroAzione)
            if !compact { DeleteDiscButton(disc: disc, wide: true) }
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
        .modifier(StampaRitiro(stampaDa: stampaDa, ritiroDa: ritiroDa))
        .allowsHitTesting(ritiroDa == nil)
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
            if new == DiscStatus.daConfermare.rawValue && old != new { stampa() }
            flash = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                withAnimation(.easeOut(duration: 0.9)) { flash = false }
            }
        }
    }

    /// V60: la scheda si stampa (come nel mock-up: parte dopo 150 ms e dura 700 ms; il cartellino dice
    /// «ACQUISIZIONE DATI» finché non è tutta fuori).
    private func stampa() {
        let da = Date()
        stampaDa = da
        acquisisco = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(850))
            acquisisco = false
            try? await Task.sleep(for: .milliseconds(250))
            if stampaDa == da { stampaDa = nil }           // finita: niente più da ridisegnare
        }
    }

    /// Solo nella fotocamera la scheda si ritira (nella Sessione resta, con «Online su Discogs»).
    private var ritiroAzione: ((Bool) -> Void)? {
        guard compact else { return nil }
        return { si in ritira(si) }
    }

    /// V60: Vendi / Bozza: si ritira (true); se Discogs non lo prende, torna com'era (false).
    private func ritira(_ si: Bool) {
        if si {
            ritiroDa = Date()
        } else {
            withAnimation(.easeOut(duration: 0.25)) { ritiroDa = nil }
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
        .frame(width: compact ? 52 : 72, height: compact ? 52 : 72)
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
    var lines = 3

    var body: some View {
        let title = disc.releaseTitle.isEmpty ? "Disco senza nome" : disc.releaseTitle
        if let rid = disc.releaseID, let url = URL(string: "https://www.discogs.com/release/\(rid)") {
            Link(destination: url) {
                (Text(title) + Text("  ") + Text(Image(systemName: "arrow.up.right.square")).foregroundColor(Theme.accent))
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .underline(color: Theme.accent.opacity(0.5))
                    .multilineTextAlignment(.leading)
                    .lineLimit(lines)
            }
            .accessibilityHint("Apre la release su Discogs")
        } else {
            Text(title).font(.system(size: size, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(lines)
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
    var compact = false
    /// V60: nella fotocamera la scheda si ritira quando si tocca Vendi o Bozza (true) e torna se non va (false).
    var onRitiro: ((Bool) -> Void)? = nil
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
                // uno sotto l'altro: Vendi, Bozza, Versioni (se ci sono altre stampe); Elimina è in fondo alla scheda.
                // Nella fotocamera (compact): tutti in fila, il cestino è in alto a destra.
                let layout = compact ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 8))
                VStack(spacing: 8) {
                  if seller.dalVideo.contains(disc.id) { condizioneVideo }   // V60: dal REC la condizione è del singolo disco
                  prezzoSubito                          // V59: prima il prezzo, poi si decide
                  layout {
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
                  }
                  changeRelease
                }
            case .pronto:
                VStack(alignment: .leading, spacing: 8) {
                    if disc.price != nil {
                        HStack(alignment: .center) {
                            Text("Prezzo").font(.system(size: 15)).foregroundStyle(Theme.muted)
                            Spacer()
                            PrezzoModificabile(disc: disc, size: 28, contaDaZero: false)    // V74: si cambia anche qui
                        }
                    }
                    HStack(spacing: 8) {
                        Button("Vendi") { vendiPronto(draft: false) }
                            .buttonStyle(SignalButtonStyle())
                        Button("Bozza") { vendiPronto(draft: true) }
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
    /// V59: il prezzo calcolato appena riconosciuto, sopra Vendi / Bozza / Versioni.
    /// V60: la condizione di un disco riconosciuto dal video (Vinile e Copertina), partendo da quella scelta in Foto.
    /// Cambiando il vinile il prezzo si ricalcola subito con la stessa regola (Discogs lo suggerisce per grado del vinile);
    /// la copertina va nell'annuncio.
    private var condizioneVideo: some View {
        VStack(spacing: 6) {
            rigaCondizione("VINILE", attuale: disc.media) { g in
                guard g != disc.media else { return }
                disc.mediaRaw = g.rawValue
                guard disc.releaseID != nil else { return }   // senza disco riconosciuto il prezzo resta com'è
                disc.price = nil
                Task { await seller.anteprimaPrezzo(disc) }
            }
            rigaCondizione("COPERTINA", attuale: disc.sleeve) { g in
                disc.sleeveRaw = g.rawValue
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func rigaCondizione(_ titolo: String, attuale: Grade, scegli: @escaping (Grade) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(titolo).font(Theme.mono(9, .bold)).tracking(1.2).foregroundStyle(Theme.glow)
                .frame(width: 74, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(Grade.allCases) { g in
                    let on = attuale == g
                    Button {
                        Suoni.tocco()
                        scegli(g)
                    } label: {
                        Text(g.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .foregroundStyle(on ? Color.black : Theme.text)
                            .background(on ? Theme.accent : Theme.panelHigh, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(titolo.lowercased()) \(g.rawValue)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder private var prezzoSubito: some View {
        HStack(alignment: .center) {
            Text("Prezzo").font(.system(size: 15)).foregroundStyle(Theme.muted)
            Spacer()
            if disc.price != nil {
                // V60: il prezzo conta da zero quando arriva; V74: − / + sulla griglia e cifra da scrivere
                PrezzoModificabile(disc: disc, size: compact ? 24 : 28)
            } else if seller.prezzoInCorso.contains(disc.id) {
                ProgressView().tint(Theme.accent).controlSize(.small)
            } else {
                Text(seller.prezzoMancante.contains(disc.id) ? "non disponibile" : "…")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.muted)
            }
        }
    }

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
        // V60: tocco medio e tick; nella fotocamera (vendita subito) la scheda si ritira dietro la riga verde
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Suoni.carica()
        let ritiro = vendiModo != "scheda"
        if ritiro { onRitiro?(true) }
        run {
            await seller.accept(disc)
            guard disc.status == .pronto else {
                if ritiro { onRitiro?(false) }
                return
            }
            if vendiModo == "scheda" {
                editor = EditorRequest(status: draft ? "Draft" : "For Sale")
            } else {
                await seller.sell(disc, draft: draft)
                if disc.listingID != nil { Suoni.online() } else { onRitiro?(false) }
            }
        }
    }

    /// Vendi / Bozza col prezzo già pronto (V60: stesso tocco, stesso ritiro).
    private func vendiPronto(draft: Bool) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Suoni.carica()
        onRitiro?(true)
        run {
            await seller.sell(disc, draft: draft)
            if disc.listingID != nil { Suoni.online() } else { onRitiro?(false) }
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.warn)
                    .frame(width: 36, height: 36)
                    .background(Theme.warnSoft, in: Circle())
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
                // V60: suono «si toglie» e vibrazione morbida che cala
                Suoni.svuota()
                let g = UIImpactFeedbackGenerator(style: .soft)
                g.impactOccurred(intensity: 1.0)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(70))
                    g.impactOccurred(intensity: 0.6)
                    try? await Task.sleep(for: .milliseconds(70))
                    g.impactOccurred(intensity: 0.3)
                }
                Task {
                    await seller.deleteDisc(disc)
                    busy = false
                }
            }
        }
    }
}

/// V60: la scheda che si stampa dall'alto dietro una riga verde (`stampaDa`) e che si ritira da destra a sinistra
/// dietro una riga verde verticale (`ritiroDa`). Tempi del mock-up: stampa 150 ms + 700 ms, ritiro 520 ms.
struct StampaRitiro: ViewModifier {
    let stampaDa: Date?
    let ritiroDa: Date?

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120, paused: stampaDa == nil && ritiroDa == nil)) { ctx in
            let st: Double = stampaDa.map { morbido((ctx.date.timeIntervalSince($0) - 0.15) / 0.7) } ?? 1
            let via: Double = ritiroDa.map { morbido(ctx.date.timeIntervalSince($0) / 0.52) } ?? 0
            content
                .mask {
                    // a riposo la maschera è più grande della scheda: il bagliore attorno (lampo, ombra) resta intero
                    GeometryReader { g in
                        let intera = st >= 1 && via <= 0
                        Rectangle()
                            .frame(width: intera ? g.size.width + 80 : g.size.width * CGFloat(1 - via),
                                   height: intera ? g.size.height + 80 : g.size.height * CGFloat(st))
                            .offset(x: intera ? -40 : 0, y: intera ? -40 : 0)
                    }
                }
                .overlay {
                    GeometryReader { g in
                        ZStack(alignment: .topLeading) {
                            if st > 0 && st < 1 {
                                Rectangle().fill(Theme.glow)
                                    .frame(width: max(0, g.size.width - 24), height: 2)
                                    .shadow(color: Theme.glow, radius: 4)
                                    .offset(x: 12, y: g.size.height * CGFloat(st) - 1)
                            }
                            if via > 0 && via < 1 {
                                Rectangle().fill(Theme.glow)
                                    .frame(width: 2, height: max(0, g.size.height - 10))
                                    .shadow(color: Theme.glow, radius: 4)
                                    .offset(x: g.size.width * CGFloat(1 - via) - 1, y: 10)
                            }
                        }
                        .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                    }
                    .allowsHitTesting(false)
                }
        }
    }
}

/// V60: il prezzo che conta da zero al valore in 700 ms (come nel mock-up).
struct PrezzoConta: View {
    let valore: Double
    let valuta: String
    var size: CGFloat = 28
    @State private var da = Date()
    @State private var finito = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120, paused: finito)) { ctx in
            let k = finito ? 1 : morbido(ctx.date.timeIntervalSince(da) / 0.7)
            Text(valore * k, format: .currency(code: valuta))
                .font(.system(size: size, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.glow)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(750))
            finito = true
        }
        .accessibilityLabel(Text(valore, format: .currency(code: valuta)))
    }
}

/// V74: il prezzo della scheda si cambia prima di Vendi / Bozza. − e + spostano di un gradino della griglia
/// (Settings › Regole del prezzo), mai sotto il minimo; toccando la cifra la si scrive. Un prezzo cambiato
/// a mano porta la scritta MANUALE e resta quello anche premendo Vendi (non si ricalcola).
struct PrezzoModificabile: View {
    @Environment(Seller.self) private var seller
    @Bindable var disc: Disc
    var size: CGFloat = 28
    var contaDaZero = true
    @State private var scrive = false
    @State private var testo = ""
    @State private var toccato = false
    @FocusState private var fuoco: Bool

    private var manuale: Bool { disc.priceCalculation == Seller.prezzoManuale }
    private var passo: Double { NSDecimalNumber(decimal: seller.rules.step).doubleValue }
    private var minimo: Double { NSDecimalNumber(decimal: seller.rules.minimum).doubleValue }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 10) {
                tasto("minus", "Abbassa il prezzo") { gradino(-1) }
                cifra
                tasto("plus", "Alza il prezzo") { gradino(1) }
            }
            if manuale {
                Text("MANUALE").font(Theme.mono(9, .bold)).tracking(1.5).foregroundStyle(Theme.glow)
            }
        }
    }

    @ViewBuilder private var cifra: some View {
        let p = disc.price ?? 0
        if scrive {
            TextField("", text: $testo)
                .keyboardType(.numbersAndPunctuation)
                .submitLabel(.done)
                .multilineTextAlignment(.center)
                .font(.system(size: size, weight: .bold)).monospacedDigit()
                .foregroundStyle(Theme.glow)
                .frame(width: size * 4.4)
                .focused($fuoco)
                .onSubmit(conferma)
                .onChange(of: fuoco) { _, f in if !f { conferma() } }
        } else if contaDaZero && !toccato {
            PrezzoConta(valore: p, valuta: seller.currency, size: size)
                .shadow(color: Theme.glow.opacity(0.35), radius: 8)
                .id(p)
                .onTapGesture(perform: apriTastiera)
        } else {
            Text(p, format: .currency(code: seller.currency))
                .font(.system(size: size, weight: .bold)).monospacedDigit()
                .foregroundStyle(Theme.glow)
                .shadow(color: Theme.glow.opacity(0.35), radius: 8)
                .contentTransition(.numericText(value: p))
                .onTapGesture(perform: apriTastiera)
        }
    }

    private func tasto(_ icona: String, _ etichetta: String, _ fai: @escaping () -> Void) -> some View {
        Button { fai() } label: {
            Image(systemName: icona).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.glow)
                .frame(width: 34, height: 34)
                .overlay(Circle().stroke(Theme.glow.opacity(0.5), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(etichetta)
    }

    /// Il gradino sopra o sotto sulla griglia (da 13 € con griglia 2,50: + va a 15, − a 12,50).
    private func gradino(_ verso: Int) {
        if scrive { conferma() }
        guard passo > 0, let p = disc.price else { return }
        let nuovo = verso > 0 ? (floor(p / passo + 1e-9) + 1) * passo
                              : max(minimo, (ceil(p / passo - 1e-9) - 1) * passo)
        guard nuovo != p else { return }                       // già al minimo: niente
        Suoni.tocco()
        toccato = true
        withAnimation(.snappy(duration: 0.25)) { imposta(nuovo) }
    }

    private func apriTastiera() {
        Suoni.tocco()
        testo = (disc.price ?? 0).formatted(.number.precision(.fractionLength(2)))
        scrive = true
        fuoco = true
    }

    private func conferma() {
        guard scrive else { return }
        scrive = false
        fuoco = false
        let t = testo.replacingOccurrences(of: "€", with: "").replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
        // «13», «13,50» o «1.250,00»; senza virgola il punto vale come virgola («13.5»)
        let numero = t.contains(",") ? t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") : t
        guard let v = Double(numero), v > 0, v < 100_000, (v * 100).rounded() / 100 != disc.price else { return }
        toccato = true
        imposta((v * 100).rounded() / 100)
    }

    private func imposta(_ v: Double) {
        disc.price = v
        disc.priceCalculation = Seller.prezzoManuale
    }
}
