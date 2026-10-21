import AVFoundation
import ImageIO
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// OCCHIO — la fotocamera di Vinyl Hustler, come gli occhi di JARVIS.
///   · tocchi lo scatto: una foto, e il disco viene riconosciuto subito (e te lo dice a voce);
///   · tocchi REC: un video vero (fino a 20 secondi). Passi i dischi davanti al telefono, tocchi di nuovo
///     per fermare: li riconosce tutti, uno per uno.
/// Sotto il mirino compaiono i dischi riconosciuti: sì, è questo / no, e poi se metterlo in vendita.
struct OcchioView: View {
    let place: String
    let media: Grade
    let sleeve: Grade
    let close: () -> Void

    static let maxVideo = 20.0

    @Environment(Seller.self) private var seller
    @Environment(\.modelContext) private var context
    @Query(sort: \Disc.createdAt, order: .reverse) private var all: [Disc]
    @AppStorage("voice") private var voice = true
    @Environment(\.scenePhase) private var fase
    @State private var motore = MotoreOcchio()
    @State private var openedAt = Date()
    @State private var stato = "AGGANCIO OTTICO"
    @State private var lampo = false
    @State private var agganciato = false
    @State private var registrando = false
    @State private var inizioVideo = Date()
    @State private var preparo = false
    @State private var attachTo: Disc?              // "Altra foto": il prossimo scatto va a questo disco
    @State private var preso = false                // disco appena riconosciuto: il mirino fa "LOCK"

    private let tinta = Theme.accent

    /// I dischi fotografati da quando hai aperto la fotocamera (il più recente prima).
    private var seen: [Disc] {
        all.filter { $0.createdAt >= openedAt && $0.status != .tolto && !$0.parked }
    }
    private static func done(_ d: Disc) -> Bool { d.status == .inVendita || d.status == .bozza }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                AnteprimaOcchio(motore: motore)
                    .opacity(agganciato ? 1 : 0)
                    .animation(.easeOut(duration: 0.4), value: agganciato)
                MirinoOcchio(agganciato: agganciato, scattando: registrando, analizzo: seller.working > 0,
                             preso: preso, tinta: tinta)
                    .allowsHitTesting(false)
                Color.white.opacity(lampo ? 0.85 : 0).allowsHitTesting(false)
                VStack(spacing: 10) {
                    topBar
                    Spacer()
                    if registrando { recBadge }
                    if let attachTo {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.viewfinder")
                            Text("PROSSIMA FOTO → \(attachTo.releaseTitle.isEmpty ? "DISCO NON RICONOSCIUTO" : attachTo.releaseTitle.uppercased())")
                                .lineLimit(1)
                            Button { self.attachTo = nil } label: { Image(systemName: "xmark") }
                        }
                        .font(Theme.mono(11, .bold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(tinta)
                    }
                    Text(stato)
                        .font(Theme.mono(11, .semibold)).tracking(2.5)
                        .foregroundStyle(tinta)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Capsule())
                    controls
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: .infinity)
            results
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden()
        .task { await prepara() }
        .onDisappear { motore.ferma() }
        // app in secondo piano (per esempio si torna a una videochiamata): la fotocamera si libera subito,
        // così una videochiamata o un'altra app la riavranno; tornando qui si riaccende da sola
        .onChange(of: fase) { _, nuova in
            switch nuova {
            case .active:
                guard !motore.sessione.isRunning else { return }
                motore.avvia { ok in
                    Task { @MainActor in
                        agganciato = ok
                        if ok { stato = "INQUADRA UN DISCO" }
                    }
                }
            case .background:
                agganciato = false
                motore.ferma()                      // ferma anche un video in corso: il file arriva lo stesso
            default:
                break                               // tendina, Centro di Controllo: la fotocamera resta accesa
            }
        }
        // disco riconosciuto: il mirino si accende un attimo ("LOCK")
        .onChange(of: seen.filter { $0.status == .daConfermare }.count) { old, new in
            guard new > old else { return }
            withAnimation(.spring(duration: 0.35, bounce: 0.4)) { preso = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeOut(duration: 0.5)) { preso = false }
            }
        }
    }

    // MARK: Pezzi

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("VINYL HUSTLER").font(Theme.mono(14, .bold)).tracking(4)
                Text("\(place) · \(media == sleeve ? media.rawValue : "\(media.rawValue)/\(sleeve.rawValue)")".uppercased())
                    .font(Theme.mono(9, .semibold)).tracking(1.5).opacity(0.8)
            }
            .foregroundStyle(tinta)
            .shadow(color: tinta.opacity(0.6), radius: 6)
            Spacer()
            roundButton(voice ? "speaker.wave.2.fill" : "speaker.slash.fill", label: voice ? "Voce attiva" : "Voce spenta") {
                voice.toggle()
            }
            roundButton("xmark", label: "Chiudi") {
                if registrando { motore.fermaVideo() }
                close()
            }
        }
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tinta)
                .frame(width: 42, height: 42)
                .background(Color.black.opacity(0.45))
                .clipShape(Circle())
                .overlay(Circle().stroke(tinta.opacity(0.5), lineWidth: 1))
        }
        .accessibilityLabel(label)
    }

    private var recBadge: some View {
        TimelineView(.periodic(from: inizioVideo, by: 0.5)) { ctx in
            let s = Int(ctx.date.timeIntervalSince(inizioVideo))
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 10, height: 10).shadow(color: .red, radius: 6)
                Text(String(format: "REC %02d:%02d", s / 60, s % 60))
                    .font(Theme.mono(14, .bold)).tracking(2).foregroundStyle(.white)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Color.black.opacity(0.55))
            .clipShape(Capsule())
        }
    }

    /// Scatto al centro (grande), REC a destra. Tocchi REC una volta per partire, una volta per fermare.
    private var controls: some View {
        HStack {
            Color.clear.frame(width: 70, height: 70)
            Spacer()
            Button { scatta() } label: {
                ZStack {
                    Circle().stroke(tinta, lineWidth: 3).frame(width: 74, height: 74)
                    Circle().fill(tinta).frame(width: 58, height: 58)
                    Image(systemName: "camera.fill").font(.system(size: 19, weight: .bold)).foregroundStyle(Color.black)
                }
                .contentShape(Circle())
                .shadow(color: tinta.opacity(0.6), radius: 10)
            }
            .buttonStyle(.plain)
            .disabled(!agganciato || registrando || preparo)
            .opacity(registrando ? 0.3 : 1)
            .accessibilityLabel("Scatta una foto")
            Spacer()
            Button { registrando ? motore.fermaVideo() : registra() } label: {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.9), lineWidth: 3).frame(width: 62, height: 62)
                    if registrando {
                        RoundedRectangle(cornerRadius: 5).fill(Color.red).frame(width: 24, height: 24)
                    } else {
                        Circle().fill(Color.red).frame(width: 48, height: 48)
                        Text("REC").font(Theme.mono(11, .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 70, height: 70)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!agganciato || preparo || attachTo != nil)
            .accessibilityLabel(registrando ? "Ferma il video" : "Registra un video")
        }
    }

    /// Sotto la fotocamera, compatti (il mirino prende il resto dello schermo):
    ///   · i dischi da decidere, uno accanto all'altro (il più nuovo a sinistra);
    ///   · una fila sottile con quelli già messi su Discogs in questa serie.
    @ViewBuilder private var results: some View {
        if !seen.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                let pending = seen.filter { !Self.done($0) }
                let doneOnes = seen.filter(Self.done)
                if !pending.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 10) {
                                ForEach(pending) { disc in
                                    // tasti bassi, e la scheda scorre in verticale: Elimina si raggiunge sempre
                                    ScrollView(.vertical, showsIndicators: false) {
                                        DiscRow(disc: disc, onRetake: { attachTo = disc }, compact: true)
                                            .controlSize(.small)
                                    }
                                    .frame(width: 350)
                                    .id(disc.id)
                                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                            removal: .scale(scale: 0.6).combined(with: .opacity)))
                                }
                            }
                            .animation(.spring(duration: 0.45, bounce: 0.25), value: pending.map(\.id))
                            .padding(.horizontal, 12)
                        }
                        // disco nuovo: la striscia torna all'inizio, dove compare
                        .onChange(of: seen.first?.id) { _, id in
                            guard let id else { return }
                            withAnimation(.snappy) { proxy.scrollTo(id, anchor: .leading) }
                        }
                    }
                    .frame(height: 210)
                }
                if !doneOnes.isEmpty {
                    Text("GIÀ SU DISCOGS · \(doneOnes.count)")
                        .font(Theme.mono(9, .semibold)).tracking(2).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 14)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 6) {
                            ForEach(doneOnes) { disc in
                                DoneCard(disc: disc)
                                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                            }
                        }
                        .animation(.spring(duration: 0.5, bounce: 0.35), value: doneOnes.map(\.id))
                        .padding(.horizontal, 12)
                    }
                    .frame(height: 50)
                }
            }
            .padding(.vertical, 10)
            .background(Theme.bg)
        }
    }

    // MARK: Lavoro

    private func prepara() async {
        openedAt = Date()
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            stato = "ACCESSO NEGATO · IMPOSTAZIONI › FOTOCAMERA"
            return
        }
        let pronto = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            motore.avvia { ok in c.resume(returning: ok) }
        }
        guard pronto else {
            let motivo = motore.motivo
            stato = motivo.isEmpty ? "FOTOCAMERA NON DISPONIBILE" : "FOTOCAMERA NON DISPONIBILE · \(motivo)"
            // appena si libera (l'altra app lascia la fotocamera) si aggancia da sola, per un minuto
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                if motore.sessione.isRunning { break }
            }
            guard motore.sessione.isRunning else { return }
            agganciato = true
            Suoni.avvio()
            stato = "INQUADRA UN DISCO"
            return
        }
        agganciato = true
        Suoni.avvio()
        stato = "INQUADRA UN DISCO"
    }

    private func scatta() {
        guard agganciato, !registrando else { return }
        Suoni.tocco()
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        withAnimation(.easeOut(duration: 0.06)) { lampo = true }
        withAnimation(.easeIn(duration: 0.45).delay(0.06)) { lampo = false }
        stato = "ANALISI"
        motore.scatta { dati in
          // V57: foto intera, alla qualità piena (niente più ritaglio automatico)
          DispatchQueue.global(qos: .userInitiated).async {
            let image = dati.flatMap { OcchioView.riduci($0) }.flatMap(UIImage.init(data:))
            Task { @MainActor in
                guard let image else { stato = "SCATTO NON RIUSCITO · RIPROVA"; return }
                if let target = attachTo {
                    seller.addPhoto(image, to: target, context: context)
                    attachTo = nil
                } else {
                    seller.shoot([image], video: false, place: place, media: media, sleeve: sleeve, context: context)
                }
                if stato == "ANALISI" { stato = "INQUADRA UN DISCO" }
            }
          }
        }
    }

    private func registra() {
        guard agganciato, !registrando else { return }
        Suoni.tocco()
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        inizioVideo = Date()
        registrando = true
        stato = "PASSA I DISCHI DAVANTI · TOCCA PER FERMARE"
        motore.registra(max: OcchioView.maxVideo) { url in
            Task { @MainActor in
                registrando = false
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                guard let url else { stato = "VIDEO NON RIUSCITO · RIPROVA"; return }
                preparo = true
                stato = "ANALISI DEL VIDEO"
                let frames = await OcchioView.fotogrammi(url)
                preparo = false
                if !frames.isEmpty {
                    seller.shoot(frames, video: true, place: place, media: media, sleeve: sleeve, context: context)
                }
                stato = "INQUADRA UN DISCO"
            }
        }
    }

    /// Fotogrammi distribuiti su tutto il video (8; 3 se il video è cortissimo).
    static func fotogrammi(_ url: URL, quanti: Int = 8) async -> [UIImage] {
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        guard let durata = try? await asset.load(.duration), durata.seconds > 0 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 1280)
        let tolleranza = CMTime(seconds: 0.15, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolleranza
        gen.requestedTimeToleranceAfter = tolleranza
        let n = durata.seconds < 2 ? 3 : quanti
        var out: [UIImage] = []
        for k in 0..<n {
            let t = CMTime(seconds: durata.seconds * (Double(k) + 0.5) / Double(n), preferredTimescale: 600)
            if let frame = try? await gen.image(at: t) { out.append(UIImage(cgImage: frame.image)) }
        }
        return out
    }

    /// Lato massimo 1600 px, JPEG all'80%, raddrizzata secondo l'orientamento del telefono.
    nonisolated static func riduci(_ dati: Data, lato: Int = 1600) -> Data? {
        guard let sorgente = CGImageSourceCreateWithData(dati as CFData, nil) else { return nil }
        let opzioni: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: lato,
        ]
        guard let piccola = CGImageSourceCreateThumbnailAtIndex(sorgente, 0, opzioni as CFDictionary) else { return nil }
        let uscita = NSMutableData()
        guard let destinazione = CGImageDestinationCreateWithData(uscita as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destinazione, piccola, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destinazione) else { return nil }
        return uscita as Data
    }
}

// MARK: - Mirino da HUD: angoli, reticolo che gira, riga di scansione

struct MirinoOcchio: View {
    let agganciato: Bool
    let scattando: Bool
    /// Sta riconoscendo un disco: la cornice si stringe sul disco e "aggancia".
    var analizzo = false
    /// Disco appena riconosciuto: la cornice si allarga un filo e si accende ("LOCK").
    var preso = false
    var tinta: Color = Theme.accent

    private var scala: CGFloat { analizzo ? 0.9 : (preso ? 1.03 : 1) }
    private var etichetta: String {
        if scattando { return "● REC" }
        if analizzo { return "AGGANCIO…" }
        if preso { return "● LOCK" }
        return agganciato ? "PRONTO" : "…"
    }

    var body: some View {
        GeometryReader { geo in
            let lato = min(geo.size.width, geo.size.height) * 0.78
            ZStack {
                TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    disegno(t: ctx.date.timeIntervalSinceReferenceDate)
                }
                .scaleEffect(scala)
                // le scritte sopra gli angoli della cornice
                HStack {
                    Text("AF · AUTO")
                    Spacer()
                    Text(etichetta).contentTransition(.opacity)
                }
                .font(Theme.mono(9, .bold)).tracking(1.5)
                .foregroundStyle((scattando ? Theme.warn : (preso ? Theme.glow : tinta)).opacity(0.85))
                .frame(width: lato * scala)
                .position(x: geo.size.width / 2, y: (geo.size.height - lato * scala) / 2 - 12)
            }
            .animation(.spring(duration: 0.45, bounce: 0.35), value: scala)
            .animation(.easeOut(duration: 0.2), value: etichetta)
        }
    }

    private func disegno(t: Double) -> some View {
        Canvas { gc, size in
            let w = Double(size.width), h = Double(size.height)
            let c = CGPoint(x: w / 2, y: h / 2)
            let lato = min(w, h) * 0.78
            let colore = scattando ? Theme.warn : (preso ? Theme.glow : tinta)
            let x0 = (w - lato) / 2, y0 = (h - lato) / 2
            let braccio = lato * 0.15
            let r = 10.0                                          // angoli arrotondati
            // respiro della luce: lento a riposo, veloce mentre aggancia
            let respiro = 0.5 + 0.5 * sin(t * (analizzo ? 9 : 2.6))

            var angoli = Path()
            for (ax, ay, dx, dy) in [(x0, y0, 1.0, 1.0), (x0 + lato, y0, -1.0, 1.0), (x0, y0 + lato, 1.0, -1.0), (x0 + lato, y0 + lato, -1.0, -1.0)] {
                angoli.move(to: CGPoint(x: ax, y: ay + dy * braccio))
                angoli.addLine(to: CGPoint(x: ax, y: ay + dy * r))
                angoli.addQuadCurve(to: CGPoint(x: ax + dx * r, y: ay), control: CGPoint(x: ax, y: ay))
                angoli.addLine(to: CGPoint(x: ax + dx * braccio, y: ay))
            }
            // alone dietro gli angoli
            var alone = gc
            alone.addFilter(.blur(radius: 4 + 5 * respiro))
            alone.stroke(angoli, with: .color(colore.opacity(0.35 + 0.45 * respiro)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            gc.stroke(angoli, with: .color(colore.opacity(0.95)), style: StrokeStyle(lineWidth: preso ? 3.5 : 3, lineCap: .round))

            // lati tratteggiati tra un angolo e l'altro
            var lati = Path()
            let gap = braccio + 14
            lati.move(to: CGPoint(x: x0 + gap, y: y0)); lati.addLine(to: CGPoint(x: x0 + lato - gap, y: y0))
            lati.move(to: CGPoint(x: x0 + gap, y: y0 + lato)); lati.addLine(to: CGPoint(x: x0 + lato - gap, y: y0 + lato))
            lati.move(to: CGPoint(x: x0, y: y0 + gap)); lati.addLine(to: CGPoint(x: x0, y: y0 + lato - gap))
            lati.move(to: CGPoint(x: x0 + lato, y: y0 + gap)); lati.addLine(to: CGPoint(x: x0 + lato, y: y0 + lato - gap))
            gc.stroke(lati, with: .color(colore.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))

            // anelli che girano attorno al centro (più veloci mentre aggancia)
            let giro = t * (analizzo ? 4.5 : (agganciato ? 0.8 : 2.4))
            for (raggio, verso, lung) in [(lato * 0.16, 1.0, 0.6), (lato * 0.21, -1.0, 0.35)] {
                var arco = Path()
                let inizio = Angle(radians: giro * verso)
                arco.addArc(center: c, radius: raggio, startAngle: inizio, endAngle: inizio + .radians(2 * .pi * lung), clockwise: false)
                gc.stroke(arco, with: .color(colore.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            // croce al centro: oscilla mentre aggancia
            let ang = analizzo ? sin(t * 10) * .pi / 8 : 0
            var croce = Path()
            for (dx, dy) in [(1.0, 0.0), (0.0, 1.0)] {
                let ex = dx * cos(ang) - dy * sin(ang), ey = dx * sin(ang) + dy * cos(ang)
                croce.move(to: CGPoint(x: c.x - 10 * ex, y: c.y - 10 * ey))
                croce.addLine(to: CGPoint(x: c.x + 10 * ex, y: c.y + 10 * ey))
            }
            gc.stroke(croce, with: .color(colore.opacity(0.9)), lineWidth: 1.5)

            // linea di scansione: veloce mentre aggancia
            let p = (t * (analizzo ? 1.6 : 0.55)).truncatingRemainder(dividingBy: 1)
            let y = y0 + lato * p
            gc.fill(Path(CGRect(x: x0, y: y - 1, width: lato, height: 2)), with: .color(colore.opacity(analizzo ? 0.9 : 0.55)))
            let scia = Path(CGRect(x: x0, y: max(y0, y - 40), width: lato, height: min(40, y - y0)))
            gc.fill(scia, with: .linearGradient(Gradient(colors: [colore.opacity(0), colore.opacity(analizzo ? 0.25 : 0.14)]),
                                                startPoint: CGPoint(x: 0, y: y - 40), endPoint: CGPoint(x: 0, y: y)))
            if analizzo {
                gc.fill(Path(CGRect(x: x0, y: y0, width: lato, height: lato)), with: .color(colore.opacity(0.04 + 0.04 * respiro)))
            }

            // tacche ai lati
            for k in 0..<12 {
                let ty = y0 + lato * Double(k) / 11
                var tacca = Path()
                tacca.move(to: CGPoint(x: x0 - 14, y: ty)); tacca.addLine(to: CGPoint(x: x0 - (k % 3 == 0 ? 4 : 8), y: ty))
                tacca.move(to: CGPoint(x: x0 + lato + 14, y: ty)); tacca.addLine(to: CGPoint(x: x0 + lato + (k % 3 == 0 ? 4 : 8), y: ty))
                gc.stroke(tacca, with: .color(colore.opacity(0.45)), lineWidth: 1)
            }
        }
    }
}

// MARK: - Anteprima della fotocamera

struct AnteprimaOcchio: UIViewRepresentable {
    let motore: MotoreOcchio

    /// L'anteprima, con sopra il riquadro verde della copertina trovata (come "Scansiona documenti").
    final class Vista: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var anteprima: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private let forma = CAShapeLayer()
        private var mancati = 0

        func prepara() {
            forma.strokeColor = UIColor(Theme.accent).cgColor
            forma.fillColor = UIColor(Theme.accent).withAlphaComponent(0.10).cgColor
            forma.lineWidth = 2.5
            forma.lineJoin = .round
            forma.shadowColor = UIColor(Theme.glow).cgColor
            forma.shadowRadius = 6
            forma.shadowOpacity = 0.8
            forma.shadowOffset = .zero
            forma.opacity = 0
            layer.addSublayer(forma)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            forma.frame = bounds
        }

        /// Angoli in coordinate della fotocamera (0…1); nil = in questo fotogramma non c'è.
        func disegna(_ punti: [CGPoint]?) {
            guard let punti, punti.count == 4 else {
                mancati += 1
                if mancati >= 3 { forma.opacity = 0 }        // sparisce solo se manca per un attimo (niente sfarfallio)
                return
            }
            mancati = 0
            let p = punti.map { anteprima.layerPointConverted(fromCaptureDevicePoint: $0) }
            let percorso = UIBezierPath()
            percorso.move(to: p[0])
            for q in p.dropFirst() { percorso.addLine(to: q) }
            percorso.close()
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            forma.path = percorso.cgPath
            forma.opacity = 1
            CATransaction.commit()
        }
    }

    func makeUIView(context: Context) -> Vista {
        let v = Vista()
        v.backgroundColor = .black
        v.anteprima.session = motore.sessione
        v.anteprima.videoGravity = .resizeAspectFill
        v.prepara()
        motore.suRiquadro = { [weak v] punti in
            DispatchQueue.main.async { v?.disegna(punti) }
        }
        return v
    }

    func updateUIView(_ v: Vista, context: Context) {}
}

// MARK: - Motore della fotocamera: foto e video veri (lavora su una coda sua, fuori dal thread principale)

final class MotoreOcchio: NSObject, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate,
                           AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let sessione = AVCaptureSession()
    private let foto = AVCapturePhotoOutput()
    private let video = AVCaptureMovieFileOutput()
    /// I fotogrammi dell'anteprima, per cercare la copertina dal vivo (riquadro verde nel mirino).
    private let fotogrammi = AVCaptureVideoDataOutput()
    private let codaRiquadro = DispatchQueue(label: "it.vinylhustler.app.riquadro")
    private var ultimoRiquadro = Date.distantPast
    /// Chi disegna il riquadro (l'anteprima). Riceve i 4 angoli in coordinate della fotocamera, o nil.
    var suRiquadro: (@Sendable ([CGPoint]?) -> Void)?
    private let coda = DispatchQueue(label: "it.vinylhustler.app.occhio")
    private var configurata = false
    private var consegnaFoto: (@Sendable (Data?) -> Void)?
    private var consegnaVideo: (@Sendable (URL?) -> Void)?
    private var cam: AVCaptureDevice?

    /// La fotocamera migliore che ha questo iPhone. Sui modelli con più obiettivi si usa quella "virtuale":
    /// passa da sola all'ultra-grandangolo in modalità macro quando avvicini il disco (etichette, numeri di catalogo).
    static func fotocameraMigliore() -> AVCaptureDevice? {
        let tipi: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
        for tipo in tipi {
            if let d = AVCaptureDevice.default(tipo, for: .video, position: .back) { return d }
        }
        return nil
    }

    /// Le foto alla risoluzione più alta che il telefono permette (12 o 48 megapixel, secondo il modello).
    private func massimaRisoluzione(_ cam: AVCaptureDevice) {
        let dims = cam.activeFormat.supportedMaxPhotoDimensions
        if let best = dims.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            foto.maxPhotoDimensions = best
        }
    }

    /// Messa a fuoco continua, preferendo le cose vicine; inquadratura normale (1x) sulle fotocamere virtuali.
    private func preparaMessaAFuoco(_ cam: AVCaptureDevice) {
        guard (try? cam.lockForConfiguration()) != nil else { return }
        if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
        if cam.isAutoFocusRangeRestrictionSupported { cam.autoFocusRangeRestriction = .near }
        if cam.isExposureModeSupported(.continuousAutoExposure) { cam.exposureMode = .continuousAutoExposure }
        // sulle virtuali lo zoom 1 è l'ultra-grandangolo: si parte dal grandangolo normale, come l'app Fotocamera
        if let uno = cam.virtualDeviceSwitchOverVideoZoomFactors.first {
            cam.videoZoomFactor = CGFloat(truncating: uno)
        }
        cam.unlockForConfiguration()
    }

    /// Cambia qualità della sessione (foto piena / video) e rimette tutto a posto.
    private func preset(_ p: AVCaptureSession.Preset) {
        guard sessione.sessionPreset != p, sessione.canSetSessionPreset(p) else { return }
        sessione.beginConfiguration()
        sessione.sessionPreset = p
        sessione.commitConfiguration()
        if let cam {
            massimaRisoluzione(cam)
            preparaMessaAFuoco(cam)
        }
        for output in [foto, video] as [AVCaptureOutput] {
            if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        }
    }

    func avvia(pronto: @escaping @Sendable (Bool) -> Void) {
        coda.async {
            self.osserva()
            if !self.configurata {
                // prima la fotocamera migliore a qualità foto piena; se non parte, quella semplice come prima della V22
                self.configurata = self.configura(migliore: true) || self.configura(migliore: false)
                guard self.configurata else { self.motivo = "CONFIGURAZIONE"; pronto(false); return }
            }
            // a volte la fotocamera è ancora occupata (un'altra app, la chiusura di prima): si riprova un paio di volte
            for tentativo in 0..<3 where !self.sessione.isRunning {
                if tentativo > 0 { Thread.sleep(forTimeInterval: 0.4) }
                self.sessione.startRunning()
            }
            if !self.sessione.isRunning, self.semplice == false {
                self.semplice = true                              // ultima prova: configurazione semplice
                if self.configura(migliore: false) { self.sessione.startRunning() }
            }
            if !self.sessione.isRunning, self.motivo.isEmpty { self.motivo = "NON PARTE" }
            if self.sessione.isRunning { self.motivo = "" }
            pronto(self.sessione.isRunning)
        }
    }

    private var semplice = false
    /// Perché la fotocamera non è partita (si mostra sotto il mirino, per capire il problema).
    private(set) var motivo = ""
    private var osservatori: [NSObjectProtocol] = []

    private func osserva() {
        guard osservatori.isEmpty else { return }
        let nc = NotificationCenter.default
        osservatori.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: sessione, queue: nil) { [weak self] n in
            let e = n.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.motivo = "ERRORE \(e?.code ?? 0)"
        })
        // finita l'interruzione (l'altra app ha lasciato la fotocamera) si riparte da soli
        osservatori.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: sessione, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.coda.async {
                if !self.sessione.isRunning { self.sessione.startRunning() }
                if self.sessione.isRunning { self.motivo = "" }
            }
        })
        osservatori.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: sessione, queue: nil) { [weak self] n in
            let raw = (n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? 0
            let testo: String
            switch AVCaptureSession.InterruptionReason(rawValue: raw) {
            case .videoDeviceInUseByAnotherClient: testo = "USATA DA UN'ALTRA APP"
            case .videoDeviceNotAvailableWithMultipleForegroundApps: testo = "CHIUDI VIDEO O FINESTRE MOBILI"
            case .videoDeviceNotAvailableDueToSystemPressure: testo = "TELEFONO TROPPO CALDO"
            case .videoDeviceNotAvailableInBackground: testo = "APP IN SECONDO PIANO"
            case .audioDeviceInUseByAnotherClient: testo = "AUDIO OCCUPATO"
            default: testo = "INTERROTTA (\(raw))"
            }
            self?.motivo = testo
        })
    }

    /// Monta la sessione. migliore = fotocamera virtuale (macro automatica) a qualità foto piena;
    /// altrimenti grandangolo normale a qualità .high, come nelle prime versioni.
    private func configura(migliore: Bool) -> Bool {
        sessione.beginConfiguration()
        sessione.inputs.forEach { sessione.removeInput($0) }
        sessione.outputs.forEach { sessione.removeOutput($0) }
        // Niente fotocamera condivisa con altre app (V50): se c'è una videochiamata in corso,
        // Vinyl Hustler non tiene la fotocamera quando non è lui in primo piano.
        if sessione.isMultitaskingCameraAccessSupported { sessione.isMultitaskingCameraAccessEnabled = false }
        let preset: AVCaptureSession.Preset = migliore && sessione.canSetSessionPreset(.photo) ? .photo : .high
        sessione.sessionPreset = preset
        let device = migliore ? Self.fotocameraMigliore()
                              : AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let cam = device, let ingresso = try? AVCaptureDeviceInput(device: cam),
              sessione.canAddInput(ingresso) else { sessione.commitConfiguration(); return false }
        sessione.addInput(ingresso)
        guard sessione.canAddOutput(foto) else { sessione.commitConfiguration(); return false }
        sessione.addOutput(foto)
        if sessione.canAddOutput(video) { sessione.addOutput(video) }
        // V57: tolto il riquadro verde dal vivo (inventava rombi e forme che saltavano): niente analisi dei fotogrammi
        for output in [foto, video] as [AVCaptureOutput] {   // verticale, come tieni il telefono
            if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        }
        foto.maxPhotoQualityPrioritization = .quality      // elaborazione Apple piena (Deep Fusion / HDR)
        sessione.commitConfiguration()
        massimaRisoluzione(cam)
        preparaMessaAFuoco(cam)
        self.cam = cam
        semplice = !migliore
        return true
    }

    func ferma() {
        coda.async {
            if self.video.isRecording { self.video.stopRecording() }
            if self.sessione.isRunning { self.sessione.stopRunning() }
        }
    }

    func scatta(_ fine: @escaping @Sendable (Data?) -> Void) {
        coda.async {
            guard self.sessione.isRunning, self.consegnaFoto == nil else { fine(nil); return }
            self.consegnaFoto = fine
            let impostazioni = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            impostazioni.maxPhotoDimensions = self.foto.maxPhotoDimensions
            impostazioni.photoQualityPrioritization = .quality
            self.foto.capturePhoto(with: impostazioni, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        let dati = error == nil ? photo.fileDataRepresentation() : nil
        coda.async {
            let f = self.consegnaFoto
            self.consegnaFoto = nil
            f?(dati)
        }
    }

    /// Un fotogramma dell'anteprima: al massimo ~7 al secondo si cerca la copertina.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let ora = Date()
        guard ora.timeIntervalSince(ultimoRiquadro) > 0.14, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        ultimoRiquadro = ora
        suRiquadro?(Ritaglio.riquadro(in: buffer))
    }

    /// Video vero, senza audio. Si ferma con fermaVideo() o da solo dopo `max` secondi.
    func registra(max: Double, _ fine: @escaping @Sendable (URL?) -> Void) {
        coda.async {
            guard self.sessione.isRunning, !self.video.isRecording,
                  self.sessione.outputs.contains(self.video) else { fine(nil); return }
            self.consegnaVideo = fine
            // video e fotogrammi insieme non vanno d'accordo su tutti gli iPhone: durante il REC niente riquadro
            if self.sessione.outputs.contains(self.fotogrammi) {
                self.sessione.beginConfiguration()
                self.sessione.removeOutput(self.fotogrammi)
                self.sessione.commitConfiguration()
            }
            self.suRiquadro?(nil)
            self.preset(.high)                              // il video a qualità video (file leggero)
            self.video.maxRecordedDuration = CMTime(seconds: max, preferredTimescale: 600)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
            self.video.startRecording(to: url, recordingDelegate: self)
        }
    }

    func fermaVideo() {
        coda.async { if self.video.isRecording { self.video.stopRecording() } }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: (any Error)?) {
        // Arrivato al tempo massimo l'errore c'è, ma il file è buono.
        let finito = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool
        let ok = error == nil || finito == true
        coda.async {
            self.preset(.photo)                             // finito il REC si torna alla qualità foto piena
            let f = self.consegnaVideo
            self.consegnaVideo = nil
            f?(ok ? url : nil)
        }
    }
}

/// Un disco della serie già messo su Discogs: piccolo e in fila, con la spunta, per lasciare spazio al prossimo.
struct DoneCard: View {
    @Environment(Seller.self) private var seller
    let disc: Disc

    var body: some View {
        HStack(spacing: 8) {
            AsyncImage(url: disc.coverURL) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                .frame(width: 30, height: 30)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.money, lineWidth: 1.5))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.black, Theme.money)
                        .offset(x: 3, y: 3)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(disc.releaseTitle).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Group {
                    if disc.status == .bozza {
                        Text("Bozza").foregroundStyle(Theme.warn)
                    } else if let p = disc.price {
                        Text(p, format: .currency(code: seller.currency)).foregroundStyle(Theme.money)
                    } else {
                        Text("Online").foregroundStyle(Theme.money)
                    }
                }
                .font(.system(size: 11, weight: .bold))
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 150, height: 50, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
