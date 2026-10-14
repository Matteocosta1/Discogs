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

/// Modalità di riconoscimento (come le opzioni di vendi.py).
enum RecognitionMode: String, CaseIterable, Codable, Identifiable {
    /// --super-veloce: niente AI, decide Vision sulle copertine. Gratis, tutto sul telefono.
    case superVeloce
    /// --veloce: come super veloce, ma nei casi dubbi la copertina la guarda l'AI (server).
    case veloce
    /// completa: più immagini e candidati, AI che legge la foto se il testo non basta.
    case completa

    var id: String { rawValue }
    var label: String {
        switch self {
        case .superVeloce: "Super veloce"
        case .veloce: "Veloce"
        case .completa: "Completa"
        }
    }
    var imagesPerRelease: Int { self == .completa ? 4 : 1 }
    var maxCandidates: Int {
        switch self {
        case .superVeloce: 5
        case .veloce: 3
        case .completa: 6
        }
    }
    var usesAI: Bool { self != .superVeloce }
}
