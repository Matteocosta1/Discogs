import AuthenticationServices
import SwiftData
import SwiftUI

/// 01 / FOTO — posizione, condizione, commenti, poi la fotocamera. Pagina ferma, senza scorrere.
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


    @AppStorage("commentoSessione") private var commento = ""
    @FocusState private var scrivo: Bool

    var body: some View {
        NavigationStack {
            // Una pagina sola, ferma: niente da scorrere. La fotocamera prende tutto lo spazio che resta.
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Spacer()
                    // la versione installata: per confrontare a colpo d'occhio due telefoni
                    Text(AppVersione.nome).font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.muted)
                }
                .padding(.top, 6)

                block("Posizione", .posizione) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(kinds, id: \.self) { kind in kindChip(kind) }
                            Button {
                                newKind = ""
                                addingKind = true
                            } label: {
                                Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                                    .frame(width: 36, height: 30)
                                    .foregroundStyle(Theme.accent)
                                    .background(Theme.panelHigh, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Aggiungi un contenitore")
                        }
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "archivebox.fill").font(.system(size: 14)).foregroundStyle(Theme.accent)
                        Text(placeKind).font(.system(size: 16, weight: .semibold))
                        TextField("numero o nome", text: $placeName).font(.system(size: 16))
                            .foregroundStyle(Theme.glow)
                            .focused($scrivo)
                    }
                }

                block("Condizione", .condizione) {
                    gradeRow("Vinile", selection: $mediaRaw)
                    gradeRow("Copertina", selection: $sleeveRaw)
                }

                block("Commenti", .commenti) {
                    TextField("Vale per tutti i dischi che fotografi (es. «Copertina con segni da scaffale»)",
                              text: $commento, axis: .vertical)
                        .font(.system(size: 15))
                        .lineLimit(2...3)
                        .focused($scrivo)
                }

                VStack(alignment: .leading, spacing: 6) {
                    InfoHeader(title: "Fotocamera") { info = .fotocamera }
                    cameraButton
                    if !aiReady { AISignInRow { aiReady = true } }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.bg.ignoresSafeArea())
            .ignoresSafeArea(.keyboard, edges: .bottom)       // la tastiera copre la fotocamera, non sposta la pagina
            .contentShape(Rectangle())
            .onTapGesture { scrivo = false }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Fine") { scrivo = false }.tint(Theme.accent)
                }
            }
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

    /// Una sezione: titolo con la (i) e il contenuto in una scheda grigia, compatta.
    private func block<Content: View>(_ title: String, _ topic: InfoTopic, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            InfoHeader(title: title) { info = topic }
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
    }

    /// Il tasto che apre la fotocamera: nero, pulito, con pochi dettagli verde Discosizer
    /// (angoli del mirino, l'obiettivo, una spia). Riempie lo spazio che resta nella pagina.
    private var cameraButton: some View {
        Button { camera = true } label: {
            Pulsa(periodo: 3.6) { respiro in
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                Angoli()
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .padding(18)
                    .opacity(0.55 + 0.45 * respiro)
                VStack(spacing: 10) {
                    Image(systemName: "camera")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.text)
                    HStack(spacing: 6) {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                            .shadow(color: Theme.glow, radius: 1 + 3 * respiro)
                        Text("APRI").font(Theme.mono(11, .bold)).tracking(2.5).foregroundStyle(Theme.accent)
                    }
                }
            }
            .frame(minHeight: 110, maxHeight: .infinity)
            .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Apri la fotocamera")
    }

    /// Il tipo di contenitore come pastiglia: verde se scelto. Tenendolo premuto si toglie.
    private func kindChip(_ kind: String) -> some View {
        Button { placeKind = kind } label: {
            Text(kind).font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
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
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.muted)
            HStack(spacing: 4) {
                ForEach(Grade.allCases) { g in
                    let on = selection.wrappedValue == g.rawValue
                    Button {
                        selection.wrappedValue = g.rawValue
                        Suoni.tocco()
                    } label: {
                        Text(g.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .foregroundStyle(on ? Color.black : Theme.text)
                            .background(on ? Theme.accent : Theme.panelHigh, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .animation(.snappy(duration: 0.2), value: on)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }
}

/// I quattro angoli del mirino, verdi: il solo dettaglio colorato del tasto fotocamera.
struct Angoli: Shape {
    func path(in r: CGRect) -> Path {
        let l = min(r.width, r.height) * 0.16
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + l, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        return p
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
