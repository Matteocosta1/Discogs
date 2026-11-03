import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Una copertina seguita durante il REC: sempre lo stesso `id` finché il telefono non la perde,
/// con i 4 angoli in coordinate della fotocamera (0…1, origine in alto a sinistra del sensore),
/// nell'ordine alto-sinistra, alto-destra, basso-destra, basso-sinistra.
struct CopertinaVista: Sendable {
    let id: UUID
    let angoli: [CGPoint]
}

/// V60 · REC dal vivo: le copertine nell'inquadratura mentre si filma (anche più di una insieme).
/// V72: la ricerca (più pesante) parte 4 volte al secondo solo per trovare copertine nuove; quelle già trovate
/// le segue Vision a ogni fotogramma (VNTrackRectangleRequest), così gli angoli restano incollati alla copertina
/// invece di saltare. Solo forme quasi quadrate, grandi abbastanza e con confidenza alta.
enum CopertineVive {
    static func richiesta() -> VNDetectRectanglesRequest {
        let r = VNDetectRectanglesRequest()
        r.minimumAspectRatio = 0.8            // una copertina è quadrata: niente rettangoli lunghi
        r.maximumAspectRatio = 1.0
        r.minimumSize = 0.2                   // V72: un filo più grande (niente quadratini sullo sfondo)
        r.quadratureTolerance = 20
        r.minimumConfidence = 0.85            // V72: più severo (meno cornici e scatole scambiate per dischi)
        r.maximumObservations = 4
        return r
    }

    /// Le copertine nuove in questo fotogramma (coordinate di Vision).
    static func cerca(in buffer: CVPixelBuffer) -> [VNRectangleObservation] {
        let r = richiesta()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        guard (try? handler.perform([r])) != nil else { return [] }
        return r.results ?? []
    }

    /// Gli angoli di Vision (origine in basso a sinistra) in coordinate della fotocamera (origine in alto a sinistra).
    static func angoli(_ o: VNRectangleObservation) -> [CGPoint] {
        [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft].map { CGPoint(x: $0.x, y: 1 - $0.y) }
    }

    /// Ancora una copertina? Mentre la segue, Vision può «scivolare» su una forma storta: i lati, in pixel veri,
    /// devono restare quasi uguali (una copertina inclinata va bene, un trapezio schiacciato no).
    static func quasiQuadrata(_ o: VNRectangleObservation, larghezza: CGFloat, altezza: CGFloat) -> Bool {
        func lato(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot((a.x - b.x) * larghezza, (a.y - b.y) * altezza) }
        let orizzontale = (lato(o.topLeft, o.topRight) + lato(o.bottomLeft, o.bottomRight)) / 2
        let verticale = (lato(o.topLeft, o.bottomLeft) + lato(o.topRight, o.bottomRight)) / 2
        guard orizzontale > 20, verticale > 20 else { return false }
        return min(orizzontale, verticale) / max(orizzontale, verticale) >= 0.65
    }
}
