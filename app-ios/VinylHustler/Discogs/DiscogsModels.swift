import Foundation

// Risposte delle API Discogs che servono all'app (https://www.discogs.com/developers).
// Si decodificano con keyDecodingStrategy = .convertFromSnakeCase (cover_image -> coverImage).

struct Money: Codable, Hashable {
    var value: Double
    var currency: String?
}

struct Identity: Codable {
    var id: Int
    var username: String
}

struct UserProfile: Codable {
    var username: String
    var currAbbr: String?
}

struct Pagination: Codable {
    var page: Int
    var pages: Int
}

/// Una stampa dello stesso album (GET /masters/{id}/versions).
struct MasterVersion: Codable, Hashable {
    var id: Int
    var title: String?
    var label: String?
    var catno: String?
    var country: String?
    var released: String?
    var format: String?
    var majorFormats: [String]?
    var thumb: String?
}

struct MasterVersionsPage: Codable {
    var versions: [MasterVersion]
}

struct SearchResponse: Codable {
    var results: [SearchResult]
}

struct SearchResult: Codable, Hashable {
    var id: Int
    var title: String               // "Artista - Titolo"
    var year: String?
    var country: String?
    var label: [String]?
    var catno: String?
    var format: [String]?
    var barcode: [String]?
    var coverImage: String?
    var thumb: String?
}

struct ReleaseImage: Codable, Hashable {
    var type: String?               // primary / secondary
    var uri: String?
    var uri150: String?
}

struct ReleaseFormat: Codable, Hashable {
    var name: String?
    var descriptions: [String]?
    var text: String?
}

struct NamedRef: Codable, Hashable {
    var name: String
    var catno: String?
}

struct Community: Codable, Hashable {
    var want: Int?
    var have: Int?
}

struct Release: Codable, Hashable {
    var id: Int
    var title: String
    var artistsSort: String?
    var artists: [NamedRef]?
    var labels: [NamedRef]?
    var formats: [ReleaseFormat]?
    var images: [ReleaseImage]?
    var community: Community?
    var country: String?
    var year: Int?
    var blockedFromSale: Bool?
    var masterId: Int?              // l'album "madre": da qui si trovano tutte le stampe

    var artist: String { artistsSort ?? artists?.map(\.name).joined(separator: ", ") ?? "" }

    /// "Artista - Titolo (etichetta, paese, anno)", come describe_release dello script.
    var description: String {
        let label = labels?.first.map { "\($0.name)\($0.catno.map { " \($0)" } ?? "")" } ?? ""
        let extra = [label, country ?? "", year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
        return "\(artist) - \(title)" + (extra.isEmpty ? "" : " (\(extra))")
    }

    /// Testo dei formati ("Vinyl, LP, Limited Edition, Red") per le caratteristiche da collezione.
    var formatsText: String {
        (formats ?? []).map { f in
            ([f.name ?? ""] + (f.descriptions ?? []) + [f.text ?? ""]).filter { !$0.isEmpty }.joined(separator: ", ")
        }.joined(separator: "; ")
    }

    /// Immagini con la principale per prima.
    var sortedImages: [ReleaseImage] {
        (images ?? []).sorted { ($0.type == "primary" ? 0 : 1) < ($1.type == "primary" ? 0 : 1) }
    }
}

struct MarketplaceStats: Codable {
    var numForSale: Int?
    var lowestPrice: Money?
    var blockedFromSale: Bool?
}

struct ListingRelease: Codable, Hashable {
    var id: Int
    var description: String?
    var thumbnail: String?
}

struct Listing: Codable, Hashable, Identifiable {
    var id: Int
    var status: String              // For Sale / Draft / Sold / Expired
    var price: Money?
    var condition: String?
    var sleeveCondition: String?
    var comments: String?
    var externalId: String?
    var location: String?
    var posted: String?
    var release: ListingRelease
}

struct InventoryPage: Codable {
    var listings: [Listing]
    var pagination: Pagination
}

struct OrderItem: Codable, Hashable {
    var id: Int
    var release: ListingRelease
    var price: Money?
}

struct Buyer: Codable, Hashable {
    var username: String
}

struct Order: Codable, Hashable, Identifiable {
    var id: String                  // es. "1234567-12"
    var status: String              // New Order / Payment Received / Shipped / ...
    var created: String
    var items: [OrderItem]
    var buyer: Buyer
    var total: Money?
    var shippingAddress: String?
}

struct OrdersPage: Codable {
    var orders: [Order]
    var pagination: Pagination
}

struct CreatedListing: Codable {
    var listingId: Int
}
