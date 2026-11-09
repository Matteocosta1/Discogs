import Combine
import SwiftData
import SwiftUI
import UIKit

@main
struct VinylHustlerApp: App {
    @State private var seller = Seller()
    @Environment(\.scenePhase) private var phase

    init() {
        OrderWatcher.register()
        Theme.configureUIKit()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(seller)
                .task { await seller.refreshAccount() }
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
        .modelContainer(for: Disc.self)
        .onChange(of: phase) { _, newPhase in
            if newPhase == .background { OrderWatcher.schedule() }
        }
    }
}

/// Le 6 sezioni: Foto, Bozze, Magazzino, Ordini, Chat, Settings (V68: barra disegnata da noi, la barra di Apple su iPhone ne tiene 5).
struct RootView: View {
    @Environment(Seller.self) private var seller
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Disc> { $0.statusRaw == "daControllare" || $0.statusRaw == "daConfermare" })
    private var toCheck: [Disc]
    @AppStorage("selectedTab") private var tab = 0
    @State private var splash = true
    /// V60 · proposta 7: quando parte l'entrata delle icone (nil = finita o non c'è).
    @State private var avvio: Date?
    @Environment(\.horizontalSizeClass) private var larghezza
    /// Le sezioni già aperte restano vive (come faceva la barra di Apple).
    @State private var viste: Set<Int> = []
    @State private var tastiera = false

    var body: some View {
        Group {
            if !seller.isLoggedIn {
                LoginView()
            } else {
                tabs
            }
        }
        .overlay {
            if splash { SplashView().transition(.opacity) }
        }
        .task { seller.startup(context: context) }
        .task {
            // all'apertura il marchio si accende come un neon, con il suono d'apertura, poi sfuma
            _ = Avvio.quando                                // il momento dell'avvio (per «IN LINEA» in Foto)
            Suoni.apertura()
            try? await Task.sleep(for: .milliseconds(1700))
            // V60: la barra in basso si copre subito, poi le icone entrano una dopo l'altra mentre la scritta sfuma
            avvio = Date()
            withAnimation(.easeOut(duration: 0.5)) { splash = false }
            if seller.isLoggedIn { await AvvioIcone.suona() }
            try? await Task.sleep(for: .milliseconds(Int(AvvioIcone.durata * 1000) - 750))
            avvio = nil
        }
        .onChange(of: tab) { _, _ in Suoni.tocco() }
        .onChange(of: seller.lastError) { _, e in if e != nil { Suoni.nego() } }
        .onAppear { if !(0...5).contains(tab) { tab = 0 } }
        .alert(seller.lastError ?? "", isPresented: Binding(get: { seller.lastError != nil },
                                                            set: { if !$0 { seller.lastError = nil } })) {}
    }

    private var tabs: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                if viste.contains(i) || tab == i {
                    sezione(i)
                        .opacity(tab == i ? 1 : 0)
                        .allowsHitTesting(tab == i)
                        .accessibilityHidden(tab != i)
                        .environment(\.sezioneVisibile, tab == i)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !tastiera {
                BarraSezioni(tab: $tab, avvio: avvio, badge: [1: toCheck.count, 4: ChatStore.shared.nonLetti])
            }
        }
        .onChange(of: tab, initial: true) { _, t in viste.insert(t) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in tastiera = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in tastiera = false }
        .task { ChatStore.shared.avvia(discogs: seller.username) }      // i non letti della Chat anche dalle altre sezioni
    }

    @ViewBuilder private func sezione(_ i: Int) -> some View {
        switch i {
        case 0: SessionView()
        case 1: DraftsTab()
        case 2: WarehouseView()
        case 3: OrdersView()
        case 4: ChatView()
        default: ConsoleView()
        }
    }
}

/// V68 — la barra delle sei sezioni, uguale a quella di Apple (nero, riga sottile in alto, icona e nome),
/// con l'entrata delle icone all'avvio (proposta 7: una dopo l'altra, ogni 150 ms).
struct BarraSezioni: View {
    @Binding var tab: Int
    let avvio: Date?
    let badge: [Int: Int]

    private static let nomi = ["Foto", "Bozze", "Magazzino", "Ordini", "Chat", "Settings"]
    private static let simboli = ["camera.fill", "tray.full", "square.stack.3d.up", "shippingbox", "bubble.left.and.text.bubble.right", "gearshape"]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120, paused: avvio == nil)) { ctx in
            HStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { k in
                    Button { tab = k } label: { icona(k, t: avvio.map { ctx.date.timeIntervalSince($0) }) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Self.nomi[k])
                        .accessibilityAddTraits(tab == k ? .isSelected : [])
                }
            }
            .frame(height: 49)
            .padding(.top, 1)
            .background(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5) }
            .background(Color.black.ignoresSafeArea(edges: .bottom))
        }
    }

    private func icona(_ k: Int, t: Double?) -> some View {
        let p = t.map { morbido(($0 - 0.15 - Double(k) * 0.15) / 0.35) } ?? 1
        let n = badge[k] ?? 0
        return VStack(spacing: 3) {
            Image(systemName: Self.simboli[k]).font(.system(size: 21, weight: .regular))
                .frame(height: 24)
                .overlay(alignment: .topTrailing) {
                    if n > 0 {
                        Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).frame(minWidth: 17, minHeight: 17)
                            .background(Theme.warn, in: Capsule())
                            .offset(x: 12, y: -5)
                    }
                }
            Text(Self.nomi[k]).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(k == tab ? Theme.accent : Theme.muted)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .scaleEffect(0.4 + 0.6 * p)
        .offset(y: 26 * (1 - p))
        .opacity(p)
    }
}

private struct SezioneVisibileKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// V68: false nelle sezioni tenute vive ma non guardate (la barra delle sezioni).
    var sezioneVisibile: Bool {
        get { self[SezioneVisibileKey.self] }
        set { self[SezioneVisibileKey.self] = newValue }
    }
}


/// Primo avvio: collegare l'account Discogs.
struct LoginView: View {
    @Environment(Seller.self) private var seller
    @State private var token = ""
    @State private var error: String?
    @State private var showManual = false

    private var hasMacToken: Bool { !AppConfig.discogsPersonalToken.isEmpty }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            // il bagliore verde dietro al marchio, come nella schermata d'accesso di Discosizer
            RadialGradient(colors: [Theme.accent.opacity(0.16), .clear], center: .init(x: 0.5, y: 0.36),
                           startRadius: 10, endRadius: 280)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    HustlerTag(size: 70)
                        .padding(.top, 150)

                    VStack(spacing: 12) {
                        if hasMacToken {
                            Button("Usa il token del Mac") {
                                Task { await seller.connect(.personalToken(AppConfig.discogsPersonalToken)) }
                            }
                            .buttonStyle(SignalButtonStyle())
                        }
                        Button("Accedi con Discogs") {
                            Task {
                                do {
                                    let credentials = try await DiscogsLogin().login()
                                    await seller.connect(credentials)
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                        .buttonStyle(SignalButtonStyle(filled: !hasMacToken))

                        Button(showManual ? "Nascondi token personale" : "Ho un token personale") {
                            withAnimation(.snappy) { showManual.toggle() }
                        }
                        .font(.system(size: 15)).foregroundStyle(Theme.muted).padding(.top, 8)

                        if showManual {
                            HStack(spacing: 8) {
                                SecureField("Token personale Discogs", text: $token).fieldStyle()
                                PasteButton(payloadType: String.self) { strings in
                                    let pasted = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                    Task { @MainActor in token = pasted }
                                }
                                .labelStyle(.iconOnly)
                            }
                            Button("Usa il token") {
                                Task { await seller.connect(.personalToken(token.trimmingCharacters(in: .whitespaces))) }
                            }
                            .buttonStyle(SignalButtonStyle(filled: false))
                            .disabled(token.count < 10)
                        }
                        if let error {
                            Text(error).font(Theme.mono(12)).foregroundStyle(Theme.warn)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 40)
                }
                .padding(20)
            }
        }
    }
}

/// Apertura: nero, bagliore verde e la scritta che si accende a scatti come un neon.
struct SplashView: View {
    @State private var light = 0.0
    @State private var glow = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(colors: [Theme.accent.opacity(glow ? 0.18 : 0), .clear], center: .center,
                           startRadius: 10, endRadius: 300)
                .ignoresSafeArea()
            HustlerTag(size: 70).opacity(light)
        }
        .task {
            // (luce, durata): tremolio del neon che si accende
            let steps: [(Double, Int)] = [(0, 180), (0.9, 40), (0.1, 70), (1, 40), (0.35, 90), (1, 60), (0.75, 120), (1, 0)]
            for (value, ms) in steps {
                withAnimation(.linear(duration: 0.03)) { light = value }
                try? await Task.sleep(for: .milliseconds(ms))
            }
            withAnimation(.easeOut(duration: 0.8)) { glow = true }
        }
    }
}
