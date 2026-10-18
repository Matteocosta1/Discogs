import AuthenticationServices
import SwiftData
import SwiftUI

/// 01 / SESSIONE — posizione, condizione, poi la fotocamera.
/// Nella fotocamera: uno scatto o un video, e i dischi vengono riconosciuti subito.
/// I dischi riconosciuti vanno in Revisione.
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

            }
            .themedBackground()
            .navigationTitle("Foto")
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
                OcchioView(place: place, media: media, sleeve: sleeve) { camera = false }
                    .environment(seller)
                    .modelContext(context)
            }
        }
    }

    /// Il tasto che apre la fotocamera: un riquadro largo con il bagliore verde, solo il simbolo (spiegazioni nella (i)).
    private var cameraButton: some View {
        Button { camera = true } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(RadialGradient(colors: [Theme.military, Color(red: 0.043, green: 0.075, blue: 0.051)],
                                         center: .center, startRadius: 0, endRadius: 170))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.accent.opacity(breathe ? 0.75 : 0.4), lineWidth: 1)
                Image(systemName: "camera")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Theme.glow)
                    .shadow(color: Theme.glow.opacity(breathe ? 0.8 : 0.3), radius: breathe ? 12 : 4)
            }
            .frame(height: 120)
            .shadow(color: Theme.accent.opacity(breathe ? 0.3 : 0.12), radius: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Apri la fotocamera")
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { breathe = true }
        }
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

    /// Una riga della condizione (come su Discogs: supporto e copertina): sei pastiglie, quella scelta in verde.
    private func gradeRow(_ title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14)).foregroundStyle(Theme.muted)
            HStack(spacing: 4) {
                ForEach(Grade.allCases) { g in
                    let on = selection.wrappedValue == g.rawValue
                    Button {
                        selection.wrappedValue = g.rawValue
                        Suoni.tocco()
                    } label: {
                        Text(g.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .foregroundStyle(on ? Color.black : Theme.text)
                            .background(on ? Theme.accent : Theme.panelHigh, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .animation(.snappy(duration: 0.2), value: on)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
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
