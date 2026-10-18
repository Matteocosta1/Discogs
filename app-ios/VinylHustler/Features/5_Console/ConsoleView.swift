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
    @AppStorage("voceModo") private var voceModo = (UserDefaults.standard.object(forKey: "voceElevenLabs") as? Bool == false ? "apple" : "eleven")
    @AppStorage("voceVeloce") private var veloce = false
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
                    Picker("Voce", selection: $voceModo) {
                        Text("Vinyl Hustler").tag("eleven")
                        Text("Apple").tag("apple")
                        Text("Nessuna").tag("off")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: voceModo) { _, m in if m != "off" { voice = true } }
                    if voceModo != "off" {
                        HStack {
                            Text("Ti chiama")
                            TextField("il tuo nome", text: $userName).multilineTextAlignment(.trailing)
                        }
                    }
                    if voceModo == "eleven" {
                        Toggle("Modello veloce (Flash, metà prezzo)", isOn: $veloce)
                    }
                    if voceModo != "off" {
                        Picker(voceModo == "eleven" ? "Riserva senza rete" : "Voce Apple", selection: $voiceID) {
                            Text("Quella di sistema (Impostazioni)").tag(Voice.systemChoice)
                            Text("La migliore italiana").tag("")
                            ForEach(Voice.italianVoices, id: \.identifier) { v in
                                Text(Voice.label(v)).tag(v.identifier)
                            }
                        }
                        Button("Prova la voce") { Voice.shared.sayTitles(["Kind Of Blue di Miles Davis"]) }
                    }
                    if voceModo == "eleven" {
                        NavigationLink("Pronuncia") { PronunciaView() }
                    }
                    Toggle("Suoni dell'interfaccia", isOn: $suoni)
                } header: {
                    Text("Voce")
                } footer: {
                    Text(footer).font(.caption)
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

    private var footer: String {
        switch voceModo {
        case "eleven": "La voce di Vinyl Hustler. Ogni frase si genera una volta sola per tutti gli utenti: le volte dopo è gratis e parte subito."
        case "apple": Voice.hasNiceVoice
            ? "La voce del telefono: gratis, anche senza rete."
            : "La voce del telefono: gratis, anche senza rete. Per una voce più naturale scarica una voce italiana Avanzata o Premium: Impostazioni › Accessibilità › Contenuti letti › Voci › Italiano."
        default: "L'app non parla. I dischi trovati li vedi sullo schermo."
        }
    }

    private func decimal(_ b: Binding<Decimal>) -> Binding<Double> {
        Binding(get: { NSDecimalNumber(decimal: b.wrappedValue).doubleValue },
                set: { b.wrappedValue = Decimal(string: String(format: "%.2f", $0)) ?? 0 })
    }
}

/// Console › Voce › Pronuncia: come deve dire certe parole la voce di Vinyl Hustler.
/// Le regole valgono per tutti gli utenti.
struct PronunciaView: View {
    @State private var rules: [Voice.Rule] = []
    @State private var loading = true
    @State private var word = ""
    @State private var sayAs = ""
    @State private var editing: Voice.Rule?
    @State private var failed = false

    var body: some View {
        Form {
            Section {
                TextField("Parola scritta (es. Miles Davis)", text: $word)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Come dirla (es. Màils Dèivis)", text: $sayAs)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    Button("Ascolta") { Voice.shared.say(sayAs) }
                        .disabled(sayAs.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    Button("Salva") { Task { await save(word, sayAs) } }
                        .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty || sayAs.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .buttonStyle(.borderless)
            } header: {
                Text(editing == nil ? "Nuova regola" : "Modifica")
            } footer: {
                Text("Scrivi la parola come si legge in italiano, con gli accenti dove cade la voce. Vale per tutti gli utenti di Vinyl Hustler.")
            }
            Section("Regole") {
                if loading {
                    ProgressView()
                } else if rules.isEmpty {
                    Text("Nessuna regola").foregroundStyle(.secondary)
                }
                ForEach(rules) { r in
                    Button {
                        editing = r; word = r.word; sayAs = r.sayAs
                    } label: {
                        HStack {
                            Text(r.word).foregroundStyle(Theme.text)
                            Spacer()
                            Text(r.sayAs).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Elimina", role: .destructive) { Task { await save(r.word, "") } }
                    }
                }
            }
        }
        .themedBackground()
        .navigationTitle("Pronuncia")
        .task { await load() }
        .alert("Non sono riuscito a salvare", isPresented: $failed) { Button("OK") {} }
    }

    private func load() async {
        rules = await Voice.rules()
        loading = false
    }

    private func save(_ w: String, _ s: String) async {
        if await Voice.setRule(word: w.trimmingCharacters(in: .whitespaces), say: s.trimmingCharacters(in: .whitespaces)) {
            word = ""; sayAs = ""; editing = nil
            await load()
        } else {
            failed = true
        }
    }
}
