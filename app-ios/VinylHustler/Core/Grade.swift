import Foundation

/// Gradi Goldmine come li scrive Discogs (stessa tabella GRADES di vendi.py).
enum Grade: String, CaseIterable, Codable, Identifiable {
    case m = "M", nm = "NM", vgPlus = "VG+", vg = "VG", gPlus = "G+", g = "G"

    var id: String { rawValue }

    /// Condizione esatta richiesta dalle API Discogs.
    var discogs: String {
        switch self {
        case .m: "Mint (M)"
        case .nm: "Near Mint (NM or M-)"
        case .vgPlus: "Very Good Plus (VG+)"
        case .vg: "Very Good (VG)"
        case .gPlus: "Good Plus (G+)"
        case .g: "Good (G)"
        }
    }
}
