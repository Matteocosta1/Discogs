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
    @State private var breathe = false
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
                                Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                                    .frame(width: 40, height: 34)
                                    .foregroundStyle(Theme.accent)
                                    .background(Theme.panelHigh, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Aggiungi un contenitore")
                        }
                        .padding(.vertical, 2)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "archivebox.fill").foregroundStyle(Theme.accent)
                        Text(placeKind).font(.system(size: 17, weight: .semibold))
                        TextField("numero o nome", text: $placeName).font(.system(size: 17))
                            .foregroundStyle(Theme.glow)
                    }
                } header: {
                    HUDLabel(number: "01", title: "Dove li metti")
                } footer: {
                    Text("Ogni disco che fotografi si porta dietro questo posto: lo ritrovi sulla scheda del disco, in Magazzino, negli Ordini (\"preleva da…\") e sull'annuncio Discogs, nel campo privato che vedi solo tu.")
                }

                Section {
                    cameraButton
                    if !aiReady { AISignInRow { aiReady = true } }
                } header: {
                    HUDLabel(number: "02", title: "Scatti")
                } footer: {
                    Text("Una foto basta: copertina, retro o centrino. Col video passi più dischi davanti al telefono e li riconosce tutti.")
                }

                Section {
                    gradeRow("Vinile", symbol: "opticaldisc", selection: $mediaRaw)
                    gradeRow("Copertina", symbol: "square", selection: $sleeveRaw)
                } header: {
                    HUDLabel(number: "03", title: "Grado")
                } footer: {
                    Text("Vale per i prossimi scatti e video. Cambialo quando passi a un blocco di dischi diverso.")
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
                    Circle().fill(Color.black).frame(width: 60, height: 60)
                        .overlay(Circle().stroke(Theme.accent, lineWidth: 2))
                        .shadow(color: Theme.glow.opacity(breathe ? 0.75 : 0.25), radius: breathe ? 16 : 6)
                    Circle().stroke(Theme.glow.opacity(breathe ? 0 : 0.5), lineWidth: 1)
                        .frame(width: 60, height: 60)
                        .scaleEffect(breathe ? 1.35 : 1)
                    Image(systemName: "camera.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.glow)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apri la fotocamera").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                    Text("Scatto = un disco · REC = tanti dischi")
                        .font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) { breathe = true }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 28, weight: .bold)).foregroundStyle(value == "0" ? Theme.text : Theme.glow)
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Il tipo di contenitore come pastiglia: verde se scelto. Tenendolo premuto si toglie.
    private func kindChip(_ kind: String) -> some View {
        Button { placeKind = kind } label: {
            Text(kind).font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(kind == placeKind ? Color.black : Theme.text)
                .background(kind == placeKind ? Theme.accent : Theme.panelHigh, in: Capsule())
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
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                .tint(Theme.accent)
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
            Text("Accedi per il riconoscimento AI. Senza, legge solo barcode e scritte.")
                .font(.system(size: 14)).foregroundStyle(Theme.muted)
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
