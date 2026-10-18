import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Vision

/// RITAGLIO — come "Scansiona documenti" dell'iPhone, ma per i dischi.
/// Nella foto cerca la copertina (un quadrato, anche storto o in prospettiva) e la raddrizza;
/// se non c'è, cerca il disco o l'etichetta (un cerchio) e ritaglia il quadrato intorno.
/// All'AI arriva solo il disco, senza tavolo, mani e sfondo: più dettaglio dove serve, meno confusione.
/// Se non trova niente di sicuro, la foto resta com'è: meglio intera che tagliata male.
enum Ritaglio {
    enum Tipo: String { case copertina, disco, intera }

    /// La richiesta che cerca la copertina: quasi quadrata, grande almeno un terzo dell'inquadratura.
    static func richiestaCopertina() -> VNDetectRectanglesRequest {
        let r = VNDetectRectanglesRequest()
        r.minimumAspectRatio = 0.55          // lato corto / lato lungo: dal quadrato a un retro un po' lungo
        r.maximumAspectRatio = 1.0
        r.minimumSize = 0.3
        r.quadratureTolerance = 30            // gradi: la copertina può essere inclinata
        r.minimumConfidence = 0.55
        r.maximumObservations = 1
        return r
    }

    // MARK: - Dal vivo (mirino)

    /// I 4 angoli della copertina in un fotogramma della fotocamera, nelle coordinate della fotocamera
    /// (0…1, origine in alto a sinistra del sensore), pronti per AVCaptureVideoPreviewLayer. nil = niente.
    static func riquadro(in buffer: CVPixelBuffer) -> [CGPoint]? {
        let richiesta = richiestaCopertina()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        guard (try? handler.perform([richiesta])) != nil, let r = richiesta.results?.first else { return nil }
        // Vision ha l'origine in basso a sinistra: si capovolge la y
        return [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft].map { CGPoint(x: $0.x, y: 1 - $0.y) }
    }

    // MARK: - Sulla foto scattata

    /// La foto ritagliata sul disco (JPEG), e cosa ha trovato.
    static func disco(_ dati: Data) -> (dati: Data, tipo: Tipo) {
        guard let immagine = CIImage(data: dati, options: [.applyOrientationProperty: true]) else { return (dati, .intera) }
        let estensione = immagine.extent
        guard estensione.width > 10, estensione.height > 10 else { return (dati, .intera) }
        let contesto = CIContext()

        // per cercare basta un'immagine piccola: è molto più veloce
        let scala = min(1, 1024 / max(estensione.width, estensione.height))
        let piccola = immagine.transformed(by: CGAffineTransform(scaleX: scala, y: scala))
        guard let cg = contesto.createCGImage(piccola, from: piccola.extent) else { return (dati, .intera) }

        if let raddrizzata = copertina(in: cg, originale: immagine), let jpeg = jpeg(raddrizzata, contesto) {
            return (jpeg, .copertina)
        }
        if let quadrato = cerchio(in: cg, originale: immagine), let jpeg = jpeg(quadrato, contesto) {
            return (jpeg, .disco)
        }
        return (dati, .intera)
    }

    /// Copertina trovata: raddrizzata come un documento scansionato.
    private static func copertina(in cg: CGImage, originale: CIImage) -> CIImage? {
        let richiesta = richiestaCopertina()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        guard (try? handler.perform([richiesta])) != nil, let r = richiesta.results?.first else { return nil }
        let e = originale.extent
        func punto(_ p: CGPoint) -> CIVector {      // stesse coordinate di Core Image: origine in basso a sinistra
            CIVector(x: e.minX + p.x * e.width, y: e.minY + p.y * e.height)
        }
        guard let filtro = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filtro.setValue(originale, forKey: kCIInputImageKey)
        filtro.setValue(punto(r.topLeft), forKey: "inputTopLeft")
        filtro.setValue(punto(r.topRight), forKey: "inputTopRight")
        filtro.setValue(punto(r.bottomRight), forKey: "inputBottomRight")
        filtro.setValue(punto(r.bottomLeft), forKey: "inputBottomLeft")
        guard let uscita = filtro.outputImage, uscita.extent.width > 200, uscita.extent.height > 200 else { return nil }
        let rapporto = uscita.extent.width / uscita.extent.height
        guard rapporto > 0.5, rapporto < 2 else { return nil }      // una striscia non è una copertina
        return uscita
    }

    /// Disco o etichetta: il cerchio più grande e ben tondo; si ritaglia il quadrato intorno, con un filo di margine.
    private static func cerchio(in cg: CGImage, originale: CIImage) -> CIImage? {
        let richiesta = VNDetectContoursRequest()
        richiesta.contrastAdjustment = 1.6
        richiesta.maximumImageDimension = 512
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        guard (try? handler.perform([richiesta])) != nil, let osservazione = richiesta.results?.first else { return nil }
        let w = Double(cg.width), h = Double(cg.height)
        var migliore: CGRect?
        var area = 0.0
        for contorno in osservazione.topLevelContours {
            let box = contorno.normalizedPath.boundingBox
            let bw = Double(box.width) * w, bh = Double(box.height) * h
            guard box.width > 0.3 || box.height > 0.3 else { continue }        // piccolo: non è il disco
            let forma = bw / max(bh, 1)
            guard forma > 0.85, forma < 1.18 else { continue }                  // non abbastanza tondo
            // un cerchio riempie circa il 78% del suo quadrato (π/4)
            let punti = contorno.normalizedPoints
            guard punti.count > 12 else { continue }
            var doppia = 0.0
            for i in 0..<punti.count {
                let a = punti[i], b = punti[(i + 1) % punti.count]
                doppia += Double(a.x) * w * Double(b.y) * h - Double(b.x) * w * Double(a.y) * h
            }
            let pieno = abs(doppia) / 2 / (bw * bh)
            guard pieno > 0.68, pieno < 0.88 else { continue }
            if bw * bh > area { area = bw * bh; migliore = box }
        }
        guard let box = migliore else { return nil }
        let e = originale.extent
        let lato = max(box.width * e.width, box.height * e.height) * 1.06
        let centro = CGPoint(x: e.minX + box.midX * e.width, y: e.minY + box.midY * e.height)
        let taglio = CGRect(x: centro.x - lato / 2, y: centro.y - lato / 2, width: lato, height: lato).intersection(e)
        guard taglio.width * taglio.height > e.width * e.height * 0.15 else { return nil }   // troppo piccolo: meglio intera
        return originale.cropped(to: taglio)
    }

    private static func jpeg(_ immagine: CIImage, _ contesto: CIContext) -> Data? {
        let pulita = immagine.transformed(by: CGAffineTransform(translationX: -immagine.extent.minX, y: -immagine.extent.minY))
        let spazio = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let qualita = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return contesto.jpegRepresentation(of: pulita, colorSpace: spazio, options: [qualita: 0.9])
    }
}
