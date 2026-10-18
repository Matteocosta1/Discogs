import Foundation

/// La descrizione degli annunci (quella che leggono i compratori su Discogs), scritta da sola:
///   1. la condizione per intero ("Vinyl: Near Mint (NM or M-) · Sleeve: Very Good Plus (VG+)");
///   2. le note veloci del disco ("Seam split · Insert included");
///   3. la nota scritta a mano;
///   4. il testo fisso della Console (spedizione, imballo…).
/// Lingua: inglese, oppure italiano + inglese (Console › Annunci › Descrizione).
enum ListingText {
    struct Tag: Identifiable, Hashable {
        let it: String
        let en: String
        var id: String { it }
    }

    /// Le note veloci, nell'ordine in cui compaiono nella descrizione.
    static let tags: [Tag] = [
        Tag(it: "Ancora sigillato", en: "Still sealed"),
        Tag(it: "Prima stampa", en: "First press"),
        Tag(it: "Apribile", en: "Gatefold"),
        Tag(it: "Inserto incluso", en: "Insert included"),
        Tag(it: "Busta interna originale", en: "Original inner sleeve"),
        Tag(it: "Adesivo originale", en: "Hype sticker"),
        Tag(it: "Disco testato", en: "Play-tested"),
        Tag(it: "Lavato", en: "Cleaned"),
        Tag(it: "Usura ad anello", en: "Ring wear"),
        Tag(it: "Copertina scollata", en: "Seam split"),
        Tag(it: "Scritta sulla copertina", en: "Writing on cover"),
        Tag(it: "Taglio promo", en: "Cut-out / promo mark"),
    ]

    enum Language: String, CaseIterable { case en, itEn }

    static var language: Language {
        Language(rawValue: UserDefaults.standard.string(forKey: "descLingua") ?? "") ?? .en
    }
    static var includeCondition: Bool { UserDefaults.standard.object(forKey: "descCondizione") as? Bool ?? true }
    static var fixedText: String { UserDefaults.standard.string(forKey: "descFisso") ?? "" }

    /// media e sleeve: le condizioni come le scrive Discogs ("Near Mint (NM or M-)").
    static func build(media: String, sleeve: String, tags chosen: [String], note: String,
                      language: Language = language, includeCondition: Bool = includeCondition,
                      fixed: String = fixedText) -> String {
        var lines: [String] = []
        if includeCondition {
            switch language {
            case .en: lines.append("Vinyl: \(media) · Sleeve: \(sleeve)")
            case .itEn: lines.append("Vinile / Vinyl: \(media) · Copertina / Sleeve: \(sleeve)")
            }
        }
        let picked = tags.filter { chosen.contains($0.it) }
        if !picked.isEmpty {
            lines.append(picked.map { language == .en ? $0.en : "\($0.it) (\($0.en))" }.joined(separator: " · "))
        }
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { lines.append(n) }
        let f = fixed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !f.isEmpty { lines.append(f) }
        return lines.joined(separator: "\n")
    }
}
