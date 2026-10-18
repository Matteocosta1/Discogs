import SwiftData
import SwiftUI

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

/// Le 5 sezioni: Foto, Bozze, Magazzino, Ordini, Console.
struct RootView: View {
    @Environment(Seller.self) private var seller
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Disc> { $0.statusRaw == "daControllare" || $0.statusRaw == "daConfermare" })
    private var toCheck: [Disc]
    @AppStorage("selectedTab") private var tab = 0
    @State private var splash = true

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
            // all'apertura il marchio si accende come un neon, col suono d'avvio di JARVIS, poi sfuma
            Suoni.apertura()
            try? await Task.sleep(for: .milliseconds(1700))
            withAnimation(.easeOut(duration: 0.5)) { splash = false }
        }
        .onChange(of: tab) { _, _ in Suoni.tocco() }
        .onAppear { if !(0...4).contains(tab) { tab = 0 } }
        .alert(seller.lastError ?? "", isPresented: Binding(get: { seller.lastError != nil },
                                                            set: { if !$0 { seller.lastError = nil } })) {}
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            SessionView().tabItem { Label("Foto", systemImage: "camera.fill") }.tag(0)
            DraftsTab().tabItem { Label("Bozze", systemImage: "tray.full") }.tag(1)
                .badge(toCheck.count)
            WarehouseView().tabItem { Label("Magazzino", systemImage: "square.stack.3d.up") }.tag(2)
            OrdersView().tabItem { Label("Ordini", systemImage: "shippingbox") }.tag(3)
            ConsoleView().tabItem { Label("Console", systemImage: "slider.horizontal.3") }.tag(4)
        }
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
