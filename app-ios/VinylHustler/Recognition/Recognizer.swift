import UIKit

/// Il riconoscimento, come in JARVIS: scatti o fai un video, e lui ti dice che dischi sono.
///   1. Barcode letto sul telefono (gratis, istantaneo) -> Discogs.
///   2. Altrimenti l'AI guarda le foto (o i fotogrammi del video) e dice TUTTI i dischi che vede.
///   3. Senza AI (non hai fatto l'accesso): le scritte più grandi della foto -> ricerca su Discogs.
/// Non decide niente da solo: propone. Sì / no lo dice il venditore.
struct Recognizer {
    let client: DiscogsClient
    var ai: AIService? = nil

    /// Un disco trovato nelle foto.
    struct Found {
        var images: [Int]               // quali foto lo mostrano (indici nell'array passato)
        var candidates: [Candidate]     // il primo è la proposta
        var read: String                // cosa ha letto/riconosciuto ("Miles Davis - Kind Of Blue")
        var method: String              // barcode / ai / testo
    }

    struct Outcome {
        var found: [Found] = []
        var aiCost = 0.0
        var note = ""                   // perché non ha trovato nulla
    }

    func scan(_ images: [UIImage], video: Bool) async -> Outcome {
        var out = Outcome()
        let all = Array(images.indices)

        // 1. Barcode sul telefono (solo per le foto: un video può avere più dischi)
        if !video {
            let codes = await Task.detached(priority: .userInitiated) { images.flatMap(PhotoReader.barcodes) }.value
            for code in codes {
                if let res = try? await client.search(["barcode": code]), !res.isEmpty {
                    out.found = [Found(images: all, candidates: Self.candidates(res), read: "barcode \(code)", method: "barcode")]
                    return out
                }
            }
        }

        // 2. L'AI: tutti i dischi che si vedono
        if let ai {
            do {
                let picked = Self.spread(images, max: 8)
                let scan = try await ai.scan(photos: picked.compactMap { images[$0].jpegForUpload() })
                out.aiCost = scan.cost ?? 0
                for record in scan.records {
                    let shown = record.images.compactMap { n in picked.indices.contains(n - 1) ? picked[n - 1] : nil }
                    let results = await search(record)
                    out.found.append(Found(images: shown.isEmpty ? all : shown, candidates: Self.candidates(results),
                                           read: record.line, method: "ai"))
                }
                if out.found.isEmpty { out.note = "Nessun disco riconosciuto: avvicinati alla copertina o al centrino" }
                return out
            } catch {
                out.note = error.localizedDescription
            }
        }

        // 3. Senza AI: le scritte grandi della foto più centrale
        if let middle = images[safe: images.count / 2] {
            let text = await Task.detached(priority: .userInitiated) { PhotoReader.bigText(in: middle) }.value
            if text.count >= 4, let res = try? await client.search(["q": text]), !res.isEmpty {
                out.found = [Found(images: all, candidates: Self.candidates(res), read: text, method: "testo")]
                return out
            }
        }
        if out.note.isEmpty { out.note = "Non riconosciuto: prova un'altra foto (copertina o centrino)" }
        return out
    }

    /// Ricerca su Discogs di quello che l'AI ha letto: barcode -> catalogo -> artista e titolo.
    private func search(_ r: AIRecord) async -> [SearchResult] {
        var tries: [[String: String]] = []
        let digits = r.barcode.filter(\.isNumber)
        if digits.count >= 8 { tries.append(["barcode": digits]) }
        if !r.catno.isEmpty {
            if !r.label.isEmpty { tries.append(["catno": r.catno, "label": r.label]) }
            tries.append(["catno": r.catno])
        }
        if !r.title.isEmpty {
            tries.append(r.artist.isEmpty ? ["release_title": r.title] : ["artist": r.artist, "release_title": r.title])
            tries.append(["q": "\(r.artist) \(r.title)"])
        }
        for params in tries {
            if let res = try? await client.search(params), !res.isEmpty { return res }
        }
        return []
    }

    static func candidates(_ results: [SearchResult]) -> [Candidate] {
        results.prefix(6).map { r in
            let extra = [r.label?.first, r.country, r.year].compactMap { $0 }.filter { !$0.isEmpty }
            let title = extra.isEmpty ? r.title : "\(r.title) (\(extra.joined(separator: ", ")))"
            return Candidate(id: r.id, title: title, coverURL: r.coverImage ?? r.thumb)
        }
    }

    /// Al massimo `max` foto, distribuite su tutto il video.
    static func spread(_ images: [UIImage], max: Int) -> [Int] {
        guard images.count > max else { return Array(images.indices) }
        return (0..<max).map { Int((Double($0) + 0.5) * Double(images.count) / Double(max)) }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
