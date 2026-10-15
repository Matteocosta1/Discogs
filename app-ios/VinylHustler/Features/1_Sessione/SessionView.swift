import AuthenticationServices
import SwiftData
import SwiftUI

/// 01 / SESSIONE — posizione, condizione, poi la fotocamera.
/// Nella fotocamera: uno scatto o un video, e i dischi vengono riconosciuti subito.
/// Sotto, in "Oggi", i dischi riconosciuti aspettano la tua decisione: sì / no, e poi se venderli.
struct SessionView: View {
    @Environment(Seller.self) private var seller
    @Environment(\.modelContext) private var context
    @Query(sort: \Disc.createdAt, order: .reverse) private var discs: [Disc]
    @AppStorage("placeKind") private var placeKind = "Scatola"
    @AppStorage("placeName") private var placeName = "1"
    /// I contenitori creati con "+" (quelli fissi non si salvano: ci sono sempre).
    @AppStorage("placeKindsCustom") private var customRaw = ""
    @AppStorage("placeKindsV2") private var oldKindsRaw = ""      // versione di prima: si recuperano i contenitori creati (es. Casa)
    @State private var removing: String?
    static let fixedKinds = ["Archivio", "Scatola", "Scaffale"]
    @AppStorage("media") private var mediaRaw = Grade.m.rawValue
    @AppStorage("sleeve") private var sleeveRaw = Grade.m.rawValue
    @State private var addingKind = false
    @State private var newKind = ""
    @State private var camera = false
    @State private var breathe = false
    @State private var aiReady = true
    @State private var listings: [Listing] = []        // l'inventario Discogs, come in Magazzino
    @State private var loadingInventory = false
    @State private var info: InfoTopic?

    private var media: Grade { Grade(rawValue: mediaRaw) ?? .m }
    private var sleeve: Grade { Grade(rawValue: sleeveRaw) ?? media }
    private var custom: [String] { customRaw.split(separator: "|").map(String.init).filter { !Self.fixedKinds.contains($0) } }
    /// Archivio, Scatola, Scaffale sempre; poi quelli creati con "+".
    private var kinds: [String] { Self.fixedKinds + custom }
    /// Dove finiscono i dischi: "Scatola 12", "Casa 2", ...
    private var place: String {
        let name = placeName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? placeKind : "\(placeKind) \(name)"
    }
    private var today: [Disc] { discs.filter { Calendar.current.isDateInToday($0.createdAt) && $0.status != .tolto } }

    /// I dischi che aspettano qualcosa in Revisione (da decidere, o col prezzo ma non ancora pubblicati).
    private var inReview: Int {
        discs.filter { [DiscStatus.daConfermare, .daControllare, .bloccato, .pronto].contains($0.status) }.count
    }

    private func loadInventory() async {
        loadingInventory = true
        defer { loadingInventory = false }
        if let l = try? await seller.syncInventory(discs: discs) { listings = l }
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
                    InfoHeader(title: "Posizione") { info = .posizione }
                }

                Section {
                    gradeRow("Vinile", selection: $mediaRaw)
                    gradeRow("Copertina", selection: $sleeveRaw)
                } header: {
                    InfoHeader(title: "Condizione") { info = .condizione }
                }

                Section {
                    cameraButton
                    if !aiReady { AISignInRow { aiReady = true } }
                } header: {
                    InfoHeader(title: "Fotocamera") { info = .fotocamera }
                }

                Section {
                    HStack {
                        stat("\(today.count)", "fotografati")
                        stat(listings.isEmpty && loadingInventory ? "…" : "\(listings.count)", "Discogs")
                        stat("\(inReview)", "bozze")
                    }
                } header: {
                    HUDLabel(number: "04", title: "Oggi")
                }
            }
            .themedBackground()
            .navigationTitle("Foto")
            .refreshable { await Task { await loadInventory() }.value }
            .onAppear {                                  // contenitore scelto che non esiste più: si torna al primo
                if !oldKindsRaw.isEmpty {
                    let extra = oldKindsRaw.split(separator: "|").map(String.init).filter { !Self.fixedKinds.contains($0) && !custom.contains($0) }
                    customRaw = (custom + extra).joined(separator: "|")
                    oldKindsRaw = ""
                }
                if !kinds.contains(placeKind) { placeKind = Self.fixedKinds[0] }
            }
            .task {
                let token = await Backend.shared.accessToken()
                aiReady = !Backend.shared.isConfigured || token != nil
                if listings.isEmpty { await Task { await loadInventory() }.value }
            }
            .confirmationDialog("Eliminare il contenitore \"\(removing ?? "")\"? I dischi già fotografati tengono il loro posto.",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button("Elimina", role: .destructive) {
                    if let r = removing {
                        customRaw = custom.filter { $0 != r }.joined(separator: "|")
                        if placeKind == r { placeKind = Self.fixedKinds[0] }
                    }
                    removing = nil
                }
            }
            .alert("Nuovo contenitore", isPresented: $addingKind) {
                TextField("es. Casa, Cassetta, Mobile…", text: $newKind)
                Button("Aggiungi") { addKind() }
                Button("Annulla", role: .cancel) {}
            }
            .sheet(item: $info) { InfoSheet(topic: $0) }
            .fullScreenCover(isPresented: $camera) {
                OcchioView(place: place, media: media, sleeve: sleeve) { camera = false; Task { await loadInventory() } }
                    .environment(seller)
                    .modelContext(context)
            }
        }
    }

    /// Il tasto che apre la fotocamera: solo il simbolo, grande e al centro. Le spiegazioni stanno nella (i).
    private var cameraButton: some View {
        Button { camera = true } label: {
            ZStack {
                Circle().fill(Color.black).frame(width: 84, height: 84)
                    .overlay(Circle().stroke(Theme.accent, lineWidth: 2))
                    .shadow(color: Theme.glow.opacity(breathe ? 0.75 : 0.25), radius: breathe ? 18 : 6)
                Circle().stroke(Theme.glow.opacity(breathe ? 0 : 0.5), lineWidth: 1)
                    .frame(width: 84, height: 84)
                    .scaleEffect(breathe ? 1.35 : 1)
                Image(systemName: "camera.fill").font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.glow)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Apri la fotocamera")
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
            // tenendo premuto: si può eliminare solo un contenitore creato con "+"
            if !Self.fixedKinds.contains(kind) {
                Button("Elimina \(kind)", systemImage: "trash", role: .destructive) { removing = kind }
            }
        }
    }

    private func addKind() {
        let name = newKind.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: " ")
        guard !name.isEmpty else { return }
        if !kinds.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            customRaw = (custom + [name]).joined(separator: "|")
        }
        placeKind = name
        placeName = ""
    }

    /// Una riga della condizione (come su Discogs: supporto e copertina), senza icone.
    private func gradeRow(_ title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
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
