import SwiftData
import SwiftUI

/// 01 / SESSIONE — si sceglie il grado una volta per tutta la sessione, poi si fotografa ogni disco:
/// fino a sei foto (copertine, centrini, solco, matrice), nessuna obbligatoria.
/// Il riconoscimento parte da solo in sottofondo: intanto si fotografa il disco successivo.
struct SessionView: View {
    @Environment(Seller.self) private var seller
    @Environment(\.modelContext) private var context
    @AppStorage("placeKind") private var placeKind = "Scatola"
    @AppStorage("placeName") private var placeName = "1"
    @AppStorage("placeKinds") private var kindsRaw = "Scatola|Archivio|Cassa|Scaffale"
    @AppStorage("recentPlaces") private var recentRaw = ""
    @State private var addingKind = false
    @State private var newKind = ""
    @AppStorage("media") private var mediaRaw = Grade.m.rawValue
    @AppStorage("sleeve") private var sleeveRaw = Grade.m.rawValue
    @State private var shots: [PhotoKind: UIImage] = [:]
    @State private var shooting: PhotoKind?          // foto aperta nella fotocamera
    @State private var pendingNext: PhotoKind?       // scatto guidato: la prossima da aprire
    @State private var guided = false
    @State private var countToday = 0

    private var media: Grade { Grade(rawValue: mediaRaw) ?? .m }
    private var sleeve: Grade { Grade(rawValue: sleeveRaw) ?? media }
    private var nextEmpty: PhotoKind? { PhotoKind.allCases.first { shots[$0] == nil } }
    private var kinds: [String] { kindsRaw.split(separator: "|").map(String.init) }
    private var recent: [String] { recentRaw.split(separator: "|").map(String.init) }
    /// Dove finiscono i dischi: "Scatola 12", "Archivio B", ...
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
                                Label("Altro", systemImage: "plus").font(Theme.mono(12, .bold))
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .foregroundStyle(Theme.muted)
                                    .overlay(Rectangle().stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                    HStack(spacing: 10) {
                        Text(placeKind.uppercased()).font(Theme.mono(13, .bold)).foregroundStyle(Theme.accent)
                        TextField("numero o nome", text: $placeName).font(Theme.mono(14))
                    }
                    if !recent.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("USATI DI RECENTE").font(Theme.mono(10, .semibold)).tracking(1.2).foregroundStyle(Theme.muted)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(recent, id: \.self) { item in
                                        Button { pick(item) } label: {
                                            Text(item).font(Theme.mono(12))
                                                .padding(.horizontal, 10).padding(.vertical, 6)
                                                .background(item == place ? Theme.military : Theme.panelHigh)
                                                .foregroundStyle(Theme.text)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    HUDLabel(number: "01", title: "Dove li metti")
                } footer: {
                    Text("Scegli o inventa il contenitore (scatola, archivio, cassa…) e scrivi quale. Si salva su ogni disco: lo ritrovi in Magazzino e negli Ordini quando devi spedire.")
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
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(PhotoKind.allCases) { kind in slot(kind) }
                    }
                    .padding(.vertical, 6)
                    shutter
                    Button("Riconosci il disco · \(shots.count) foto") { submit() }
                        .buttonStyle(SignalButtonStyle())
                        .disabled(shots.isEmpty)
                    if !shots.isEmpty {
                        Button("Ricomincia questo disco", role: .destructive) { shots = [:] }
                            .font(Theme.mono(12))
                    }
                } header: {
                    HUDLabel(number: "03", title: "Scatti")
                } footer: {
                    Text("Nessuna foto è obbligatoria: più ne fai, più il riconoscimento è preciso. Tocca un riquadro per rifare quella foto, tienilo premuto per toglierla.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }

                Section {
                    LabeledContent("Dischi fotografati", value: "\(countToday)")
                    LabeledContent("In riconoscimento", value: "\(seller.working)")
                    LabeledContent("Modalità", value: seller.mode.label)
                    if !seller.secondsPerDisc.isEmpty {
                        let avg = seller.secondsPerDisc.reduce(0, +) / Double(seller.secondsPerDisc.count)
                        LabeledContent("Media", value: String(format: "%.0f s a disco", avg))
                    }
                } header: {
                    HUDLabel(number: "04", title: "Oggi")
                }
                .font(Theme.mono(13))
            }
            .themedBackground()
            .navigationTitle("Sessione")
            .alert("Nuovo contenitore", isPresented: $addingKind) {
                TextField("es. Cassetta, Mobile, Stand…", text: $newKind)
                Button("Aggiungi") { addKind() }
                Button("Annulla", role: .cancel) {}
            }
            .fullScreenCover(item: $shooting, onDismiss: {
                if let next = pendingNext {            // scatto guidato: subito la foto successiva
                    pendingNext = nil
                    shooting = next
                }
            }) { kind in
                CameraPicker { image in
                    if let image {
                        shots[kind] = image
                        pendingNext = guided ? PhotoKind.allCases.first { shots[$0] == nil } : nil
                    } else {
                        guided = false                 // annullato: lo scatto guidato si ferma qui
                        pendingNext = nil
                    }
                    shooting = nil
                }
                .ignoresSafeArea()
            }
        }
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
    }

    /// Riprende una collocazione recente ("Scatola 12" -> tipo "Scatola", nome "12").
    private func pick(_ item: String) {
        if let kind = kinds.sorted(by: { $0.count > $1.count }).first(where: { item == $0 || item.hasPrefix($0 + " ") }) {
            placeKind = kind
            placeName = String(item.dropFirst(kind.count)).trimmingCharacters(in: .whitespaces)
        } else {
            placeName = item
        }
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

    /// Il riquadro di una foto: vuoto con l'icona, oppure con lo scatto e la targhetta verde.
    private func slot(_ kind: PhotoKind) -> some View {
        let image = shots[kind]
        return Button {
            guided = false
            shooting = kind
        } label: {
            Rectangle()
                .fill(Theme.panelHigh)
                .frame(height: 118)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                            .padding(.bottom, 26)
                    }
                }
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(kind.number) · \(kind.title.uppercased())").font(Theme.mono(10, .bold))
                        Text(kind.hint).font(Theme.mono(9)).lineLimit(1)
                    }
                    .foregroundStyle(image == nil ? Theme.text : Color.black)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(image == nil ? Color.clear : Theme.accent)
                }
                .overlay(Rectangle().stroke(image == nil ? Theme.line : Theme.accent, lineWidth: image == nil ? 1 : 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if image != nil {
                Button("Togli questa foto", systemImage: "trash", role: .destructive) { shots[kind] = nil }
            }
        }
    }

    /// Scatto guidato: apre la fotocamera sulla prima foto mancante e passa da sola alle successive.
    /// Annullando la fotocamera ci si ferma (le foto che mancano restano facoltative).
    private var shutter: some View {
        Button {
            guard let first = nextEmpty else { return }
            guided = true
            shooting = first
        } label: {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Theme.accent, lineWidth: 3).frame(width: 64, height: 64)
                    Circle().fill(Theme.accent).frame(width: 52, height: 52)
                    Image(systemName: "camera.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(Color.black)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("SCATTO GUIDATO").font(Theme.display(24)).foregroundStyle(Theme.text)
                    Text(nextEmpty.map { "PROSSIMA: \($0.title.uppercased())" } ?? "TUTTE LE FOTO FATTE")
                        .font(Theme.mono(10, .semibold)).tracking(1.2).foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(nextEmpty == nil)
    }

    private func submit() {
        let ordered = PhotoKind.allCases.compactMap { kind in shots[kind].map { (kind: kind, image: $0) } }
        seller.addDisc(photos: ordered, lot: place, media: media, sleeve: sleeve, context: context)
        recentRaw = ([place] + recent.filter { $0 != place }).prefix(8).joined(separator: "|")
        shots = [:]
        countToday += 1
    }
}

/// Fotocamera di sistema. (Più avanti: fotocamera guidata con cornice e lettura del barcode dal vivo
/// con VisionKit DataScannerViewController.)
struct CameraPicker: UIViewControllerRepresentable {
    var onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}
