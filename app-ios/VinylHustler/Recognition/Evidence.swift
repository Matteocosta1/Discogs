import Foundation

/// Indizi letti dalle foto di un disco: barcode, numeri di catalogo, righe di testo.
/// Porta di Evidence, catno_candidates, is_strong_catno, is_track_line e big_lines di vendi.py.
struct Evidence {
    struct Line { var text: String; var height: Double }

    var barcodes: [String] = []
    var catnos: [String: String] = [:]      // normalizzato -> come è scritto
    var lines: [Line] = []
    var main: [String] = []                 // scritte principali (di solito artista e titolo)

    var text: String { lines.map(\.text).joined(separator: "\n") }

    mutating func add(lines new: [Line]) {
        lines += new
        main += Self.bigLines(new)
        // I cataloghi di una scaletta ("From the album 'Mirage' BJQD/15") sono di altri dischi.
        let texts = lines.map(\.text)
        let inTracks = Self.catnoCandidates(texts.filter(Self.isTrackLine))
        let strongTracks = inTracks.keys.filter(Self.isStrongCatno)
        func fromTracks(_ norm: String) -> Bool { inTracks[norm] != nil || strongTracks.contains { norm.contains($0) } }
        for (norm, raw) in Self.catnoCandidates(texts.filter { !Self.isTrackLine($0) }) where !fromTracks(norm) {
            if catnos[norm] == nil { catnos[norm] = raw }
        }
        catnos = catnos.filter { !fromTracks($0.key) }
    }

    /// Cataloghi "forti" (lettere e numeri, almeno 4 caratteri), i più lunghi prima.
    var strongCatnos: [String] {
        catnos.filter { Self.isStrongCatno($0.key) }.sorted { $0.key.count > $1.key.count }.map(\.value)
    }

    // MARK: - Regole (identiche allo script)

    static func normalizeCatno(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }).uppercased()
    }

    static func isStrongCatno(_ norm: String) -> Bool {
        norm.count >= 4 && norm.contains(where: \.isNumber) && norm.contains(where: \.isLetter)
    }

    private static let yearRegex = try! NSRegularExpression(pattern: "^(19|20)\\d\\d$")
    private static let tokenRegex = try! NSRegularExpression(pattern: "[A-Za-z0-9][A-Za-z0-9.\\-/]*")
    private static let trackRegex = try! NSRegularExpression(
        pattern: "^\\s*(?:[A-Ha-h]\\s?\\d{1,2}|\\d{1,2})\\s*[.):\\-–]?\\s+(?!rpm\\b|giri\\b)\\S", options: [.caseInsensitive])
    private static let fromAlbumRegex = try! NSRegularExpression(
        pattern: "\\bfrom (?:the )?(?:album|lp|ep|12\"?)\\b", options: [.caseInsensitive])

    static func isTrackLine(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return trackRegex.firstMatch(in: text, range: range) != nil || fromAlbumRegex.firstMatch(in: text, range: range) != nil
    }

    /// Possibili numeri di catalogo nel testo: {normalizzato: testo originale}.
    static func catnoCandidates(_ lines: [String]) -> [String: String] {
        var found: [String: String] = [:]
        for line in lines {
            let tokens = tokenRegex.matches(in: line, range: NSRange(line.startIndex..., in: line))
                .compactMap { Range($0.range, in: line).map { String(line[$0]) } }
            for i in tokens.indices {
                for n in 1...3 where i + n <= tokens.count {   // "SHVL 804", "2C 062-04512"
                    let raw = tokens[i..<(i + n)].joined(separator: " ")
                    let norm = normalizeCatno(raw)
                    guard (3...20).contains(norm.count), norm.contains(where: \.isNumber) else { continue }
                    if norm.allSatisfy(\.isNumber) {
                        let isYear = yearRegex.firstMatch(in: norm, range: NSRange(norm.startIndex..., in: norm)) != nil
                        if norm.count < 4 || norm.count >= 12 || isYear { continue }   // corto, anno o barcode
                    }
                    if found[norm] == nil { found[norm] = raw }
                }
            }
        }
        return found
    }

    /// Le scritte più grandi (di solito artista e titolo), senza la scaletta.
    static func bigLines(_ lines: [Line]) -> [String] {
        let usable = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && !isTrackLine($0.text) }
        guard let tallest = usable.map(\.height).max() else { return [] }
        let top = Set(usable.sorted { $0.height > $1.height }.prefix(8).map(\.text))
        return usable.filter { (tallest > 0 && $0.height >= tallest * 0.5) || top.contains($0.text) }.map(\.text)
    }

    /// True se il nome dell'etichetta compare nel testo letto (per confermare un catalogo).
    static func labelInText(_ label: String, _ text: String) -> Bool {
        func compact(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let name = label.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
        let c = compact(name)
        return c.count >= 3 && compact(text).contains(c)
    }
}
