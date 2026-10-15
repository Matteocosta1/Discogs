import AuthenticationServices
import CryptoKit
import SwiftData
import SwiftUI

/// 05 / CONSOLE — account, modalità di riconoscimento, contatore API, regole del prezzo, accesso AI.
struct ConsoleView: View {
    @Environment(Seller.self) private var seller
    @Query private var discs: [Disc]
    @State private var apiUsed = 0
    @State private var nonce = ""
    @State private var aiSignedIn = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var seller = seller
        NavigationStack {
            Form {
                Section("Account Discogs") {
                    LabeledContent("Utente", value: seller.username.isEmpty ? "—" : seller.username)
                    LabeledContent("Valuta", value: seller.currency)
                    Button("Esci da Discogs", role: .destructive) { seller.logout() }
                }
                Section("API Discogs · ultimo minuto") {
                    LabeledContent("Richieste", value: "\(apiUsed) / 60")
                    ProgressView(value: Double(apiUsed), total: 60).tint(apiUsed > 50 ? Theme.warn : Theme.accent)
                    Text("Una richiesta al secondo, sempre. Il limite è per telefono (indirizzo IP).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Riconoscimento") {
                    Picker("Modalità", selection: $seller.mode) {
                        ForEach(RecognitionMode.allCases) { Text($0.label).tag($0) }
                    }
                    Text(modeHelp).font(.caption).foregroundStyle(.secondary)
                    if seller.mode.usesAI {
                        if Backend.shared.isConfigured {
                            if aiSignedIn {
                                Label("AI attiva", systemImage: "checkmark.seal")
                            } else {
                                SignInWithAppleButton(.signIn) { request in
                                    nonce = UUID().uuidString
                                    request.requestedScopes = [.email]
                                    request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
                                } onCompletion: { result in
                                    guard case .success(let auth) = result,
                                          let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                                          let tokenData = cred.identityToken, let token = String(data: tokenData, encoding: .utf8) else { return }
                                    Task {
                                        try? await Backend.shared.signInWithApple(idToken: token, nonce: nonce)
                                        aiSignedIn = await Backend.shared.accessToken() != nil
                                    }
                                }
                                .frame(height: 44)
                            }
                        } else {
                            Text("Supabase non configurato: l'AI è spenta, si usa solo Vision.").font(.caption).foregroundStyle(Theme.warn)
                        }
                    }
                    LabeledContent("Spesa AI (tutti i dischi)", value: discs.reduce(0) { $0 + $1.aiCost }.formatted(.currency(code: "EUR")))
                }
                Section("Regole del prezzo") {
                    Stepper("Griglia: \(seller.rules.step.formatted()) €", value: decimal($seller.rules.step), in: 0.5...10, step: 0.5)
                    Stepper("Prezzo minimo: \(seller.rules.minimum.formatted()) €", value: decimal($seller.rules.minimum), in: 0.5...20, step: 0.5)
                    Stepper("Controllo a mano sopra \(Int(seller.rules.reviewAbove)) €", value: $seller.rules.reviewAbove, in: 20...1000, step: 10)
                    Toggle("Tre corsie (lenta / normale / calda)", isOn: Binding(get: { !seller.rules.lanesOff },
                                                                                set: { seller.rules.lanesOff = !$0 }))
                    Text("Base = più basso in vendita, mai sotto il suggerito per il grado. Premi: 0 copie +100%, 1-2 +50%, 3-5 +25%; want/have oltre 1 +10%, oltre 2 +25%, oltre 4 +50%. Arrotondato per eccesso alla griglia.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text("DISCOSIZER SELLER · BUILD 0.1 · KR").font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            .themedBackground()
            .font(Theme.mono(13))
            .navigationTitle("Console")
            .onReceive(timer) { _ in Task { apiUsed = await seller.apiUsedLastMinute() } }
            .task { aiSignedIn = await Backend.shared.accessToken() != nil }
        }
    }

    private func decimal(_ b: Binding<Decimal>) -> Binding<Double> {
        Binding(get: { NSDecimalNumber(decimal: b.wrappedValue).doubleValue },
                set: { b.wrappedValue = Decimal(string: String(format: "%.2f", $0)) ?? 0 })
    }

    private var modeHelp: String {
        switch seller.mode {
        case .superVeloce: "Barcode e scritte trovano i candidati, Vision confronta le copertine. Niente AI, gratis. Copertina non netta = da controllare."
        case .veloce: "Come Super veloce, ma nei casi dubbi la copertina la guarda l'AI."
        case .completa: "Più immagini e candidati; se il testo non basta, l'AI legge la foto."
        }
    }
}
