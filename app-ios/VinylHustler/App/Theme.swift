import SwiftUI
import UIKit

/// Family feeling Discosizer: nero puro, schede grigie arrotondate come iOS, carattere di sistema,
/// e il verde Discosizer in quattro gradazioni. Tutti i colori e i caratteri stanno qui:
/// per cambiare il look dell'app si tocca solo questo file.
enum Theme {
    // MARK: Colori (presi dall'app Discosizer)
    static let bg = Color.black                   // fondo
    static let panel = Color(hex: 0x1C1C1E)       // schede
    static let panelHigh = Color(hex: 0x262629)   // pastiglie, tasti secondari
    static let field = Color(hex: 0x141414)       // campi di testo
    static let line = Color.white.opacity(0.08)   // separatori
    static let text = Color.white
    static let muted = Color(hex: 0x8E8E93)       // testo secondario
    // La scala di verdi
    static let glow = Color(hex: 0x39FF14)        // verdino chiaro: logo, luce, riconosciuto
    static let accent = Color(hex: 0x0AED0C)      // verde Discosizer: azioni
    static let money = Color(hex: 0x30D158)       // valori positivi, online
    static let military = Color(hex: 0x1F3C28)    // verde scuro: fondo delle pastiglie
    // Rosso
    static let warn = Color(hex: 0xFF453A)
    static let warnSoft = Color(hex: 0x452323)

    static let radius: CGFloat = 16

    // MARK: Caratteri: San Francisco, come Discosizer
    /// Titoli e cifre grandi.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight)
    }

    /// Testo, etichette, numeri (il nome è rimasto da quando era monospace).
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Barre di navigazione e delle schede (UIKit), da chiamare una volta all'avvio.
    static func configureUIKit() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = .black
        nav.shadowColor = .clear
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = .black
        tab.shadowColor = UIColor(white: 1, alpha: 0.08)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UISegmentedControl.appearance().selectedSegmentTintColor = UIColor(white: 0.36, alpha: 1)
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

/// Intestazione di sezione, come in Discosizer: maiuscolo, grigio, semplice. (Il numero non si mostra più.)
struct HUDLabel: View {
    var number: String = ""
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted)
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
            Text("VH")
                .font(.system(size: size * 0.07, weight: .black, design: .monospaced))
                .foregroundStyle(Color.black)
                .offset(y: -size * 0.09)
            Circle().fill(Theme.bg).frame(width: size * 0.035, height: size * 0.035)
        }
    }
}

/// Pulsante dell'app, come il tasto Staff di Discosizer: verde pieno con testo nero,
/// oppure grigio (secondario). I distruttivi diventano rossi.
struct SignalButtonStyle: ButtonStyle {
    var filled = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let destructive = configuration.role == .destructive
        return configuration.label
            .font(.system(size: 16, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.vertical, 13)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .foregroundStyle(filled ? Color.black : (destructive ? Theme.warn : Theme.text))
            .background(filled ? (destructive ? Theme.warn : Theme.accent) : Theme.panelHigh,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
    }
}

/// Stato del disco come targhetta.
struct StatusTag: View {
    let status: DiscStatus

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(colors.fg)
            .background(colors.bg, in: Capsule())
    }

    private var label: String {
        switch status {
        case .inLavorazione: "Sto guardando…"
        case .daConfermare: "Riconosciuto"
        case .pronto: "Pronto"
        case .inVendita: "Online"
        case .bozza: "Bozza"
        case .daControllare: "Non riconosciuto"
        case .bloccato: "Bloccato"
        case .tolto: "Tolto"
        }
    }

    /// Le pastiglie di Discosizer: fondo scuro della stessa tinta del testo.
    private var colors: (fg: Color, bg: Color) {
        switch status {
        case .inVendita, .pronto: (Theme.money, Theme.military)
        case .daConfermare: (Theme.glow, Theme.glow.opacity(0.14))
        case .daControllare, .bloccato: (Theme.warn, Theme.warnSoft)
        default: (Theme.muted, Theme.panelHigh)
        }
    }
}

/// Campo di testo dell'app, come Email/Password di Discosizer.
struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 17))
            .padding(16)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension View {
    /// Scheda grigia arrotondata, come le liste di Discosizer.
    func panel(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    func fieldStyle() -> some View { modifier(FieldStyle()) }

    /// Liste e moduli sul fondo dell'app invece del grigio di sistema.
    func themedBackground() -> some View {
        self.scrollContentBackground(.hidden).background(Theme.bg)
    }
}

/// Il marchio, con le lettere del logo Discosizer (ricavate dal logo stesso: D, I, S, C, O, Z, E, R;
/// V, N, Y, L, H, U, T costruite con gli stessi pezzi). Verde che si accende nel buio.
struct HustlerTag: View {
    var size: CGFloat = 76          // altezza di una riga
    var stacked = true              // VINYL sopra HUSTLER, oppure su una riga

    var body: some View {
        VStack(spacing: size * 0.22) {
            Image(stacked ? "Wordmark" : "WordmarkLine")
                .resizable()
                .scaledToFit()
                .frame(height: stacked ? size * 2.11 : size)
                .shadow(color: Theme.glow.opacity(0.55), radius: size * 0.22)
                .shadow(color: Theme.accent.opacity(0.35), radius: size * 0.6)
                .accessibilityLabel("Vinyl Hustler")
            Text("A DISCOSIZER PROJECT")
                .font(.system(size: max(11, size * 0.16), weight: .semibold))
                .tracking(size * 0.04)
                .foregroundStyle(Theme.muted)
        }
    }
}
