import SwiftData
import SwiftUI

/// 05 / SETTINGS (prima "Console") — account, nome, valuta, accesso AI, voce, annunci, regole del prezzo.
/// V60 · proposta 12: come JARVIS — riquadri scuri con il bordo verde e i titoli in monospazio al posto dell'elenco
/// grigio di Apple; all'apertura la pagina si stampa dall'alto (0,9 s) con il suono del testo che carica.
/// Le voci e l'ordine sono gli stessi di prima.
struct ConsoleView: View {
    @Environment(Seller.self) private var seller
    @Query private var discs: [Disc]
    @State private var apiUsed = 0
    @State private var aiSignedIn = false
    @State private var stampaDa = Date.distantPast
    @State private var stampaFinita = true
    @AppStorage("voice") private var voice = true
    @AppStorage("userName") private var userName = ""
    @AppStorage("voiceID") private var voiceID = Voice.systemChoice
    @AppStorage("suoni") private var suoni = true
    @AppStorage("voceModo") private var voceModo = (UserDefaults.standard.object(forKey: "voceElevenLabs") as? Bool == false ? "apple" : "eleven")
    @AppStorage("voceVeloce") private var veloce = false
    @AppStorage("vendiModo") private var vendiModo = "subito"
    @AppStorage("offerteDefault") private var offerteDefault = true
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GruppoJarvis("Account") {
                        RigaJarvis { Text("Versione dell'app"); Spacer(); valore(AppVersione.nome) }
                        accountRows
                    } piede: { accountFooter }
                    GruppoJarvis("API Discogs · ultimo minuto") {
                        RigaJarvis {
                            Text("Richieste")
                            Spacer()
                            ProgressView(value: Double(apiUsed), total: 60)
                                .tint(apiUsed > 50 ? Theme.warn : Theme.accent)
                                .frame(maxWidth: 120)
                            valore("\(apiUsed) / 60")
                        }
                    } piede: { Text("Una richiesta al secondo, sempre. Il limite è per telefono (indirizzo IP).") }
                    GruppoJarvis("Riconoscimento") { riconoscimentoRows } piede: { EmptyView() }
                    GruppoJarvis("Voce") { voiceRows } piede: { Text(footer) }
                    GruppoJarvis("Annunci") { annunciRows } piede: { annunciFooter }
                    GruppoJarvis("Regole del prezzo") { prezzoRows } piede: {
                        Text("Base = più basso in vendita, mai sotto il suggerito per il grado. Premi: 0 copie +100%, 1-2 +50%, 3-5 +25%; want/have oltre 1 +10%, oltre 2 +25%, oltre 4 +50%. Arrotondato per eccesso alla griglia.")
                    }
                    Text("VINYL HUSTLER · \(AppVersione.nome) · KR")
                        .font(Theme.mono(10)).tracking(1.5).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                // la pagina si stampa dall'alto, una volta, quando si apre
                .mask {
                    TimelineView(.animation(minimumInterval: 1 / 60, paused: stampaFinita)) { ctx in
                        let x = stampaFinita ? 1 : min(1, max(0, ctx.date.timeIntervalSince(stampaDa) / 0.9))
                        let p = 1 - pow(1 - x, 2.2)
                        GeometryReader { g in
                            VStack(spacing: 0) {
                                Rectangle().frame(height: g.size.height * p)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            .sfondoHUD()
            .senzaTitolo("Settings")
            .onReceive(timer) { _ in Task { apiUsed = await seller.apiUsedLastMinute() } }
            .task { aiSignedIn = await Backend.shared.accessToken() != nil }
            .onAppear {
                stampaDa = Date()
                stampaFinita = false
                Suoni.chatCarica()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(900))
                    Suoni.chatPronta()
                    stampaFinita = true
                }
            }
        }
    }

    private func valore(_ t: String) -> some View {
        Text(t).font(Theme.mono(13)).foregroundStyle(Color(hex: 0xCFE9D3)).lineLimit(1).minimumScaleFactor(0.7)
    }

    // Il corpo è diviso in pezzi: tutto insieme è troppo per il compilatore di Swift.
    @ViewBuilder private var accountRows: some View {
        RigaJarvis {
            Text("Nome")
            TextField("come ti chiami", text: $userName).multilineTextAlignment(.trailing)
                .font(Theme.mono(13)).foregroundStyle(Theme.glow)
        }
        RigaJarvis { Text("Account Discogs"); Spacer(); valore(seller.username.isEmpty ? "—" : seller.username) }
        RigaJarvis {
            Text("Valuta")
            Spacer()
            Picker("Valuta", selection: Binding(get: { UserDefaults.standard.string(forKey: "valuta") ?? "" },
                                                set: { seller.setCurrency($0) })) {
                Text("Come su Discogs (\(seller.discogsCurrency))").tag("")
                ForEach(Seller.currencies, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        }
        RigaJarvis(ultima: true) {
            Button("Cambia account Discogs", role: .destructive) { Suoni.tocco(); seller.logout() }
                .foregroundStyle(Theme.warn)
            Spacer()
        }
    }

    private var accountFooter: some View {
        Text(seller.currency == seller.discogsCurrency
             ? "Il nome è quello con cui ti saluta la voce. La valuta è quella dei prezzi: di solito conviene lasciarla come su Discogs."
             : "Attenzione: su Discogs vendi in \(seller.discogsCurrency). L'app calcola i prezzi in \(seller.currency), ma Discogs li legge nella sua valuta: cambiala anche nelle impostazioni di Discogs, altrimenti i prezzi saranno sbagliati.")
            .foregroundStyle(seller.currency == seller.discogsCurrency ? Theme.muted : Theme.warn)
    }

    @ViewBuilder private var riconoscimentoRows: some View {
        if !Backend.shared.isConfigured {
            RigaJarvis {
                Text("Supabase non configurato: niente AI, solo barcode e scritte.").font(.caption).foregroundStyle(Theme.warn)
            }
        } else if aiSignedIn {
            RigaJarvis {
                Label("AI attiva", systemImage: "checkmark.seal").foregroundStyle(Theme.accent)
                Spacer()
                Button("Esci dall'AI", role: .destructive) {
                    Task { await Backend.shared.signOut(); aiSignedIn = false }
                }
                .foregroundStyle(Theme.warn)
            }
        } else {
            RigaJarvis { AISignInRow { aiSignedIn = true } }
        }
        RigaJarvis(ultima: true) {
            Text("Spesa AI (tutti i dischi)")
            Spacer()
            valore(discs.reduce(0) { $0 + $1.aiCost }.formatted(.currency(code: "EUR")))
        }
    }

    @ViewBuilder private var voiceRows: some View {
        RigaJarvis {
            Picker("Voce", selection: $voceModo) {
                Text("Vinyl Hustler").tag("eleven")
                Text("Apple").tag("apple")
                Text("Nessuna").tag("off")
            }
            .pickerStyle(.segmented)
            .onChange(of: voceModo) { _, m in if m != "off" { voice = true } }
        }
        if voceModo == "eleven" {
            RigaJarvis { Toggle("Modello veloce (Flash)", isOn: $veloce).tint(Theme.accent) }
        }
        if voceModo != "off" {
            RigaJarvis {
                Text(voceModo == "eleven" ? "Riserva senza rete" : "Voce Apple")
                Spacer()
                Picker(voceModo == "eleven" ? "Riserva senza rete" : "Voce Apple", selection: $voiceID) {
                    Text("Quella di sistema (Impostazioni)").tag(Voice.systemChoice)
                    Text("La migliore italiana").tag("")
                    ForEach(Voice.italianVoices, id: \.identifier) { v in
                        Text(Voice.label(v)).tag(v.identifier)
                    }
                }
                .labelsHidden()
            }
            RigaJarvis {
                Button("Prova la voce") { Suoni.tocco(); Voice.shared.sayTitles(["Kind Of Blue di Miles Davis"]) }
                Spacer()
            }
        }
        if voceModo == "eleven" {
            NavigationLink { PronunciaView() } label: {
                RigaJarvis {
                    Text("Pronuncia").foregroundStyle(Theme.text)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                }
            }
            .buttonStyle(.plain)
        }
        RigaJarvis(ultima: true) { Toggle("Suoni dell'interfaccia", isOn: $suoni).tint(Theme.accent) }
    }

    @ViewBuilder private var annunciRows: some View {
        RigaJarvis {
            Text("Vendi")
            Spacer()
            Picker("Vendi", selection: $vendiModo) {
                Text("Subito").tag("subito")
                Text("Prima la scheda").tag("scheda")
            }
            .labelsHidden()
        }
        RigaJarvis { Toggle("Accetta offerte", isOn: $offerteDefault).tint(Theme.accent) }
        NavigationLink { DescrizioneView() } label: {
            RigaJarvis(ultima: true) {
                Text("Descrizione").foregroundStyle(Theme.text)
                Spacer()
                valore((UserDefaults.standard.string(forKey: "descLingua") ?? "en") == "itEn" ? "Italiano + English" : "English")
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
            }
        }
        .buttonStyle(.plain)
    }

    private var annunciFooter: some View {
        Text(vendiModo == "subito"
             ? "Vendi mette il disco online con un tocco. Prezzo e tutto il resto li cambi quando vuoi toccando il disco in Magazzino."
             : "Vendi apre la scheda annuncio già compilata: controlli prezzo, condizioni e descrizione, poi «Metti online».")
    }

    @ViewBuilder private var prezzoRows: some View {
        @Bindable var seller = seller
        RigaJarvis {
            Stepper("Griglia: \(seller.rules.step.formatted()) €", value: decimal($seller.rules.step), in: 0.5...10, step: 0.5)
        }
        RigaJarvis {
            Stepper("Prezzo minimo: \(seller.rules.minimum.formatted()) €", value: decimal($seller.rules.minimum), in: 0.5...20, step: 0.5)
        }
        RigaJarvis(ultima: true) {
            Toggle("Tre corsie (lenta / normale / calda)", isOn: Binding(get: { !seller.rules.lanesOff },
                                                                        set: { seller.rules.lanesOff = !$0 }))
                .tint(Theme.accent)
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

/// V60 · un riquadro di Settings alla JARVIS: titolo in monospazio verde, righe dentro un riquadro scuro con il bordo verde,
/// testo di spiegazione sotto.
struct GruppoJarvis<Righe: View, Piede: View>: View {
    let titolo: String
    @ViewBuilder let righe: () -> Righe
    @ViewBuilder let piede: () -> Piede

    init(_ titolo: String, @ViewBuilder _ righe: @escaping () -> Righe, @ViewBuilder piede: @escaping () -> Piede) {
        self.titolo = titolo
        self.righe = righe
        self.piede = piede
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titolo.uppercased())
                .font(Theme.mono(11, .bold)).tracking(2)
                .foregroundStyle(Theme.glow)
                .shadow(color: Theme.glow.opacity(0.4), radius: 3)
                .padding(.horizontal, 4)
            VStack(spacing: 0) { righe() }
                .padding(.horizontal, 14)
                .background(Theme.glow.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.glow.opacity(0.28), lineWidth: 1))
            piede()
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 4)
        }
    }
}

/// Una riga di un riquadro: alta almeno 44 punti, con la linea verde sotto (tranne l'ultima).
struct RigaJarvis<Contenuto: View>: View {
    var ultima = false
    @ViewBuilder let contenuto: () -> Contenuto

    init(ultima: Bool = false, @ViewBuilder _ contenuto: @escaping () -> Contenuto) {
        self.ultima = ultima
        self.contenuto = contenuto
    }

    var body: some View {
        HStack(spacing: 10) { contenuto() }
            .font(.system(size: 15))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) {
                if !ultima { Rectangle().fill(Theme.glow.opacity(0.12)).frame(height: 1) }
            }
    }
}

/// Console › Voce › Pronuncia: come deve dire certe parole la voce di Vinyl Hustler.
/// Le regole valgono per tutti gli utenti.
struct PronunciaView: View {
    @State private var rules: [Voice.Rule] = []
    @State private var admin = false
    @State private var loading = true
    @State private var word = ""
    @State private var sayAs = ""
    @State private var editing: Voice.Rule?
    @State private var failed = false

    var body: some View {
        Form {
            if admin {
                editor
            } else if !loading {
                Section {
                    Text("Le regole di pronuncia valgono per tutti gli utenti: le cambia solo l'amministratore.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Regole") {
                if loading {
                    ProgressView()
                } else if rules.isEmpty {
                    Text("Nessuna regola").foregroundStyle(.secondary)
                }
                ForEach(rules) { r in
                    if admin {
                        Button {
                            editing = r; word = r.word; sayAs = r.sayAs
                        } label: { row(r) }
                        .swipeActions {
                            Button("Elimina", role: .destructive) { Task { await save(r.word, "") } }
                        }
                    } else {
                        row(r)
                    }
                }
            }
        }
        .themedBackground()
        .navigationTitle("Pronuncia")
        .task { await load() }
        .alert("Non sono riuscito a salvare", isPresented: $failed) { Button("OK") {} }
    }

    private func row(_ r: Voice.Rule) -> some View {
        HStack {
            Text(r.word).foregroundStyle(Theme.text)
            Spacer()
            Text(r.sayAs).foregroundStyle(.secondary)
        }
    }

    private var editor: some View {
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
    }

    private func load() async {
        let out = await Voice.rules()
        rules = out.rules
        admin = out.admin
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

/// Console › Annunci › Descrizione: il testo che finisce in ogni annuncio.
struct DescrizioneView: View {
    @AppStorage("descLingua") private var lingua = ListingText.Language.en.rawValue
    @AppStorage("descCondizione") private var condizione = true
    @AppStorage("descFisso") private var fisso = ""

    private var preview: String {
        ListingText.build(media: Grade.nm.discogs, sleeve: Grade.vgPlus.discogs, tags: ["Apribile", "Inserto incluso"],
                          note: "", language: ListingText.Language(rawValue: lingua) ?? .en,
                          includeCondition: condizione, fixed: fisso)
    }

    var body: some View {
        Form {
            Section {
                Picker("Lingua", selection: $lingua) {
                    Text("English").tag(ListingText.Language.en.rawValue)
                    Text("Italiano + English").tag(ListingText.Language.itEn.rawValue)
                }
                .pickerStyle(.segmented)
                Toggle("Condizione scritta per intero", isOn: $condizione)
            } footer: {
                Text("Su Discogs comprano da tutto il mondo: l'inglese lo capiscono tutti.")
            }
            Section {
                TextEditor(text: $fisso)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
            } header: {
                Text("Testo fisso")
            } footer: {
                Text("In fondo a ogni annuncio. Per esempio: «Ships within 2 days in a sturdy record mailer. Combined shipping available.»")
            }
            Section("Anteprima") {
                Text(preview.isEmpty ? "—" : preview)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
            }
        }
        .themedBackground()
        .navigationTitle("Descrizione")
    }
}
