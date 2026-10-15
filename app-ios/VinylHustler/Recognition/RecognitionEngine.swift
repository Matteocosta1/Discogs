import UIKit

/// Esito del riconoscimento di un disco.
struct RecognitionResult {
    enum Outcome { case found, toCheck, blocked }
    var outcome: Outcome
    var release: Release?
    var method: String = ""             // barcode / catalogo / copertina / copertina-ai
    var reason: String = ""             // perché va controllato
    var details: [String] = []
    var candidates: [Candidate] = []
    var aiCost: Double = 0

    /// Riconosciuto con un codice stampato (barcode o catalogo): non serve la conferma della copertina.
    var byCode: Bool { method == "barcode" || method == "catalogo" }
}

/// La cascata di vendi.py, nell'ordine deciso:
///   1. barcode e testo letti sul telefono (gratis)          -> candidati da Discogs
///   2. confronto delle copertine con Vision (gratis)         -> scelta, se netta
///   3. solo se serve e se la modalità lo permette: AI sul server (confronto copertine / lettura foto)
///   4. PORTA D'USCITA: senza codice, nessun disco va in vendita se la copertina non combacia.
struct RecognitionEngine {
    let client: DiscogsClient
    let store: CoverStore
    let mode: RecognitionMode
    var ai: AIService? = nil

    func recognize(photos: [UIImage]) async -> RecognitionResult {
        // 1. Lettura locale (Vision, sul telefono)
        let (ev, prints) = await Task.detached(priority: .userInitiated) {
            (PhotoReader.evidence(from: photos),
             photos.compactMap { $0.normalizedCGImage(maxSide: 1024).flatMap(FeaturePrint.init(image:)) })
        }.value
        var details = [ev.barcodes.isEmpty ? "nessun barcode letto" : "barcode: \(ev.barcodes.joined(separator: ", "))"]
        if !ev.strongCatnos.isEmpty { details.append("cataloghi: \(ev.strongCatnos.prefix(5).joined(separator: ", "))") }
        var aiCost = 0.0

        // 2. Candidati da Discogs
        var (method, found) = await searchByEvidence(ev)
        if found.isEmpty, mode == .completa, let ai {
            // La parte locale non ha trovato nulla: l'AI legge la foto, poi si cerca di nuovo
            if let read = try? await ai.read(photos: photos.compactMap { $0.jpegForUpload(maxSide: 1568) }) {
                aiCost += read.cost ?? 0
                details.append("AI legge: \(read.artist) - \(read.title) [\(read.catno)]")
                (method, found) = await searchByAIRead(read, ev: ev)
            }
        }
        guard !found.isEmpty else {
            return RecognitionResult(outcome: .toCheck, reason: "Non trovato su Discogs", details: details, aiCost: aiCost)
        }
        details.append("\(found.count) candidati (\(method))")

        // 3. Copertine: Vision tra i candidati
        let shortlist = Array(found.prefix(mode.maxCandidates))
        let matcher = CoverMatcher(store: store)
        let distances = await matcher.distances(photos: prints, candidates: shortlist.map(\.id),
                                                imagesPerRelease: mode.imagesPerRelease)
        let verdict = matcher.verdict(distances)
        details.append(verdict.text)
        let candidates = shortlist.map {
            Candidate(id: $0.id, title: $0.title, coverURL: $0.coverImage ?? $0.thumb, coverDistance: distances[$0.id])
        }.sorted { ($0.coverDistance ?? 9) < ($1.coverDistance ?? 9) }

        var chosen: Int?
        var how = method
        if shortlist.count == 1, method == "barcode" || method == "catalogo" {
            // Trovato con un codice: si ferma solo se la copertina è CHIARAMENTE un'altra
            let id = shortlist[0].id
            if let d = distances[id], d > CoverThresholds.clearlyDifferent {
                return RecognitionResult(outcome: .toCheck, method: method,
                                         reason: "Copertina diversa da quella su Discogs, anche se trovato con il \(method)",
                                         details: details, candidates: candidates, aiCost: aiCost)
            }
            chosen = id
        } else if let id = verdict.chosen {
            chosen = id
            how = "copertina"
        } else if mode.usesAI, let ai {
            // Zona di dubbio: l'AI guarda le foto accanto alle copertine dei 3 più vicini
            let near = candidates.filter { ($0.coverDistance ?? 9) <= CoverThresholds.clearlyDifferent }.prefix(3)
            if !near.isEmpty {
                var payload: [AIService.CandidateImages] = []
                for c in near {
                    let urls = await store.images(of: c.id, limit: mode.imagesPerRelease)
                    let imgs = urls.compactMap { UIImage(contentsOfFile: $0.path)?.jpegForUpload()?.base64EncodedString() }
                    payload.append(.init(releaseId: c.id, title: c.title, images: imgs))
                }
                if let pick = try? await ai.matchCovers(photos: photos.compactMap { $0.jpegForUpload() }, candidates: payload) {
                    aiCost += pick.cost ?? 0
                    details.append("AI copertine (\(pick.confidence)): \(pick.reason)")
                    if pick.confidence == "high", near.contains(where: { $0.id == pick.releaseId }) {
                        chosen = pick.releaseId
                        how = "copertina-ai"
                    }
                }
            }
        }

        guard let chosenID = chosen else {
            let reason = shortlist.count > 1 ? "Più release possibili: scegli quella giusta"
                                             : "Copertina diversa da quella su Discogs"
            return RecognitionResult(outcome: .toCheck, method: method, reason: reason, details: details,
                                     candidates: candidates, aiCost: aiCost)
        }

        // 4. La release scelta: si può vendere?
        guard let release = try? await client.release(chosenID) else {
            return RecognitionResult(outcome: .toCheck, method: how, reason: "Discogs non risponde: riprova",
                                     details: details, candidates: candidates, aiCost: aiCost)
        }
        if release.blockedFromSale == true {
            return RecognitionResult(outcome: .blocked, release: release, method: how,
                                     reason: "Bloccato da Discogs: non si può vendere", details: details, aiCost: aiCost)
        }
        return RecognitionResult(outcome: .found, release: release, method: how, details: details,
                                 candidates: candidates, aiCost: aiCost)
    }

    /// Barcode -> catalogo (confermato dall'etichetta letta) -> scritte principali.
    private func searchByEvidence(_ ev: Evidence) async -> (String, [SearchResult]) {
        for b in ev.barcodes {
            if let res = try? await client.search(["barcode": b]), !res.isEmpty { return ("barcode", res) }
        }
        for raw in ev.strongCatnos.prefix(3) {    // al massimo 3 tentativi, per non sprecare richieste
            if let res = try? await client.search(["catno": raw]) {
                let confirmed = res.filter { ($0.label ?? []).contains { Evidence.labelInText($0, ev.text) } }
                if !confirmed.isEmpty { return ("catalogo", confirmed) }
            }
        }
        let main = ev.main.prefix(3).joined(separator: " ")
        if main.count >= 4, let res = try? await client.search(["q": main]), !res.isEmpty { return ("testo", res) }
        return ("", [])
    }

    private func searchByAIRead(_ read: AIRead, ev: Evidence) async -> (String, [SearchResult]) {
        if !read.barcode.isEmpty, let res = try? await client.search(["barcode": read.barcode]), !res.isEmpty { return ("barcode", res) }
        if Evidence.isStrongCatno(Evidence.normalizeCatno(read.catno)),
           let res = try? await client.search(["catno": read.catno, "label": read.label]), !res.isEmpty { return ("ai-catalogo", res) }
        for (artist, title) in [(read.artist, read.title), (read.recognizedArtist, read.recognizedTitle)] where !title.isEmpty {
            var params = ["release_title": title]
            if !artist.isEmpty { params["artist"] = artist }
            if let res = try? await client.search(params), !res.isEmpty { return ("ai-testo", res) }
        }
        return ("", [])
    }
}
