import AVFoundation
import ShazamKit
import SwiftUI

/// Il brano sentito dall'Orecchio: diventa un indizio per trovare il disco su Discogs.
struct BranoSentito: Codable, Equatable {
    var titolo: String
    var artista: String
    var album: String
    var copertina: String?

    var riga: String { album.isEmpty ? "\(artista) — \(titolo)" : "\(artista) — \(titolo) · \(album)" }
}

/// L'ORECCHIO — lo stesso di JARVIS: ShazamKit dal microfono.
/// Si mette il disco sul piatto (o vicino alle casse), l'Orecchio ascolta fino a 15 secondi
/// e riconosce il brano anche nell'elettronica più complessa. Serve il servizio ShazamKit
/// attivo sull'identificativo dell'app (developer.apple.com › Identifiers › it.vinylhustler.app › App Services).
enum Orecchio {
    enum Esito { case trovato(BranoSentito), nessuno, errore(String) }

    static func ascolta(secondi: Double = 15) async -> Esito {
        guard await AVAudioApplication.requestRecordPermission() else { return .errore("Manca il permesso del microfono") }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try? s.setActive(true)
        defer { try? s.setActive(false, options: .notifyOthersOnDeactivation) }

        let sessione = SHManagedSession()
        let durata = min(max(secondi, 5), 20)
        let inizio = Date()
        // rete di sicurezza: qualunque cosa succeda, entro durata + 8 secondi si esce
        let r: SHSession.Result? = await withCheckedContinuation { (c: CheckedContinuation<SHSession.Result?, Never>) in
            let una = UnaSolaVolta()
            Task {
                await sessione.prepare()
                let scadenza = Task {
                    try? await Task.sleep(for: .seconds(durata))
                    if !Task.isCancelled { sessione.cancel() }
                }
                let esito = await sessione.result()
                scadenza.cancel()
                if una.prendi() { c.resume(returning: esito) }
            }
            Task {
                try? await Task.sleep(for: .seconds(durata + 8))
                if una.prendi() { sessione.cancel(); c.resume(returning: nil) }
            }
        }
        sessione.cancel()
        guard let r else { return .errore("L'Orecchio non ha risposto: forse il servizio ShazamKit non è ancora attivo per l'app") }

        switch r {
        case .match(let m):
            guard let v = m.mediaItems.first else { return .nessuno }
            return .trovato(BranoSentito(titolo: v.title ?? "", artista: v.artist ?? "",
                                         album: v.subtitle ?? "", copertina: v.artworkURL?.absoluteString))
        case .noMatch:
            return .nessuno
        case .error(let e, _):
            let ns = e as NSError
            if ns.domain == SHErrorDomain, ns.code == SHError.Code.matchAttemptFailed.rawValue { return .nessuno }
            if Date().timeIntervalSince(inizio) >= durata - 0.5 { return .nessuno }
            return .errore("\(e.localizedDescription) [\(ns.domain) \(ns.code)]")
        @unknown default:
            return .nessuno
        }
    }
}

/// Garantisce che la risposta arrivi una volta sola (dal risultato o dal tempo massimo).
final class UnaSolaVolta: @unchecked Sendable {
    private let lock = NSLock()
    private var usata = false
    func prendi() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if usata { return false }
        usata = true
        return true
    }
}

/// Schermata dell'Orecchio: onde che pulsano mentre ascolta, poi il brano trovato.
struct OrecchioView: View {
    let fine: (BranoSentito?) -> Void
    @State private var stato = "IN ASCOLTO"
    @State private var trovato: BranoSentito?
    @State private var ascoltando = true
    @State private var mancano = 15
    @State private var tentativo = 0

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VINYL HUSTLER").font(Theme.mono(15, .bold)).tracking(4)
                        Text("ORECCHIO").font(Theme.mono(9)).tracking(2).opacity(0.7)
                    }
                    .foregroundStyle(Theme.accent)
                    Spacer()
                    Button { fine(nil) } label: {
                        Image(systemName: "xmark").font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 44, height: 44)
                            .overlay(Circle().stroke(Theme.accent.opacity(0.5), lineWidth: 1))
                    }
                    .accessibilityLabel("Chiudi")
                }
                Spacer()
                if let b = trovato {
                    risultato(b)
                } else {
                    OndeOrecchio(attive: ascoltando).frame(width: 260, height: 260)
                    Text(ascoltando ? "\(stato) · \(mancano)" : stato)
                        .font(Theme.mono(13, .semibold)).tracking(3).foregroundStyle(Theme.accent)
                        .contentTransition(.numericText(countsDown: true))
                    Text("Metti il disco sul piatto o avvicina il telefono alle casse.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    if !ascoltando {
                        Button("Riprova") { tentativo += 1 }.buttonStyle(SignalButtonStyle(filled: false)).frame(width: 200)
                    }
                }
                Spacer()
            }
            .padding(20)
        }
        .task(id: tentativo) { await ascolta() }
    }

    private func risultato(_ b: BranoSentito) -> some View {
        VStack(spacing: 16) {
            AsyncImage(url: b.copertina.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() }
                placeholder: { VinylMark(size: 200) }
                .frame(width: 220, height: 220).clipped()
                .overlay(Rectangle().stroke(Theme.accent, lineWidth: 2))
            Text("SENTITO").font(Theme.mono(11, .bold)).tracking(3).foregroundStyle(Theme.accent)
            Text(b.titolo).font(Theme.display(32)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
            Text(b.artista.uppercased()).font(Theme.mono(13, .bold)).foregroundStyle(Theme.text)
            if !b.album.isEmpty { Text(b.album).font(Theme.mono(12)).foregroundStyle(Theme.muted) }
            Button("Usa per questo disco") { fine(b) }.buttonStyle(SignalButtonStyle()).padding(.top, 8)
            Button("Ascolta di nuovo") { trovato = nil; tentativo += 1 }.buttonStyle(SignalButtonStyle(filled: false))
        }
    }

    private func ascolta() async {
        ascoltando = true
        stato = "IN ASCOLTO"
        let conto = Task { @MainActor in
            for s in stride(from: 15, through: 1, by: -1) {
                withAnimation { mancano = s }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let esito = await Orecchio.ascolta(secondi: 15)
        conto.cancel()
        ascoltando = false
        switch esito {
        case .trovato(let b):
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.snappy) { trovato = b }
        case .nessuno:
            stato = "NESSUN BRANO RICONOSCIUTO"
        case .errore(let e):
            stato = e.uppercased()
        }
    }
}

/// Onde concentriche che pulsano mentre l'Orecchio ascolta.
struct OndeOrecchio: View {
    let attive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let massimo = min(size.width, size.height) / 2
                for k in 0..<4 {
                    let fase = attive ? ((t * 0.5) + Double(k) / 4).truncatingRemainder(dividingBy: 1) : 0.25 * Double(k + 1)
                    let r = massimo * (0.3 + 0.7 * fase)
                    let cerchio = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                    gc.stroke(cerchio, with: .color(Theme.accent.opacity(attive ? (1 - fase) * 0.8 : 0.2)), lineWidth: 2)
                }
                let nucleo = massimo * 0.26
                gc.fill(Path(ellipseIn: CGRect(x: c.x - nucleo, y: c.y - nucleo, width: nucleo * 2, height: nucleo * 2)),
                        with: .color(Theme.accent))
            }
            .overlay {
                Image(systemName: "ear").font(.system(size: 40, weight: .bold)).foregroundStyle(Color.black)
            }
        }
    }
}
