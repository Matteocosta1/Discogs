import UIKit
import Vision

/// Confronto delle foto con le copertine Discogs (copertine.py, backend "vision").
/// Le soglie sono quelle tarate sulle foto vere il 14 ottobre 2026:
/// stessa copertina 0,45–1,17, copertine diverse 0,74–1,18.
enum CoverThresholds {
    static let strong = 0.65    // sotto: stessa copertina, Vision decide da solo
    static let gap = 0.15       // il primo deve staccare il secondo di almeno questo
    static let doubt = 1.00     // tra strong e strong+doubt: zona di dubbio (decide l'AI, se attiva)
    static var clearlyDifferent: Double { strong + doubt }
}

/// Impronta visiva normalizzata (lunghezza 1) e distanza euclidea, come _vision_feature/_vision_distance.
/// Si usa la stessa formula dello script per poter riusare le stesse soglie.
struct FeaturePrint {
    let vector: [Float]

    init?(image: CGImage) {
        let request = VNGenerateImageFeaturePrintRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
              let obs = request.results?.first as? VNFeaturePrintObservation else { return nil }
        var values: [Float] = []
        obs.data.withUnsafeBytes { buffer in
            switch obs.elementType {
            case .float: values = Array(buffer.bindMemory(to: Float.self).prefix(obs.elementCount))
            case .double: values = buffer.bindMemory(to: Double.self).prefix(obs.elementCount).map { Float($0) }
            default: break
            }
        }
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        vector = values.map { $0 / norm }
    }

    func distance(to other: FeaturePrint) -> Double {
        Double(sqrt(zip(vector, other.vector).reduce(Float(0)) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }))
    }
}

/// Copertine Discogs in cache sul telefono: Caches/Copertine/<release>-<n>.jpg.
actor CoverStore {
    let client: DiscogsClient
    private var prints: [String: FeaturePrint] = [:]

    init(client: DiscogsClient) { self.client = client }

    func file(_ releaseID: Int, _ n: Int) -> URL { AppFolders.covers.appendingPathComponent("\(releaseID)-\(n).jpg") }

    /// Immagini locali di una release (scaricandole se servono, al massimo `limit`).
    func images(of releaseID: Int, limit: Int, release: Release? = nil) async -> [URL] {
        let fm = FileManager.default
        let cached = (0..<limit).map { file(releaseID, $0) }.filter { fm.fileExists(atPath: $0.path) }
        // <release>.count = quante immagini ha la release su Discogs (per non richiederla di nuovo)
        let countFile = AppFolders.covers.appendingPathComponent("\(releaseID).count")
        let known = (try? String(contentsOf: countFile, encoding: .utf8)).flatMap { Int($0) }
        if cached.count >= limit || (known != nil && cached.count >= min(limit, known!)) { return cached }
        let rel: Release
        if let release { rel = release } else if let r = try? await client.release(releaseID) { rel = r } else { return cached }
        try? String(rel.sortedImages.count).write(to: countFile, atomically: true, encoding: .utf8)
        var out: [URL] = []
        for (n, img) in rel.sortedImages.prefix(limit).enumerated() {
            let target = file(releaseID, n)
            if !fm.fileExists(atPath: target.path) {
                guard let url = img.uri ?? img.uri150, let data = try? await client.download(url) else { continue }
                try? data.write(to: target)
            }
            out.append(target)
        }
        return out
    }

    /// La copertina principale (per la scheda del disco), scaricata se serve.
    func mainCover(of releaseID: Int) async -> URL? {
        await images(of: releaseID, limit: 1).first
    }

    func featurePrint(of url: URL) -> FeaturePrint? {
        if let p = prints[url.path] { return p }
        guard let img = UIImage(contentsOfFile: url.path)?.normalizedCGImage(maxSide: 1024),
              let p = FeaturePrint(image: img) else { return nil }
        prints[url.path] = p
        return p
    }
}

/// Esito del confronto tra le foto di un disco e i candidati.
struct CoverVerdict {
    var chosen: Int?                     // release scelta da Vision (nil = nessuna netta)
    var distances: [Int: Double]         // distanza minima per release
    var text: String
}

struct CoverMatcher {
    let store: CoverStore

    /// Distanza minima tra le foto del disco e le immagini di ogni candidato.
    func distances(photos: [FeaturePrint], candidates: [Int], imagesPerRelease: Int) async -> [Int: Double] {
        var out: [Int: Double] = [:]
        for id in candidates {
            var best: Double?
            for url in await store.images(of: id, limit: imagesPerRelease) {
                guard let cover = await store.featurePrint(of: url) else { continue }
                for p in photos {
                    let d = p.distance(to: cover)
                    if best == nil || d < best! { best = d }
                }
            }
            if let best { out[id] = best }
        }
        return out
    }

    /// Scelta come Matcher.verdict: c'è solo se il migliore è sotto `strong` e stacca il secondo di `gap`.
    func verdict(_ distances: [Int: Double]) -> CoverVerdict {
        let ranked = distances.sorted { $0.value < $1.value }
        let list = ranked.map { "\($0.key) \(String(format: "%.2f", $0.value))" }.joined(separator: ", ")
        guard let best = ranked.first else { return CoverVerdict(chosen: nil, distances: distances, text: "copertine: nessun confronto possibile") }
        if best.value > CoverThresholds.strong {
            return CoverVerdict(chosen: nil, distances: distances, text: "copertine: \(list); nessuna copertina riconosciuta")
        }
        if ranked.count > 1, ranked[1].value - best.value < CoverThresholds.gap {
            return CoverVerdict(chosen: nil, distances: distances, text: "copertine: \(list); copertine troppo simili tra loro")
        }
        return CoverVerdict(chosen: best.key, distances: distances, text: "copertine: \(list); riconosciuta \(best.key)")
    }
}
