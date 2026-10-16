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
    @State private var motore = MotoreOcchio()
    @State private var openedAt = Date()
    @State private var stato = "AGGANCIO OTTICO"
    @State private var lampo = false
    @State private var agganciato = false
    @State private var registrando = false
    @State private var inizioVideo = Date()
    @State private var preparo = false
    @State private var attachTo: Disc?              // "Altra foto": il prossimo scatto va a questo disco

    private let tinta = Theme.accent

    /// I dischi fotografati da quando hai aperto la fotocamera (il più recente prima).
    private var seen: [Disc] {
        all.filter { $0.createdAt >= openedAt && $0.status != .tolto && !$0.parked }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                AnteprimaOcchio(sessione: motore.sessione)
                    .opacity(agganciato ? 1 : 0)
                    .animation(.easeOut(duration: 0.4), value: agganciato)
                MirinoOcchio(agganciato: agganciato, scattando: registrando, tinta: tinta)
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
                    Circle().stroke(tinta, lineWidth: 4).frame(width: 82, height: 82)
                    Circle().fill(tinta).frame(width: 66, height: 66)
                    Image(systemName: "camera.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(Color.black)
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

    /// I dischi riconosciuti, sotto la fotocamera: sì / no, poi vendita.
    @ViewBuilder private var results: some View {
        if !seen.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(seen) { disc in
                        DiscRow(disc: disc, onRetake: { attachTo = disc })
                            .frame(width: 320)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                    removal: .opacity))
                    }
                }
                .animation(.spring(duration: 0.45, bounce: 0.25), value: seen.map(\.id))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(height: 210)
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
            stato = "FOTOCAMERA NON DISPONIBILE"
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
            let image = dati.flatMap { OcchioView.riduci($0) }.flatMap(UIImage.init(data:))
            Task { @MainActor in
                guard let image else { stato = "SCATTO NON RIUSCITO · RIPROVA"; return }
                if let target = attachTo {
                    seller.addPhoto(image, to: target, context: context)
                    attachTo = nil
                } else {
                    seller.shoot([image], video: false, place: place, media: media, sleeve: sleeve, context: context)
                }
                stato = "INQUADRA UN DISCO"
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
    var tinta: Color = Theme.accent

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                let w = Double(size.width), h = Double(size.height)
                let c = CGPoint(x: w / 2, y: h / 2)
                let lato = min(w, h) * 0.78
                let colore = scattando ? Theme.warn : tinta
                let x0 = (w - lato) / 2, y0 = (h - lato) / 2
                let braccio = lato * 0.12

                var angoli = Path()
                for (ax, ay, dx, dy) in [(x0, y0, 1.0, 1.0), (x0 + lato, y0, -1.0, 1.0), (x0, y0 + lato, 1.0, -1.0), (x0 + lato, y0 + lato, -1.0, -1.0)] {
                    angoli.move(to: CGPoint(x: ax, y: ay + dy * braccio))
                    angoli.addLine(to: CGPoint(x: ax, y: ay))
                    angoli.addLine(to: CGPoint(x: ax + dx * braccio, y: ay))
                }
                gc.stroke(angoli, with: .color(colore.opacity(0.9)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

                let giro = t * (agganciato ? 0.8 : 2.4)
                for (r, verso, lung) in [(lato * 0.16, 1.0, 0.6), (lato * 0.21, -1.0, 0.35)] {
                    var arco = Path()
                    let inizio = Angle(radians: giro * verso)
                    arco.addArc(center: c, radius: r, startAngle: inizio, endAngle: inizio + .radians(2 * .pi * lung), clockwise: false)
                    gc.stroke(arco, with: .color(colore.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
                var croce = Path()
                croce.move(to: CGPoint(x: c.x - 8, y: c.y)); croce.addLine(to: CGPoint(x: c.x + 8, y: c.y))
                croce.move(to: CGPoint(x: c.x, y: c.y - 8)); croce.addLine(to: CGPoint(x: c.x, y: c.y + 8))
                gc.stroke(croce, with: .color(colore.opacity(0.8)), lineWidth: 1)

                let p = (t * 0.55).truncatingRemainder(dividingBy: 1)
                let y = y0 + lato * p
                gc.fill(Path(CGRect(x: x0, y: y - 1, width: lato, height: 2)), with: .color(colore.opacity(0.55)))
                let scia = Path(CGRect(x: x0, y: max(y0, y - 40), width: lato, height: min(40, y - y0)))
                gc.fill(scia, with: .linearGradient(Gradient(colors: [colore.opacity(0), colore.opacity(0.14)]),
                                                    startPoint: CGPoint(x: 0, y: y - 40), endPoint: CGPoint(x: 0, y: y)))

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
}

// MARK: - Anteprima della fotocamera

struct AnteprimaOcchio: UIViewRepresentable {
    let sessione: AVCaptureSession

    final class Vista: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var anteprima: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> Vista {
        let v = Vista()
        v.backgroundColor = .black
        v.anteprima.session = sessione
        v.anteprima.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ v: Vista, context: Context) {}
}

// MARK: - Motore della fotocamera: foto e video veri (lavora su una coda sua, fuori dal thread principale)

final class MotoreOcchio: NSObject, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let sessione = AVCaptureSession()
    private let foto = AVCapturePhotoOutput()
    private let video = AVCaptureMovieFileOutput()
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
            if !self.configurata {
                self.sessione.beginConfiguration()
                // Qualità FOTO piena del telefono (come l'app Fotocamera). Il REC passa a .high solo mentre registra.
                self.sessione.sessionPreset = self.sessione.canSetSessionPreset(.photo) ? .photo : .high
                guard let cam = Self.fotocameraMigliore(),
                      let ingresso = try? AVCaptureDeviceInput(device: cam),
                      self.sessione.canAddInput(ingresso),
                      self.sessione.canAddOutput(self.foto) else {
                    self.sessione.commitConfiguration()
                    pronto(false)
                    return
                }
                self.sessione.addInput(ingresso)
                self.sessione.addOutput(self.foto)
                if self.sessione.canAddOutput(self.video) { self.sessione.addOutput(self.video) }
                for output in [self.foto, self.video] as [AVCaptureOutput] {   // verticale, come tieni il telefono
                    if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
                }
                self.foto.maxPhotoQualityPrioritization = .quality   // elaborazione Apple piena (Deep Fusion / HDR)
                self.sessione.commitConfiguration()
                self.massimaRisoluzione(cam)
                self.preparaMessaAFuoco(cam)
                self.cam = cam
                self.configurata = true
            }
            if !self.sessione.isRunning { self.sessione.startRunning() }
            pronto(self.sessione.isRunning)
        }
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

    /// Video vero, senza audio. Si ferma con fermaVideo() o da solo dopo `max` secondi.
    func registra(max: Double, _ fine: @escaping @Sendable (URL?) -> Void) {
        coda.async {
            guard self.sessione.isRunning, !self.video.isRecording,
                  self.sessione.outputs.contains(self.video) else { fine(nil); return }
            self.consegnaVideo = fine
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
