import SwiftUI

// V60 — i pezzi in comune delle animazioni alla JARVIS (come nel mock-up approvato).
// Regola: niente animazioni infinite fatte con withAnimation(.repeatForever) (fanno ballare le pagine, V55):
// quello che si muove sempre è guidato da TimelineView.

/// Le lettere che si «decodificano»: simboli che diventano il testo vero (come Glifi in JARVIS).
enum Glifi {
    static let insieme = Array("ABCDEFGHJKLMNPQRSTUVWXYZ0123456789#%&*+=<>/|▪▫░▒")
    /// `quanto`: 0 = testo vero, 1 = tutti simboli.
    static func rimescola(_ s: String, _ quanto: Double) -> String {
        guard quanto > 0 else { return s }
        return String(s.map { c in
            (c == " " || c == "\n" || Double.random(in: 0..<1) > quanto) ? c : (insieme.randomElement() ?? c)
        })
    }
}

/// Un testo che si decodifica una volta: parte `ritardo` secondi dopo `da` e dura `durata` secondi.
/// Cambiando `testo` (o `da`) riparte.
struct TestoDecodifica: View {
    let testo: String
    var da: Date
    var ritardo: Double = 0
    var durata: Double = 0.5
    /// A decodifica finita il TimelineView si ferma (non gira per niente).
    @State private var finito = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: finito)) { ctx in
            let t = ctx.date.timeIntervalSince(da) - ritardo
            let quanto = t <= 0 ? 1 : max(0, 1 - t / durata)
            Text(Glifi.rimescola(testo, finito ? 0 : quanto))
        }
        .task(id: TestoDecodifica.chiave(testo, da)) {
            let resta = ritardo + durata - Date().timeIntervalSince(da)
            if resta > 0 {
                finito = false
                try? await Task.sleep(for: .milliseconds(Int(resta * 1000) + 60))
                if Task.isCancelled { return }
            }
            finito = true
        }
    }

    private static func chiave(_ testo: String, _ da: Date) -> String { "\(testo)|\(da.timeIntervalSinceReferenceDate)" }
}

/// Curva morbida 0…1 (come `morbido` nel mock-up).
func morbido(_ x: Double) -> Double {
    let c = min(1, max(0, x))
    return c * c * (3 - 2 * c)
}

/// Sfondo HUD (proposta 6): dietro le sezioni un bagliore verde che respira e una griglia a quadretti appena visibile
/// che scorre. Tutto guidato da TimelineView, quindi non tocca la disposizione della pagina.
struct SfondoHUD: View {
    /// false = sotto la fotocamera a tutto schermo: lo sfondo non si vede e si ferma.
    var attivo = true
    @Environment(\.accessibilityReduceMotion) private var fermo
    /// V68: sezione non guardata (la barra le tiene vive): lo sfondo si ferma.
    @Environment(\.sezioneVisibile) private var sezioneVisibile
    /// Le pagine delle sezioni non guardate restano vive nel TabView: lì lo sfondo si ferma (batteria).
    @State private var visibile = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: fermo || !visibile || !attivo || !sezioneVisibile)) { ctx in
            let t = fermo ? 0 : ctx.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                // il bagliore in alto che respira (9 s)
                let r = (sin(t * 2 * .pi / 9) + 1) / 2
                let centro = CGPoint(x: size.width / 2, y: 0.2 * 620 - 60 + r * 8)
                gc.fill(Path(CGRect(origin: .zero, size: size)),
                        with: .radialGradient(Gradient(colors: [Theme.accent.opacity(0.13 * (0.75 + 0.25 * r)), .clear]),
                                              center: centro, startRadius: 0, endRadius: max(size.width, 420) * 0.62))
                // la griglia che scorre verso il basso (un quadretto ogni 4,6 s)
                let lato = 28.0
                let scorre = (t / 4.6).truncatingRemainder(dividingBy: 1) * lato
                var griglia = Path()
                var y = scorre - lato
                while y < size.height { griglia.move(to: CGPoint(x: 0, y: y)); griglia.addLine(to: CGPoint(x: size.width, y: y)); y += lato }
                var x = 0.0
                while x < size.width { griglia.move(to: CGPoint(x: x, y: 0)); griglia.addLine(to: CGPoint(x: x, y: size.height)); x += lato }
                gc.stroke(griglia, with: .color(Theme.glow.opacity(0.05)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { visibile = true }
        .onDisappear { visibile = false }
    }
}

extension View {
    /// Fondo nero dell'app con sopra lo sfondo HUD (proposta 6): per le pagine principali delle cinque sezioni.
    func sfondoHUD(attivo: Bool = true) -> some View {
        self.background { ZStack { Theme.bg; SfondoHUD(attivo: attivo) }.ignoresSafeArea() }
    }
}
