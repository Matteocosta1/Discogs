import SwiftUI
import UIKit

/// Look "Discogs × tecnologico": nero da sala d'ascolto, tipografia condensata, dati in monospace,
/// angoli vivi e un solo colore di segnale. Tutti i colori e i caratteri stanno qui:
/// per cambiare il look dell'app si tocca solo questo file.
enum Theme {
    // MARK: Colori
    static let bg = Color(hex: 0x0A0A0B)          // fondo
    static let panel = Color(hex: 0x141416)       // schede
    static let panelHigh = Color(hex: 0x1D1D20)   // campi e righe in evidenza
    static let line = Color.white.opacity(0.10)   // filetti
    static let text = Color.white
    static let muted = Color.white.opacity(0.55)
    static let accent = Color(hex: 0xC8F03C)      // verde segnale: azioni e stati "ok"
    static let military = Color(hex: 0x4B5D33)    // King Rusto Green: gradi e dettagli
    static let warn = Color(hex: 0xFF6A3D)        // da controllare / errori

    // MARK: Caratteri
    /// Titoli: condensato e nerissimo, come le testate.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .black) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }

    /// Dati, etichette, numeri di catalogo: monospace.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Barre di navigazione e delle schede (UIKit), da chiamare una volta all'avvio.
    static func configureUIKit() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(bg)
        nav.shadowColor = .clear
        nav.largeTitleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 40, weight: .black, width: .condensed),
            .foregroundColor: UIColor.white,
        ]
        nav.titleTextAttributes = [
            .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: UIColor.white,
        ]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(bg)
        tab.shadowColor = UIColor(white: 1, alpha: 0.10)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Componenti

/// Etichetta tecnica in stile HUD: "01 / SESSIONE".
struct HUDLabel: View {
    let number: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(number).foregroundStyle(Theme.accent)
            Text("/").foregroundStyle(Theme.muted)
            Text(title.uppercased()).foregroundStyle(Theme.muted)
        }
        .font(Theme.mono(11, .semibold))
        .tracking(1.5)
    }
}

/// Il disco: solchi concentrici ed etichetta verde al centro. Con `spinning` gira piano;
/// il riflesso resta fermo, come su un giradischi vero.
struct VinylMark: View {
    var size: CGFloat = 120
    var spinning = false
    @State private var angle = 0.0

    var body: some View {
        ZStack {
            disc
                .rotationEffect(.degrees(angle))
            Circle()
                .trim(from: 0.06, to: 0.14)
                .stroke(Color.white.opacity(0.10), lineWidth: size * 0.22)
                .padding(size * 0.16)
                .blur(radius: size * 0.02)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard spinning else { return }
            withAnimation(.linear(duration: 5).repeatForever(autoreverses: false)) { angle = 360 }
        }
    }

    private var disc: some View {
        ZStack {
            Circle().fill(Color(hex: 0x111112))
            ForEach(1..<11, id: \.self) { i in
                Circle()
                    .stroke(Color.white.opacity(i % 3 == 0 ? 0.11 : 0.05), lineWidth: 0.7)
                    .padding(size * 0.027 * CGFloat(i))
            }
            Circle().fill(Theme.accent).frame(width: size * 0.34, height: size * 0.34)
            Text("DS")
                .font(.system(size: size * 0.07, weight: .black, design: .monospaced))
                .foregroundStyle(Color.black)
                .offset(y: -size * 0.09)
            Circle().fill(Theme.bg).frame(width: size * 0.035, height: size * 0.035)
        }
    }
}

/// Pulsante dell'app: pieno (verde segnale) o a filo. I pulsanti "distruttivi" diventano arancio.
struct SignalButtonStyle: ButtonStyle {
    var filled = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let destructive = configuration.role == .destructive
        return configuration.label
            .font(Theme.mono(13, .bold))
            .textCase(.uppercase)
            .tracking(1)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.vertical, 13)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .foregroundStyle(filled ? Color.black : (destructive ? Theme.warn : Theme.text))
            .background(filled ? (destructive ? Theme.warn : Theme.accent) : Color.clear)
            .overlay(Rectangle().stroke(filled ? Color.clear : Theme.line, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
    }
}

/// Stato del disco come targhetta.
struct StatusTag: View {
    let status: DiscStatus

    var body: some View {
        Text(label)
            .font(Theme.mono(10, .bold))
            .tracking(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .foregroundStyle(foreground)
            .background(background)
    }

    private var label: String {
        switch status {
        case .inLavorazione: "IN RICONOSCIMENTO"
        case .pronto: "PRONTO"
        case .inVendita: "ONLINE"
        case .bozza: "BOZZA"
        case .daControllare: "DA CONTROLLARE"
        case .bloccato: "BLOCCATO"
        case .tolto: "TOLTO"
        }
    }

    private var background: Color {
        switch status {
        case .inVendita, .pronto: Theme.accent
        case .daControllare, .bloccato: Theme.warn
        default: Theme.panelHigh
        }
    }

    private var foreground: Color {
        switch status {
        case .inVendita, .pronto, .daControllare, .bloccato: Color.black
        default: Theme.text
        }
    }
}

/// Campo di testo dell'app: fondo scuro, filetto, monospace.
struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.mono(13))
            .padding(12)
            .background(Theme.panelHigh)
            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
    }
}

extension View {
    /// Scheda con angoli vivi e filetto (stile Discogs, ma al buio).
    func panel(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(Theme.panel)
            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
    }

    func fieldStyle() -> some View { modifier(FieldStyle()) }

    /// Liste e moduli sul fondo dell'app invece del grigio di sistema.
    func themedBackground() -> some View {
        self.scrollContentBackground(.hidden).background(Theme.bg)
    }
}
