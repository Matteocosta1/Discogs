import Foundation
import SwiftData

/// Stato di un disco nell'app (equivale a foto.esito + annunci_api.stato dello script).
enum DiscStatus: String, Codable, CaseIterable {
    case inLavorazione      // foto fatte, riconoscimento in corso
    case pronto             // riconosciuto e prezzato: aspetta "Pubblica"
    case inVendita          // annuncio For Sale su Discogs
    case bozza              // annuncio Draft su Discogs
    case daControllare      // il riconoscimento non è sicuro: serve l'occhio del venditore
    case bloccato           // release bloccata dal marketplace Discogs
    case tolto              // tolto dal venditore
}

/// I sei tipi di foto di un disco. Nessuna è obbligatoria: più ce ne sono, più il riconoscimento è preciso.
/// La matrice (su Discogs "Matrix / Runout") è il codice inciso nella zona liscia vicino al centrino:
/// distingue le diverse stampe dello stesso disco.
enum PhotoKind: String, CaseIterable, Codable, Identifiable {
    case copertinaFronte, copertinaRetro, centrinoA, centrinoB, solco, matrice
    /// Fotogramma di un giro con l'Occhio (il disco girato davanti al telefono): non ha un riquadro suo.
    case giro

    /// I sei riquadri della sessione (il giro non ne ha uno).
    static var slots: [PhotoKind] { allCases.filter { $0 != .giro } }

    var id: String { rawValue }
    var number: String { String(format: "%02d", (PhotoKind.allCases.firstIndex(of: self) ?? 0) + 1) }

    var title: String {
        switch self {
        case .copertinaFronte: "Copertina fronte"
        case .copertinaRetro: "Copertina retro"
        case .centrinoA: "Centrino lato A"
        case .centrinoB: "Centrino lato B"
        case .solco: "Solco"
        case .matrice: "Matrice"
        case .giro: "Giro"
        }
    }

    var hint: String {
        switch self {
        case .copertinaFronte: "o copertina 1"
        case .copertinaRetro: "o copertina 2"
        case .centrinoA: "o etichetta 1"
        case .centrinoB: "o etichetta 2"
        case .solco: "superficie del vinile"
        case .matrice: "codice inciso vicino al centrino"
        case .giro: "fotogramma dell'Occhio"
        }
    }

    var symbol: String {
        switch self {
        case .copertinaFronte: "square"
        case .copertinaRetro: "square.on.square"
        case .centrinoA, .centrinoB: "circle.circle"
        case .solco: "circle.dotted"
        case .matrice: "number"
        case .giro: "eye"
        }
    }
}

/// Un candidato proposto per un disco da controllare (tasto "È questo").
struct Candidate: Codable, Hashable, Identifiable {
    var id: Int                 // release_id Discogs
    var title: String           // "Artista - Titolo (etichetta, paese, anno)"
    var coverURL: String?
    var coverDistance: Double?  // distanza Vision (più bassa = più simile)
}

/// Un disco fotografato. Le foto restano nella cartella Documents/Foto dell'app.
@Model
final class Disc {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var lot: String
    var photoFiles: [String]            // nomi dei file, nell'ordine di PhotoKind
    var photoKinds: [String] = []       // PhotoKind di ogni file (stesso ordine di photoFiles)
    var mediaRaw: String
    var sleeveRaw: String
    var statusRaw: String
    var reason: String                  // perché è da controllare
    var details: String                 // traccia del riconoscimento (come "dettagli" nello script)
    var method: String                  // barcode / catalogo / copertina / copertina-ai / manuale
    var releaseID: Int?
    var releaseTitle: String
    var coverFile: String?              // copertina Discogs in cache (immagine principale della scheda)
    var candidatesData: Data            // [Candidate] in JSON
    var price: Double?
    var priceCalculation: String
    var listingID: Int?
    var box: String                     // posizione fisica (scatola/QR)
    var aiCost: Double

    init(lot: String, photoFiles: [String], media: Grade, sleeve: Grade) {
        id = UUID()
        createdAt = .now
        self.lot = lot
        self.photoFiles = photoFiles
        mediaRaw = media.rawValue
        sleeveRaw = sleeve.rawValue
        statusRaw = DiscStatus.inLavorazione.rawValue
        reason = ""
        details = ""
        method = ""
        releaseTitle = ""
        candidatesData = Data("[]".utf8)
        priceCalculation = ""
        box = ""
        aiCost = 0
        releaseID = nil
        coverFile = nil
        price = nil
        listingID = nil
    }

    var status: DiscStatus {
        get { DiscStatus(rawValue: statusRaw) ?? .daControllare }
        set { statusRaw = newValue.rawValue }
    }
    var media: Grade { Grade(rawValue: mediaRaw) ?? .vgPlus }
    var sleeve: Grade { Grade(rawValue: sleeveRaw) ?? media }
    var candidates: [Candidate] {
        get { (try? JSONDecoder().decode([Candidate].self, from: candidatesData)) ?? [] }
        set { candidatesData = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8) }
    }
    /// external_id dell'annuncio su Discogs: collega l'annuncio a questo disco.
    var externalID: String { "app-\(id.uuidString.prefix(8).lowercased())" }

    var gradeText: String { media == sleeve ? "Grado \(media.rawValue)" : "Disco \(media.rawValue) · Copertina \(sleeve.rawValue)" }
}

/// Cartelle dell'app.
enum AppFolders {
    static var photos: URL { folder("Foto") }
    static var covers: URL { folder("Copertine", in: .cachesDirectory) }

    private static func folder(_ name: String, in dir: FileManager.SearchPathDirectory = .documentDirectory) -> URL {
        let url = FileManager.default.urls(for: dir, in: .userDomainMask)[0].appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
