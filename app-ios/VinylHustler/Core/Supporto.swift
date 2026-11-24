import CoreGraphics
import Foundation

/// V82 · Il supporto che si sta fotografando: le tre fotocamere VINILE · CD · CASSETTA (sopra lo scatto).
/// Va all'AI (cosa sta guardando), alla ricerca su Discogs (format=Vinyl / CD / Cassette), alle Versioni
/// (solo stampe dello stesso supporto), al REC (forma della custodia) e alle scritte della condizione.
enum Supporto: String, CaseIterable, Identifiable, Sendable {
    case vinile, cd, cassetta

    var id: String { rawValue }

    /// Dal formato scritto da Discogs ("Cassette, Album", "CD, Album, Reissue", "Vinyl, LP"). Senza formato: vinile.
    static func da(formato: String?) -> Supporto {
        let f = formato ?? ""
        if f.contains("Cassette") { return .cassetta }
        if f.range(of: #"\bCD"#, options: .regularExpression) != nil { return .cd }
        return .vinile
    }

    /// La chiave in UserDefaults dell'ultima fotocamera scelta (resta tra un'apertura e l'altra).
    static let chiave = "supporto"
    /// La fotocamera scelta adesso.
    static var attuale: Supporto { Supporto(rawValue: UserDefaults.standard.string(forKey: chiave) ?? "") ?? .vinile }

    /// Il nome della modalità sopra lo scatto.
    var nome: String {
        switch self {
        case .vinile: "VINILE"
        case .cd: "CD"
        case .cassetta: "CASSETTA"
        }
    }
    /// La parola del riquadro in alto («● DISCO») e del caricamento.
    var tipo: String {
        switch self {
        case .vinile: "DISCO"
        case .cd: "CD"
        case .cassetta: "CASSETTA"
        }
    }
    /// Il formato come lo chiama Discogs (ricerca, versioni).
    var discogs: String {
        switch self {
        case .vinile: "Vinyl"
        case .cd: "CD"
        case .cassetta: "Cassette"
        }
    }
    /// Condizione: il supporto e la sua custodia (Foto, scheda del video, annuncio).
    var nomeSupporto: String {
        switch self {
        case .vinile: "Vinile"
        case .cd: "CD"
        case .cassetta: "Cassetta"
        }
    }
    var nomeCustodia: String { self == .vinile ? "Copertina" : "Custodia" }
    /// Le stesse due parole in inglese, per la descrizione dell'annuncio.
    var supportoInglese: String { discogs }
    var custodiaInglese: String { self == .vinile ? "Sleeve" : "Case" }

    /// REC: la frase mentre si filma.
    var passa: String {
        switch self {
        case .vinile: "PASSA I DISCHI DAVANTI · LASCIA PER FERMARE"
        case .cd: "PASSA I CD DAVANTI · LASCIA PER FERMARE"
        case .cassetta: "PASSA LE CASSETTE DAVANTI · LASCIA PER FERMARE"
        }
    }
    /// REC: il contatore accanto al tempo («1 DISCO», «3 CASSETTE»).
    func quanti(_ n: Int) -> String {
        switch self {
        case .vinile: n == 1 ? "1 DISCO" : "\(n) DISCHI"
        case .cd: "\(n) CD"
        case .cassetta: n == 1 ? "1 CASSETTA" : "\(n) CASSETTE"
        }
    }
    /// REC: la frase alla fine.
    func trovati(_ n: Int) -> String {
        switch self {
        case .vinile: n == 0 ? "NESSUN DISCO AGGANCIATO · RIPROVA" : (n == 1 ? "1 DISCO TROVATO" : "\(n) DISCHI TROVATI")
        case .cd: n == 0 ? "NESSUN CD AGGANCIATO · RIPROVA" : (n == 1 ? "1 CD TROVATO" : "\(n) CD TROVATI")
        case .cassetta: n == 0 ? "NESSUNA CASSETTA AGGANCIATA · RIPROVA" : (n == 1 ? "1 CASSETTA TROVATA" : "\(n) CASSETTE TROVATE")
        }
    }

    /// REC: la forma da cercare nell'inquadratura (lato corto / lato lungo). Copertine dei vinili e custodie dei CD
    /// sono quasi quadrate; la custodia di una cassetta è un rettangolo (circa 11 × 7 cm).
    var rettangoloMinimo: Float { self == .cassetta ? 0.5 : 0.8 }
    var rettangoloMassimo: Float { self == .cassetta ? 0.8 : 1.0 }
    /// Mentre la segue: sotto questo rapporto tra i lati non è più la stessa custodia.
    var latiMinimo: CGFloat { self == .cassetta ? 0.45 : 0.65 }
}
