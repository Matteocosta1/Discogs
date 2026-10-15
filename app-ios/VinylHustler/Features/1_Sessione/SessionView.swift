import AuthenticationServices
import SwiftData
import SwiftUI

/// 01 / SESSIONE — dove li metti, il grado, poi la fotocamera.
/// Nella fotocamera: uno scatto o un video, e i dischi vengono riconosciuti subito.
/// Sotto, in "Oggi", i dischi riconosciuti aspettano la tua decisione: sì / no, e poi se venderli.
struct SessionView: View {
    @Environment(Seller.self) private var seller
    @Environment(\.modelContext) private var context
    @Query(sort: \Disc.createdAt, order: .reverse) private var discs: [Disc]
    @AppStorage("placeKind") private var placeKind = "Scatola"
    @AppStorage("placeName") private var placeName = "1"
    @AppStorage("placeKindsV2") private var kindsRaw = "Scatola|Archivio|Scaffale"
    @AppStorage("media") private var mediaRaw = Grade.m.rawValue
    @AppStorage("sleeve") private var sleeveRaw = Grade.m.rawValue
    @State private var addingKind = false
    @State private var newKind = ""
    @State private var camera = false
    @State private var aiReady = true

    private var media: Grade { Grade(rawValue: mediaRaw) ?? .m }
    private var sleeve: Grade { Grade(rawValue: sleeveRaw) ?? media }
    private var kinds: [String] { kindsRaw.split(separator: "|").map(String.init) }
    /// Dove finiscono i dischi: "Scatola 12", "Casa 2", ...
    private var place: String {
        let name = placeName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? placeKind : "\(placeKind) \(name)"
    }
    private var today: [Disc] { discs.filter { Calendar.current.isDateInToday($0.createdAt) && $0.status != .tolto } }
    /// Quelli che aspettano una decisione (i "Dopo" e quelli già online stanno in Revisione).
    private var waiting: [Disc] {
        today.filter { !$0.parked && ![DiscStatus.inVendita, .bozza].contains($0.status) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(kinds, id: \.self) { kind in kindChip(kind) }
                            Button {
                                newKind = ""
                                addingKind = true
                            } label: {
                                Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                                    .frame(width: 40, height: 33)
                                    .foregroundStyle(Theme.muted)
                                    .overlay(Rectangle().stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Aggiungi un contenitore")
                        }
                        .padding(.vertical, 2)
                    }
                    HStack(spacing: 10) {
                        Text(placeKind.uppercased()).font(Theme.mono(13, .bold)).foregroundStyle(Theme.accent)
                        TextField("numero o nome", text: $placeName).font(Theme.mono(14))
                    }
                } header: {
                    HUDLabel(number: "01", title: "Dove li metti")
                } footer: {
                    Text("Ogni disco che fotografi si porta dietro questo posto: lo ritrovi sulla scheda del disco, in Magazzino, negli Ordini (\"preleva da…\") e sull'annuncio Discogs, nel campo privato che vedi solo tu.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }

                Section {
                    gradeRow("Vinile", symbol: "opticaldisc", selection: $mediaRaw)
                    gradeRow("Copertina", symbol: "square", selection: $sleeveRaw)
                } header: {
                    HUDLabel(number: "02", title: "Grado")
                } footer: {
                    Text("Vale per tutti i vinili della sessione. Cambialo quando passi a un blocco di dischi diverso.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }

                Section {
                    cameraButton
                    if !aiReady { AISignInRow { aiReady = true } }
                } header: {
                    HUDLabel(number: "03", title: "Scatti")
                } footer: {
                    Text("Una foto basta: copertina, retro o centrino. Col video passi più dischi davanti al telefono e li riconosce tutti.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }

                Section {
                    HStack {
                        stat("\(today.count)", "fotografati")
                        stat("\(today.filter { [DiscStatus.inVendita, .bozza].contains($0.status) }.count)", "su Discogs")
                        stat("\(seller.working)", "in corso")
                    }
                    ForEach(waiting) { disc in
                        DiscRow(disc: disc)
                            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    HUDLabel(number: "04", title: "Oggi")
                } footer: {
                    if waiting.isEmpty && !today.isEmpty {
                        Text("Tutto deciso. Quelli messi su \"Dopo\" li trovi in Revisione.")
                            .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                }
            }
            .themedBackground()
            .navigationTitle("Sessione")
            .onAppear {                                  // contenitore scelto che non esiste più: si torna al primo
                if !kinds.contains(placeKind) { placeKind = kinds.first ?? "Scatola" }
            }
            .task {
                let token = await Backend.shared.accessToken()
                aiReady = !Backend.shared.isConfigured || token != nil
            }
            .alert("Nuovo contenitore", isPresented: $addingKind) {
                TextField("es. Casa, Cassetta, Mobile…", text: $newKind)
                Button("Aggiungi") { addKind() }
                Button("Annulla", role: .cancel) {}
            }
            .fullScreenCover(isPresented: $camera) {
                OcchioView(place: place, media: media, sleeve: sleeve) { camera = false }
                    .environment(seller)
                    .modelContext(context)
            }
        }
    }

    /// Il tasto che apre la fotocamera: grande, chiaro, impossibile non vederlo.
    private var cameraButton: some View {
        Button { camera = true } label: {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Theme.accent, lineWidth: 3).frame(width: 66, height: 66)
                    Circle().fill(Theme.accent).frame(width: 54, height: 54)
                    Image(systemName: "camera.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(Color.black)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("APRI LA FOTOCAMERA").font(Theme.display(24)).foregroundStyle(Theme.text)
                    Text("SCATTO = UN DISCO · REC = TANTI DISCHI")
                        .font(Theme.mono(10, .semibold)).tracking(1.2).foregroundStyle(Theme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.accent)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.display(26)).foregroundStyle(Theme.text)
            Text(label.uppercased()).font(Theme.mono(9, .semibold)).tracking(1).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Il tipo di contenitore come pastiglia: verde se scelto. Tenendolo premuto si toglie.
    private func kindChip(_ kind: String) -> some View {
        Button { placeKind = kind } label: {
            Text(kind.uppercased()).font(Theme.mono(12, .bold)).tracking(1)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(kind == placeKind ? Color.black : Theme.text)
                .background(kind == placeKind ? Theme.accent : Theme.panelHigh)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if kinds.count > 1 {
                Button("Togli \(kind)", systemImage: "trash", role: .destructive) {
                    kindsRaw = kinds.filter { $0 != kind }.joined(separator: "|")
                    if placeKind == kind { placeKind = kinds.first ?? "Scatola" }
                }
            }
        }
    }

    private func addKind() {
        let name = newKind.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: " ")
        guard !name.isEmpty else { return }
        if !kinds.contains(name) { kindsRaw = (kinds + [name]).joined(separator: "|") }
        placeKind = name
        placeName = ""
    }

    /// Una riga del grado: cosa si sta gradando, scritto chiaro, e i sei gradi.
    private func gradeRow(_ title: String, symbol: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title.uppercased(), systemImage: symbol)
                .font(Theme.mono(12, .bold)).tracking(1.2).foregroundStyle(Theme.text)
            Picker(title, selection: selection) {
                ForEach(Grade.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

/// Accesso con Apple: serve per il riconoscimento AI (la chiave sta sul server, non nel telefono).
/// Al primo accesso Apple dà anche il nome: lo usa la voce ("Ciao Marco…").
struct AISignInRow: View {
    var done: () -> Void
    @AppStorage("userName") private var userName = ""
    @State private var nonce = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACCEDI PER IL RICONOSCIMENTO AI · SENZA, LEGGE SOLO BARCODE E SCRITTE")
                .font(Theme.mono(10, .semibold)).tracking(1).foregroundStyle(Theme.warn)
            SignInWithAppleButton(.signIn) { request in
                nonce = UUID().uuidString
                request.requestedScopes = [.fullName, .email]
                request.nonce = Backend.sha256(nonce)
            } onCompletion: { result in
                guard case .success(let auth) = result,
                      let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                      let tokenData = cred.identityToken, let token = String(data: tokenData, encoding: .utf8) else { return }
                if userName.isEmpty, let given = cred.fullName?.givenName, !given.isEmpty { userName = given }
                Task {
                    try? await Backend.shared.signInWithApple(idToken: token, nonce: nonce)
                    if await Backend.shared.accessToken() != nil { done() }
                }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 44)
        }
        .padding(.vertical, 4)
    }
}
