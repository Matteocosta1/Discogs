import SwiftData
import SwiftUI

/// 05 / CONSOLE — account Discogs, accesso AI, voce, contatore API, regole del prezzo.
struct ConsoleView: View {
    @Environment(Seller.self) private var seller
    @Query private var discs: [Disc]
    @State private var apiUsed = 0
    @State private var aiSignedIn = false
    @AppStorage("voice") private var voice = true
    @AppStorage("userName") private var userName = ""
    @AppStorage("voiceID") private var voiceID = Voice.systemChoice
    @AppStorage("suoni") private var suoni = true
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
                    if !Backend.shared.isConfigured {
                        Text("Supabase non configurato: niente AI, solo barcode e scritte.").font(.caption).foregroundStyle(Theme.warn)
                    } else if aiSignedIn {
                        Label("AI attiva", systemImage: "checkmark.seal").foregroundStyle(Theme.accent)
                        Button("Esci dall'AI", role: .destructive) {
                            Task { await Backend.shared.signOut(); aiSignedIn = false }
                        }
                    } else {
                        AISignInRow { aiSignedIn = true }
                    }
                    LabeledContent("Spesa AI (tutti i dischi)", value: discs.reduce(0) { $0 + $1.aiCost }.formatted(.currency(code: "EUR")))
                }
                Section {
                    Toggle("Ti dice il disco a voce", isOn: $voice)
                    Toggle("Suoni dell'interfaccia", isOn: $suoni)
                    HStack {
                        Text("Ti chiama")
                        TextField("il tuo nome", text: $userName).multilineTextAlignment(.trailing)
                    }
                    Picker("Voce", selection: $voiceID) {
                        Text("Quella di sistema (Impostazioni)").tag(Voice.systemChoice)
                        Text("La migliore italiana").tag("")
                        ForEach(Voice.italianVoices, id: \.identifier) { v in
                            Text(Voice.label(v)).tag(v.identifier)
                        }
                    }
                    Button("Prova la voce") { Voice.shared.say("Ciao\(userName.isEmpty ? "" : " \(userName)"), questo è Kind Of Blue di Miles Davis.") }
                } header: {
                    Text("Voce")
                } footer: {
                    Text(Voice.hasNiceVoice
                         ? "Quando riconosce un disco te lo dice: \"Ciao \(userName.isEmpty ? "Marco" : userName), questo è…\""
                         : "Per una voce più naturale scarica una voce italiana Avanzata o Premium: Impostazioni › Accessibilità › Contenuti letti › Voci › Italiano. Poi sceglila qui.")
                        .font(.caption)
                }
                Section("Regole del prezzo") {
                    Stepper("Griglia: \(seller.rules.step.formatted()) €", value: decimal($seller.rules.step), in: 0.5...10, step: 0.5)
                    Stepper("Prezzo minimo: \(seller.rules.minimum.formatted()) €", value: decimal($seller.rules.minimum), in: 0.5...20, step: 0.5)
                    Toggle("Tre corsie (lenta / normale / calda)", isOn: Binding(get: { !seller.rules.lanesOff },
                                                                                set: { seller.rules.lanesOff = !$0 }))
                    Text("Base = più basso in vendita, mai sotto il suggerito per il grado. Premi: 0 copie +100%, 1-2 +50%, 3-5 +25%; want/have oltre 1 +10%, oltre 2 +25%, oltre 4 +50%. Arrotondato per eccesso alla griglia.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text("VINYL HUSTLER · BUILD 0.1 · KR").font(.caption2.monospaced()).foregroundStyle(.secondary)
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
}
