import SwiftData
import SwiftUI

@main
struct DiscosizerSellerApp: App {
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

/// Le 5 sezioni: Sessione, Revisione, Magazzino, Ordini, Console.
struct RootView: View {
    @Environment(Seller.self) private var seller
    @Query(filter: #Predicate<Disc> { $0.statusRaw == "daControllare" }) private var toCheck: [Disc]
    @State private var tab = 0

    var body: some View {
        Group {
            if !seller.isLoggedIn {
                LoginView()
            } else {
                tabs
            }
        }
        .alert(seller.lastError ?? "", isPresented: Binding(get: { seller.lastError != nil },
                                                            set: { if !$0 { seller.lastError = nil } })) {}
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            SessionView().tabItem { Label("Sessione", systemImage: "camera.aperture") }.tag(0)
            ReviewView().tabItem { Label("Revisione", systemImage: "checkmark.seal") }.tag(1)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        HUDLabel(number: "00", title: "Accesso")
                        Spacer()
                        Text("v0.1").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                    VinylMark(size: 230, spinning: true)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    Text("DISCOSIZER").font(Theme.display(58)).foregroundStyle(Theme.text)
                    Text("SELLER").font(Theme.display(58)).foregroundStyle(Theme.accent).padding(.top, -16)
                    Text("Fotografa. Riconosci. Vendi su Discogs.")
                        .font(Theme.mono(13)).foregroundStyle(Theme.muted).padding(.top, 6)

                    VStack(spacing: 10) {
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
                        .font(Theme.mono(12)).foregroundStyle(Theme.muted).padding(.top, 4)

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
                    .padding(.top, 28)
                }
                .padding(24)
            }
        }
    }
}
