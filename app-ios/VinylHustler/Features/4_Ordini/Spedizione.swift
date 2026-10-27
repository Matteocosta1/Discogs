import AVFoundation
import SwiftUI
import UIKit

/// V60 — SPEDIZIONE: si inquadra il codice a barre della ricevuta, il numero si scrive da solo,
/// si sceglie il corriere, si vede il messaggio che riceverà l'acquirente e con «Spedisci e avvisa»
/// l'ordine diventa «Shipped» su Discogs (stato e messaggio partono insieme).
/// Usa la fotocamera: si chiude con la X nel cerchio (regola di JARVIS).
struct SpedizioneSheet: View {
    let order: Order
    /// Chiamata solo quando Discogs ha accettato: l'ordine è davvero spedito.
    let onSpedito: () -> Void

    @Environment(Seller.self) private var seller
    @Environment(\.dismiss) private var dismiss
    @State private var corriere: Corriere = .poste
    @State private var tracking = ""
    @State private var letto = false
    @State private var giro = 0                 // cambia per rileggere: la fotocamera riparte da capo
    @State private var invio = false
    @State private var errore: String?
    @State private var aperta = Date()

    private var codice: String { Corriere.pulisci(tracking) }
    private var link: String { corriere.link(codice) }
    private var testo: String {
        "Ciao \(order.buyer.username), il tuo ordine è partito!\nCorriere: \(corriere.nome)\nTracking: \(codice.isEmpty ? "…" : codice)"
            + (codice.isEmpty ? "" : "\n\(link)") + "\nGrazie e buon ascolto!"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("SPEDIZIONE").font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow)
                    Spacer()
                    Button { Suoni.testa(); dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.accent)
                            .frame(width: 36, height: 36)
                            .background(Color.black.opacity(0.45), in: Circle())
                            .overlay(Circle().stroke(Theme.accent.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Chiudi")
                }

                mirino

                Text(letto ? "LETTO · \(corriere.nome.uppercased()) · \(codice)" : "INQUADRA IL CODICE A BARRE DELLA RICEVUTA")
                    .font(Theme.mono(9.5, .bold)).tracking(1.2).foregroundStyle(Theme.glow)
                    .lineLimit(2)

                campo("CORRIERE") {
                    Picker("Corriere", selection: $corriere) {
                        ForEach(Corriere.allCases) { c in Text(c.nome).tag(c) }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .frame(height: 42)
                    .background(Theme.panelHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                campo("TRACKING") {
                    TextField("Si scrive da solo dalla foto", text: $tracking)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(size: 16))
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(Theme.panelHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                campo("MESSAGGIO ALL'ACQUIRENTE") {
                    Text(testo)
                        .font(.system(size: 13)).foregroundStyle(Color(red: 0.85, green: 0.96, blue: 0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Theme.glow.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }

                if let errore {
                    Text(errore).font(.system(size: 13)).foregroundStyle(Theme.warn)
                }

                Button(action: spedisci) {
                    HStack(spacing: 8) {
                        if invio { ProgressView().tint(.black) }
                        Text(invio ? "Invio a Discogs…" : "Spedisci e avvisa").font(.system(size: 16, weight: .bold))
                    }
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(codice.isEmpty || invio)
                .opacity(codice.isEmpty || invio ? 0.4 : 1)
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 26)
        }
        .background(Color(red: 0.043, green: 0.059, blue: 0.047))
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .interactiveDismissDisabled(invio)
        .onAppear { aperta = Date(); Suoni.camera() }
    }

    /// Il mirino piccolo: la fotocamera, la riga verde che scende finché non legge, poi il riquadro acceso.
    private var mirino: some View {
        ZStack {
            LettoreCodici(letto: { valore in
                let c = Corriere.pulisci(valore)
                guard !c.isEmpty else { return }
                tracking = c
                if let r = Corriere.riconosci(c) { corriere = r }
                letto = true
                Suoni.schedaPronta()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            })
            .id(giro)

            if letto {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.glow, lineWidth: 2)
                    .shadow(color: Theme.glow.opacity(0.5), radius: 7)
                    .padding(.horizontal, 60).padding(.vertical, 16)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 120)) { ctx in
                    let p = ctx.date.timeIntervalSince(aperta).truncatingRemainder(dividingBy: 0.9) / 0.9
                    GeometryReader { g in
                        Rectangle().fill(Theme.glow)
                            .frame(width: g.size.width * 0.64, height: 2)
                            .shadow(color: Theme.glow, radius: 5)
                            .position(x: g.size.width / 2, y: 18 + p * (g.size.height - 36))
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            // già letto: un tocco per rileggere un altro codice
            guard letto else { return }
            Suoni.tocco()
            letto = false
            aperta = Date()
            giro += 1
        }
        .accessibilityLabel(letto ? "Codice letto: tocca per rileggere" : "Fotocamera per il codice a barre")
    }

    private func campo<C: View>(_ titolo: String, @ViewBuilder _ contenuto: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(titolo).font(Theme.mono(9, .bold)).tracking(1.5).foregroundStyle(Theme.muted)
            contenuto()
        }
    }

    private func spedisci() {
        let numero = codice
        guard !numero.isEmpty, !invio else { return }
        invio = true
        errore = nil
        Suoni.tocco()
        let messaggio = testo
        let id = order.id
        let client = seller.client
        Task { @MainActor in
            do {
                // stato e messaggio insieme: l'acquirente riceve «Spedito» con il tracking
                try await client.postOrderMessage(id, message: messaggio, status: "Shipped")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                invio = false
                dismiss()
                onSpedito()
            } catch {
                invio = false
                Suoni.nego()
                errore = "Non spedito: " + error.localizedDescription
            }
        }
    }
}

/// I corrieri, con il link per seguire il pacco (come nel mock-up).
enum Corriere: String, CaseIterable, Identifiable, Hashable {
    case poste, brt, gls, sda, dhl, ups

    var id: String { rawValue }

    var nome: String {
        switch self {
        case .poste: return "Poste Italiane"
        case .brt: return "BRT"
        case .gls: return "GLS"
        case .sda: return "SDA"
        case .dhl: return "DHL"
        case .ups: return "UPS"
        }
    }

    func link(_ codice: String) -> String {
        switch self {
        case .poste: return "https://www.poste.it/cerca/#/risultati-spedizioni/" + codice
        case .brt: return "https://vas.brt.it/vas/sped_det_show.hsm?referer=sped_numspe_par.htm&Nspediz=" + codice
        case .gls: return "https://www.gls-italy.com/it/servizi-online/ricerca-spedizioni?match=" + codice
        case .sda: return "https://www.sda.it/wps/portal/Servizi_online/dettaglio-spedizione?locale=it&tracing.letteraVettura=" + codice
        case .dhl: return "https://www.dhl.com/it-it/home/tracking.html?tracking-id=" + codice
        case .ups: return "https://www.ups.com/track?tracknum=" + codice
        }
    }

    /// Solo lettere e cifre, in maiuscolo (il codice letto può avere spazi).
    static func pulisci(_ s: String) -> String {
        String(s.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map { Character($0) })
    }

    /// Il corriere quando il formato non lascia dubbi; altrimenti nil (resta quello scelto).
    static func riconosci(_ codice: String) -> Corriere? {
        let c = pulisci(codice)
        // formato postale internazionale: 2 lettere, 9 cifre, 2 lettere del paese (…IT = Poste Italiane)
        if c.range(of: "^[A-Z]{2}[0-9]{9}IT$", options: .regularExpression) != nil { return .poste }
        if c.hasPrefix("1Z") && c.count == 18 { return .ups }
        if c.hasPrefix("JJD") || c.hasPrefix("JVGL") { return .dhl }
        return nil
    }
}

/// La fotocamera che legge i codici a barre (AVFoundation, sul telefono, gratis).
struct LettoreCodici: UIViewRepresentable {
    let letto: (String) -> Void

    final class Vista: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var anteprima: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let sessione = AVCaptureSession()
        var letto: (String) -> Void = { _ in }
        private var fatto = false
        private let coda = DispatchQueue(label: "it.vinylhustler.codici")

        func avvia() {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configura()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { ok in if ok { self.configura() } }
            default:
                break
            }
        }

        private func configura() {
            coda.async {
                let s = self.sessione
                s.beginConfiguration()
                if s.inputs.isEmpty,
                   let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: camera), s.canAddInput(input) {
                    s.addInput(input)
                }
                if s.outputs.isEmpty {
                    let out = AVCaptureMetadataOutput()
                    if s.canAddOutput(out) {
                        s.addOutput(out)
                        out.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                        let voluti: [AVMetadataObject.ObjectType] = [.code128, .code39, .code93, .ean13, .ean8, .interleaved2of5,
                                                                     .itf14, .upce, .qr, .dataMatrix, .pdf417, .aztec]
                        out.metadataObjectTypes = voluti.filter { out.availableMetadataObjectTypes.contains($0) }
                    }
                }
                s.commitConfiguration()
                if !s.isRunning { s.startRunning() }
            }
        }

        func ferma() {
            coda.async {
                if self.sessione.isRunning { self.sessione.stopRunning() }
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !fatto else { return }
            for oggetto in metadataObjects {
                guard let codice = oggetto as? AVMetadataMachineReadableCodeObject,
                      let valore = codice.stringValue, valore.count >= 6 else { continue }
                fatto = true
                letto(valore)
                ferma()
                return
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Vista {
        let v = Vista()
        v.backgroundColor = .black
        v.anteprima.session = context.coordinator.sessione
        v.anteprima.videoGravity = .resizeAspectFill
        context.coordinator.letto = letto
        context.coordinator.avvia()
        return v
    }

    func updateUIView(_ uiView: Vista, context: Context) {
        context.coordinator.letto = letto
    }

    static func dismantleUIView(_ uiView: Vista, coordinator: Coordinator) {
        coordinator.ferma()
    }
}
