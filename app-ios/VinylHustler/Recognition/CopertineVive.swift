import CoreImage
import CoreVideo
import Foundation
import Vision

/// V60 · REC dal vivo: le copertine nell'inquadratura mentre si filma (anche più di una insieme).
/// Più severo del riquadro della V51 (che «inventava rombi»): solo forme quasi quadrate, grandi abbastanza
/// e con confidenza alta. Il filtro vero lo fa poi RECVivo, che tiene solo quelle ferme per qualche fotogramma.
enum CopertineVive {
    static func richiesta() -> VNDetectRectanglesRequest {
        let r = VNDetectRectanglesRequest()
        r.minimumAspectRatio = 0.8            // una copertina è quadrata: niente rettangoli lunghi
        r.maximumAspectRatio = 1.0
        r.minimumSize = 0.18
        r.quadratureTolerance = 20
        r.minimumConfidence = 0.8
        r.maximumObservations = 4
        return r
    }

    /// Gli angoli di ogni copertina in coordinate della fotocamera (0…1, origine in alto a sinistra del sensore),
    /// nell'ordine alto-sinistra, alto-destra, basso-destra, basso-sinistra. Pronti per l'anteprima.
    static func trova(in buffer: CVPixelBuffer) -> [[CGPoint]] {
        let r = richiesta()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        guard (try? handler.perform([r])) != nil, let risultati = r.results else { return [] }
        return risultati.map { o in
            [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft].map { CGPoint(x: $0.x, y: 1 - $0.y) }
        }
    }
}
