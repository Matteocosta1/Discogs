import UIKit
import Vision

/// Lettura sul telefono, gratis e senza rete (Vision di Apple): il barcode, che basta da solo a trovare
/// il disco su Discogs, e le scritte più grandi, che servono solo se l'AI non è disponibile.
enum PhotoReader {
    /// Barcode EAN/UPC. Vision riporta un UPC-A come EAN-13 con uno 0 davanti: Discogs li trova entrambi.
    static func barcodes(in image: UIImage) -> [String] {
        guard let cg = image.normalizedCGImage() else { return [] }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.ean13, .ean8, .upce]
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        var found: [String] = []
        for obs in request.results ?? [] {
            if let s = obs.payloadStringValue, !found.contains(s) { found.append(s) }
        }
        return found
    }

    /// Le scritte più grandi della foto (di solito artista e titolo), dalla più alta.
    static func bigText(in image: UIImage) -> String {
        guard let cg = image.normalizedCGImage() else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        let lines = (request.results ?? []).compactMap { obs in
            obs.topCandidates(1).first.map { (text: $0.string, height: Double(obs.boundingBox.height)) }
        }
        return lines.sorted { $0.height > $1.height }.prefix(3).map(\.text).joined(separator: " ")
    }
}

extension UIImage {
    /// CGImage con l'orientamento corretto (le foto della fotocamera sono spesso ruotate nei metadati).
    func normalizedCGImage(maxSide: CGFloat = 2000) -> CGImage? {
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }.cgImage
    }

    func jpegForUpload(maxSide: CGFloat = 1024) -> Data? {
        guard let cg = normalizedCGImage(maxSide: maxSide) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.75)
    }
}
