import Foundation
import SwiftData

/// Stato di un disco nell'app (equivale a foto.esito + annunci_api.stato dello script).
enum DiscStatus: String, Codable, CaseIterable {
    case inLavorazione      // foto fatte, riconoscimento in corso
    case daConfermare       // riconosciuto: il venditore dice "sì, è questo" o "no"
    case pronto             // riconosciuto e prezzato: aspetta "Pubblica"
    case inVendita          // annuncio For Sale su Discogs
    case bozza              // annuncio Draft su Discogs
    case daControllare      // non riconosciuto: serve un'altra foto o il numero della release
    case bloccato           // release bloccata dal marketplace Discogs
    case tolto              // tolto dal venditore
}

/// Da dove viene una foto del disco: uno scatto o un fotogramma di un video.
enum PhotoKind: String, Codable {
    case foto, fotogramma
}

/// Un candidato proposto per un disco da controllare (tasto "È questo").
struct Candidate: Codable, Hashable, Identifiable {
    var id: Int                 // release_id Discogs
    var title: String           // "Artista - Titolo (etichetta, paese, anno)"
    var coverURL: String?
}

/// Un disco fotografato. Le foto restano nella cartella Documents/Foto dell'app.
@Model
final class Disc {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var lot: String
    var photoFiles: [String]            // nomi dei file delle foto
    var photoKinds: [String] = []       // PhotoKind di ogni file (stesso ordine di photoFiles)
    var earArtist: String = ""          // non più usati (Orecchio tolto): restano per i dischi già salvati
    var earTitle: String = ""
    var earAlbum: String = ""
    var parked: Bool = false            // "Dopo": deciso più tardi, sparisce dalla sessione
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
    var box: String                     // dove sta fisicamente: "Scatola 12", "Casa 2"…
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
    /// La release proposta, tra i candidati (per la copertina Discogs).
    var proposal: Candidate? { candidates.first { $0.id == releaseID } }
    var coverURL: URL? { proposal?.coverURL.flatMap(URL.init(string:)) }

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
