import AVFoundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// OCCHIO — la modalità "occhi" di JARVIS portata in Vinyl Hustler.
/// Fotocamera dal vivo con mirino da HUD:
///   · tasto occhio: una foto (va nel primo riquadro libero della sessione);
///   · tasto REC (giro): 5 secondi mentre si gira il disco davanti al telefono — copertina, retro,
///     centrini, matrice — e 4 fotogrammi ben distanziati che partono subito per il riconoscimento.
/// Le foto escono già ridotte (lato 1280 px, 1024 nel giro) e raddrizzate.
struct OcchioView: View {
    /// Le foto scattate: una, oppure i fotogrammi del giro. Vuoto = chiuso senza scattare.
    let fine: ([Data]) -> Void

    static let durataGiro = 5.0
    static let fotogrammiGiro = 4

    @State private var motore = MotoreOcchio()
    @State private var stato = "AGGANCIO OTTICO"
    @State private var lampo = false
    @State private var scattando = false
    @State private var chiuso = false
    @State private var agganciato = false
    @State private var registrando = false
    @State private var mancano = 5

    private let tinta = Theme.accent

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AnteprimaOcchio(sessione: motore.sessione)
                .ignoresSafeArea()
                .opacity(agganciato ? 1 : 0)
                .animation(.easeOut(duration: 0.4), value: agganciato)
            MirinoOcchio(agganciato: agganciato, scattando: scattando || registrando, tinta: tinta)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            if registrando {
                VStack {
                    HStack(spacing: 8) {
                        Circle().fill(Color.red).frame(width: 10, height: 10).shadow(color: .red, radius: 6)
                        Text("REC · \(mancano)")
                            .font(Theme.mono(14, .bold)).tracking(3).foregroundStyle(.white)
                            .contentTransition(.numericText(countsDown: true))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Capsule())
                    .padding(.top, 70)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            Color.white.opacity(lampo ? 0.85 : 0).ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VINYL HUSTLER").font(Theme.mono(15, .bold)).tracking(4)
                        Text(registrando ? "OCCHIO · GIRO" : "OCCHIO").font(Theme.mono(9)).tracking(2).opacity(0.7)
                    }
                    .foregroundStyle(tinta)
                    .shadow(color: tinta.opacity(0.6), radius: 6)
                    Spacer()
                    Button { chiudi([]) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(tinta)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.4))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(tinta.opacity(0.5), lineWidth: 1))
                    }
                    .accessibilityLabel("Chiudi")
                }
                Spacer()
                Text(stato)
                    .font(Theme.mono(12, .semibold)).tracking(3)
                    .foregroundStyle(tinta)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Capsule())
                    .contentTransition(.opacity)
                HStack(spacing: 40) {
                    Button { scatta() } label: {
                        ZStack {
                            Circle().stroke(tinta, lineWidth: 3).frame(width: 74, height: 74)
                            Circle().fill(tinta.opacity(scattando ? 0.9 : 0.25)).frame(width: 60, height: 60)
                            Image(systemName: "eye").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                        }
                        .shadow(color: tinta.opacity(0.7), radius: 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(!agganciato || scattando || registrando)
                    .accessibilityLabel("Scatta una foto")
                    Button { Task { await giro() } } label: {
                        ZStack {
                            Circle().stroke(Color.red.opacity(0.85), lineWidth: 2).frame(width: 60, height: 60)
                            Text("REC").font(Theme.mono(13, .bold)).foregroundStyle(.white)
                        }
                        .shadow(color: .red.opacity(0.5), radius: 8)
                    }
                    .buttonStyle(.plain)
                    .disabled(!agganciato || scattando || registrando)
                    .accessibilityLabel("Giro di cinque secondi")
                }
                Text("OCCHIO = UNA FOTO · REC = GIRA IL DISCO PER 5 SECONDI")
                    .font(Theme.mono(9, .semibold)).tracking(1.2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .statusBarHidden()
        .task { await prepara() }
        .onDisappear { motore.ferma() }
    }

    // MARK: Lavoro

    private func prepara() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            stato = "ACCESSO NEGATO · IMPOSTAZIONI › FOTOCAMERA"
            try? await Task.sleep(for: .seconds(2.5))
            chiudi([])
            return
        }
        let pronto = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            motore.avvia { ok in c.resume(returning: ok) }
        }
        guard pronto else {
            stato = "FOTOCAMERA NON DISPONIBILE"
            try? await Task.sleep(for: .seconds(2))
            chiudi([])
            return
        }
        agganciato = true
        stato = "INQUADRI IL DISCO"
    }

    private func scatta() {
        guard agganciato, !scattando, !chiuso else { return }
        scattando = true
        stato = "ACQUISIZIONE"
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        withAnimation(.easeOut(duration: 0.06)) { lampo = true }
        withAnimation(.easeIn(duration: 0.45).delay(0.06)) { lampo = false }
        motore.scatta(veloce: false) { dati in
            let jpeg = dati.flatMap { OcchioView.riduci($0) }
            Task { @MainActor in chiudi(jpeg.map { [$0] } ?? []) }
        }
    }

    /// Il giro: 5 secondi, 4 fotogrammi distribuiti nel tempo, poi si chiude da solo.
    private func giro() async {
        guard agganciato, !scattando, !registrando, !chiuso else { return }
        registrando = true
        stato = "GIRI IL DISCO DAVANTI AL TELEFONO"
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        let inizio = Date()
        let passo = OcchioView.durataGiro / Double(OcchioView.fotogrammiGiro)
        var fotogrammi: [Data] = []
        let conto = Task { @MainActor in
            for s in stride(from: Int(OcchioView.durataGiro), through: 1, by: -1) {
                withAnimation { mancano = s }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        for k in 0..<OcchioView.fotogrammiGiro {
            let quando = passo * (Double(k) + 0.4)               // 0,5 · 1,75 · 3 · 4,25 secondi
            let attesa = quando - Date().timeIntervalSince(inizio)
            if attesa > 0 { try? await Task.sleep(for: .seconds(attesa)) }
            guard !chiuso else { conto.cancel(); return }
            let dati = await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
                motore.scatta(veloce: true) { d in c.resume(returning: d) }
            }
            if let dati, let jpeg = OcchioView.riduci(dati, lato: 1024) { fotogrammi.append(jpeg) }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        let resto = OcchioView.durataGiro - Date().timeIntervalSince(inizio)
        if resto > 0 { try? await Task.sleep(for: .seconds(resto)) }
        conto.cancel()
        guard !chiuso else { return }
        registrando = false
        stato = "ANALISI"
        chiudi(fotogrammi)
    }

    private func chiudi(_ dati: [Data]) {
        guard !chiuso else { return }
        chiuso = true
        motore.ferma()
        fine(dati)
    }

    /// Lato massimo 1280 px (1024 nel giro), JPEG al 70%, raddrizzata secondo l'orientamento del telefono.
    nonisolated static func riduci(_ dati: Data, lato: Int = 1280) -> Data? {
        guard let sorgente = CGImageSourceCreateWithData(dati as CFData, nil) else { return nil }
        let opzioni: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: lato,
        ]
        guard let piccola = CGImageSourceCreateThumbnailAtIndex(sorgente, 0, opzioni as CFDictionary) else { return nil }
        let uscita = NSMutableData()
        guard let destinazione = CGImageDestinationCreateWithData(uscita as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destinazione, piccola, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
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

// MARK: - Motore della fotocamera (lavora su una coda sua, fuori dal thread principale)

final class MotoreOcchio: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let sessione = AVCaptureSession()
    private let uscita = AVCapturePhotoOutput()
    private let coda = DispatchQueue(label: "it.vinylhustler.app.occhio")
    private var configurata = false
    private var consegna: (@Sendable (Data?) -> Void)?

    func avvia(pronto: @escaping @Sendable (Bool) -> Void) {
        coda.async {
            if !self.configurata {
                self.sessione.beginConfiguration()
                self.sessione.sessionPreset = .photo
                guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let ingresso = try? AVCaptureDeviceInput(device: cam),
                      self.sessione.canAddInput(ingresso) else {
                    self.sessione.commitConfiguration()
                    pronto(false)
                    return
                }
                self.sessione.addInput(ingresso)
                guard self.sessione.canAddOutput(self.uscita) else {
                    self.sessione.commitConfiguration()
                    pronto(false)
                    return
                }
                self.sessione.addOutput(self.uscita)
                self.sessione.commitConfiguration()
                if cam.isFocusModeSupported(.continuousAutoFocus), (try? cam.lockForConfiguration()) != nil {
                    cam.focusMode = .continuousAutoFocus
                    cam.unlockForConfiguration()
                }
                self.configurata = true
            }
            if !self.sessione.isRunning { self.sessione.startRunning() }
            pronto(self.sessione.isRunning)
        }
    }

    func ferma() {
        coda.async { if self.sessione.isRunning { self.sessione.stopRunning() } }
    }

    /// veloce: per i fotogrammi del giro, scatto immediato senza elaborazioni pesanti.
    func scatta(veloce: Bool, _ fine: @escaping @Sendable (Data?) -> Void) {
        coda.async {
            guard self.sessione.isRunning, self.consegna == nil else { fine(nil); return }
            self.consegna = fine
            let impostazioni = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            if veloce { impostazioni.photoQualityPrioritization = .speed }
            self.uscita.capturePhoto(with: impostazioni, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        let dati = error == nil ? photo.fileDataRepresentation() : nil
        coda.async {
            let f = self.consegna
            self.consegna = nil
            f?(dati)
        }
    }
}
