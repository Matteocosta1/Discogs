import UIKit
import Vision

/// Lettura sul telefono, gratis e senza rete: barcode e testo delle foto (Vision di Apple).
/// Nello script: read_barcodes (zxing) + ocr_lines (ocrmac, che usa lo stesso Vision).
enum PhotoReader {
    /// Barcode EAN/UPC. Vision riporta un UPC-A come EAN-13 con uno 0 davanti: Discogs li trova entrambi.
    static func barcodes(in image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.ean13, .ean8, .upce]
        try VNImageRequestHandler(cgImage: image).perform([request])
        var found: [String] = []
        for obs in request.results ?? [] {
            if let s = obs.payloadStringValue, !found.contains(s) { found.append(s) }
        }
        return found
    }

    /// Righe di testo con la loro altezza (0-1 rispetto alla foto): le più alte sono artista e titolo.
    static func textLines(in image: CGImage) throws -> [Evidence.Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false      // cataloghi e nomi non sono parole di dizionario
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let best = obs.topCandidates(1).first else { return nil }
            return Evidence.Line(text: best.string, height: Double(obs.boundingBox.height))
        }
    }

    /// Tutti gli indizi delle foto di un disco (fronte e retro).
    static func evidence(from images: [UIImage]) -> Evidence {
        var ev = Evidence()
        for image in images {
            guard let cg = image.normalizedCGImage() else { continue }
            for b in (try? barcodes(in: cg)) ?? [] where !ev.barcodes.contains(b) { ev.barcodes.append(b) }
            ev.add(lines: (try? textLines(in: cg)) ?? [])
        }
        return ev
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

    func jpegForUpload(maxSide: CGFloat = 768) -> Data? {
        guard let cg = normalizedCGImage(maxSide: maxSide) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
    }
}
