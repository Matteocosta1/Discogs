import SwiftData
import SwiftUI

/// 01 / SESSIONE — si fotografa il disco (fronte, poi retro) con il grado scelto una volta per la sessione.
/// Il riconoscimento parte da solo in sottofondo: intanto si fotografa il disco successivo.
struct SessionView: View {
    @Environment(Seller.self) private var seller
    @Environment(\.modelContext) private var context
    @AppStorage("lot") private var lot = "Lotto 01"
    @AppStorage("media") private var mediaRaw = Grade.m.rawValue
    @AppStorage("sleeve") private var sleeveRaw = Grade.m.rawValue
    @State private var front: UIImage?
    @State private var showCamera = false
    @State private var wantBack = false
    @State private var countToday = 0

    private var media: Grade { Grade(rawValue: mediaRaw) ?? .m }
    private var sleeve: Grade { Grade(rawValue: sleeveRaw) ?? media }

    var body: some View {
        NavigationStack {
            Form {
                Section("Lotto") {
                    TextField("Nome del lotto", text: $lot)
                }
                Section("Grado (vale per tutti i dischi della sessione)") {
                    Picker("Disco", selection: $mediaRaw) {
                        ForEach(Grade.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }.pickerStyle(.segmented)
                    Picker("Copertina", selection: $sleeveRaw) {
                        ForEach(Grade.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }.pickerStyle(.segmented)
                }
                Section {
                    Button {
                        showCamera = true
                    } label: {
                        Label(front == nil ? "Fotografa il FRONTE" : "Ora il RETRO", systemImage: "camera.fill")
                            .font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    if front != nil {
                        Button("Ricomincia questo disco", role: .destructive) { front = nil }
                    }
                }
                Section("Oggi") {
                    LabeledContent("Dischi fotografati", value: "\(countToday)")
                    LabeledContent("In riconoscimento", value: "\(seller.working)")
                    LabeledContent("Modalità", value: seller.mode.label)
                    if !seller.secondsPerDisc.isEmpty {
                        let avg = seller.secondsPerDisc.reduce(0, +) / Double(seller.secondsPerDisc.count)
                        LabeledContent("Media", value: String(format: "%.0f s a disco", avg))
                    }
                }
            }
            .navigationTitle("Sessione")
            .fullScreenCover(isPresented: $showCamera, onDismiss: {
                if wantBack, front != nil { wantBack = false; showCamera = true }   // subito il retro
            }) {
                CameraPicker { image in
                    showCamera = false
                    guard let image else { return }
                    if let f = front {
                        seller.addDisc(front: f, back: image, lot: lot, media: media, sleeve: sleeve, context: context)
                        front = nil
                        countToday += 1
                    } else {
                        front = image
                        wantBack = true
                    }
                }
                .ignoresSafeArea()
            }
        }
    }
}

/// Fotocamera di sistema. (Più avanti: fotocamera guidata con cornice e lettura del barcode dal vivo
/// con VisionKit DataScannerViewController, come nel mockup.)
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
