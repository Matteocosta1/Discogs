import SwiftData
import SwiftUI

/// 01 / SESSIONE — si sceglie il grado una volta per tutta la sessione, poi si fotografa ogni disco:
/// fino a sei foto (copertine, centrini, solco, matrice), nessuna obbligatoria.
/// Il riconoscimento parte da solo in sottofondo: intanto si fotografa il disco successivo.
struct SessionView: View {
    @Environment(Seller.self) private var seller
    @Environment(\.modelContext) private var context
    @AppStorage("lot") private var lot = "Lotto 01"
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nome del lotto", text: $lot).font(Theme.mono(14))
                } header: {
                    HUDLabel(number: "01", title: "Lotto")
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
        seller.addDisc(photos: ordered, lot: lot, media: media, sleeve: sleeve, context: context)
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
