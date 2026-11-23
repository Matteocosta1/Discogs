import AVFoundation
import SwiftUI
import UIKit

/// V60 — SPEDIZIONE. V79 (come nel mock-up): solo le informazioni di spedizione: corriere, tracking con il suo link
/// e il messaggio all'acquirente, che si scrive da solo e si può modificare. Con «Spedisci e avvisa» l'ordine
/// diventa «Shipped» su Discogs (stato e messaggio partono insieme). Niente più fotocamera: si chiude con «Chiudi».
struct SpedizioneSheet: View {
    let order: Order
    /// Chiamata solo quando Discogs ha accettato: l'ordine è davvero spedito.
    let onSpedito: () -> Void

    @Environment(Seller.self) private var seller
    @Environment(\.dismiss) private var dismiss
    @State private var corriere: Corriere = .poste
    @State private var tracking = ""
    @State private var invio = false
    @State private var errore: String?
    /// Il messaggio: si scrive da solo finché non lo modifichi tu; dopo, corriere, tracking e link lo seguono comunque.
    @State private var messaggio = ""
    @State private var toccato = false
    @State private var ultimoScritto = ""
    @State private var prima: (corriere: String, codice: String, link: String)?
    @FocusState private var scrivo: Bool

    private var codice: String { Corriere.pulisci(tracking) }
    private var link: String { codice.isEmpty ? "" : corriere.link(codice) }
    private var base: String {
        "Ciao \(order.buyer.username), il tuo ordine è partito!\nCorriere: \(corriere.nome)\nTracking: \(codice.isEmpty ? "…" : codice)"
            + (codice.isEmpty ? "" : "\n\(link)") + "\nGrazie e buon ascolto!"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("SPEDIZIONE").font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow)
                    Spacer()
                    Button("Chiudi") { Suoni.testa(); dismiss() }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                }

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
                    TextField("Codice della ricevuta", text: $tracking)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(size: 16))
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(Theme.panelHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if !link.isEmpty, let url = URL(string: link) {
                        Link(destination: url) {
                            Text("↗ " + link.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "www.", with: ""))
                                .font(Theme.mono(11)).foregroundStyle(Theme.glow)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .simultaneousGesture(TapGesture().onEnded { Suoni.tocco() })
                    }
                }

                campo("MESSAGGIO ALL'ACQUIRENTE") {
                    TextEditor(text: $messaggio)
                        .focused($scrivo)
                        .font(.system(size: 15))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 150)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Theme.glow.opacity(scrivo ? 0.8 : 0.35), style: StrokeStyle(lineWidth: 1, dash: scrivo ? [] : [4, 3])))
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
        .scrollDismissesKeyboard(.interactively)
        .background(Color(red: 0.043, green: 0.059, blue: 0.047))
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .interactiveDismissDisabled(invio)
        .onAppear { aggiorna() }
        .onChange(of: tracking) { _, _ in aggiorna() }
        .onChange(of: corriere) { _, _ in Suoni.tocco(); aggiorna() }
        .onChange(of: messaggio) { _, nuovo in if nuovo != ultimoScritto { toccato = true } }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Fine") { scrivo = false; _ = UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    /// Il messaggio segue corriere e tracking: tutto da capo finché non l'hai toccato; dopo, si cambiano solo
    /// il corriere, il codice e il link dentro il tuo testo.
    private func aggiorna() {
        let ora = (corriere: corriere.nome, codice: codice, link: link)
        var nuovo = messaggio
        if !toccato || messaggio.isEmpty {
            nuovo = base
        } else if let p = prima {
            if !p.link.isEmpty && !ora.link.isEmpty { nuovo = nuovo.replacingOccurrences(of: p.link, with: ora.link) }
            else if !p.link.isEmpty { nuovo = nuovo.replacingOccurrences(of: "\n" + p.link, with: "").replacingOccurrences(of: p.link, with: "") }
            else if !ora.link.isEmpty, let r = nuovo.range(of: "Tracking: " + (p.codice.isEmpty ? "…" : p.codice)) {
                nuovo.insert(contentsOf: "\n" + ora.link, at: r.upperBound)
            }
            nuovo = nuovo.replacingOccurrences(of: "Corriere: " + p.corriere, with: "Corriere: " + ora.corriere)
            nuovo = nuovo.replacingOccurrences(of: "Tracking: " + (p.codice.isEmpty ? "…" : p.codice), with: "Tracking: " + (ora.codice.isEmpty ? "…" : ora.codice))
        }
        prima = ora
        if nuovo != messaggio {
            ultimoScritto = nuovo
            messaggio = nuovo
        }
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
        let testoFinale = messaggio.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = order.id
        let client = seller.client
        Task { @MainActor in
            do {
                // stato e messaggio insieme: l'acquirente riceve «Spedito» con il tracking
                try await client.postOrderMessage(id, message: testoFinale, status: "Shipped")
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
