import SwiftData
import SwiftUI

@main
struct DiscosizerSellerApp: App {
    @State private var seller = Seller()
    @Environment(\.scenePhase) private var phase

    init() { OrderWatcher.register() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(seller)
                .task { await seller.refreshAccount() }
                .tint(Theme.accent)
        }
        .modelContainer(for: Disc.self)
        .onChange(of: phase) { _, newPhase in
            if newPhase == .background { OrderWatcher.schedule() }
        }
    }
}

/// Le 5 sezioni del mockup V2: Sessione, Revisione, Magazzino, Ordini, Console.
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
        Group {
            TabView(selection: $tab) {
                SessionView().tabItem { Label("Sessione", systemImage: "camera") }.tag(0)
                ReviewView().tabItem { Label("Revisione", systemImage: "checkmark.circle") }.tag(1)
                    .badge(toCheck.count)
                WarehouseView().tabItem { Label("Magazzino", systemImage: "shippingbox") }.tag(2)
                OrdersView().tabItem { Label("Ordini", systemImage: "bag") }.tag(3)
                ConsoleView().tabItem { Label("Console", systemImage: "gearshape") }.tag(4)
            }
        }
    }
}

/// Colori del concept V2 (King Rusto Green). Il layout si ristudia: qui solo i valori di base.
enum Theme {
    static let accent = Color(red: 0.11, green: 0.36, blue: 0.22)
    static let ink = Color.primary
    static let warn = Color(red: 0.70, green: 0.25, blue: 0.10)
}

/// Primo avvio: collegare l'account Discogs.
struct LoginView: View {
    @Environment(Seller.self) private var seller
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("DISCOSIZER SELLER").font(.system(size: 34, weight: .black))
            Text("Collega il tuo account Discogs per riconoscere e mettere in vendita i dischi.")
                .foregroundStyle(.secondary)
            Button {
                Task {
                    do {
                        let credentials = try await DiscogsLogin().login()
                        await seller.connect(credentials)
                    } catch { self.error = error.localizedDescription }
                }
            } label: {
                Text("Accedi con Discogs").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            Divider()
            Text("Uso interno: token personale").font(.caption).foregroundStyle(.secondary)
            SecureField("Token da discogs.com/settings/developers", text: $token)
                .textFieldStyle(.roundedBorder)
            Button("Usa il token") { Task { await seller.connect(.personalToken(token.trimmingCharacters(in: .whitespaces))) } }
                .disabled(token.count < 10)
            if let error { Text(error).foregroundStyle(Theme.warn).font(.footnote) }
        }
        .padding(24)
    }
}
