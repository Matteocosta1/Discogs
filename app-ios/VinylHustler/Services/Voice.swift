import AVFoundation
import Foundation

/// La voce di Vinyl Hustler: quando riconosce un disco te lo dice, chiamandoti per nome.
/// "Ciao Marco, questo è Kind Of Blue di Miles Davis."
/// Gira tutta sul telefono (sintesi vocale di Apple): gratis, istantanea, anche col silenzioso.
@MainActor
final class Voice {
    static let shared = Voice()
    private let synth = AVSpeechSynthesizer()

    /// Nome con cui l'app ti saluta (Console). Vuoto = niente nome.
    var name: String { UserDefaults.standard.string(forKey: "userName") ?? "" }
    var enabled: Bool { UserDefaults.standard.object(forKey: "voice") as? Bool ?? true }

    func say(found discs: [Disc]) {
        let hello = name.isEmpty ? "" : "Ciao \(name), "
        let names = discs.compactMap { d in d.status == .daConfermare ? Self.spoken(d.releaseTitle) : nil }
        let text: String
        switch names.count {
        case 0: text = "\(hello)questo non lo riconosco. Prova un'altra foto."
        case 1: text = "\(hello)questo è \(names[0])."
        default: text = "\(hello)ne ho trovati \(names.count): " + names.joined(separator: "; ") + "."
        }
        say(text)
    }

    func say(_ text: String) {
        guard enabled else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        if synth.isSpeaking { synth.stopSpeaking(at: .word) }
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.italian
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synth.speak(u)
    }

    /// "Miles Davis - Kind Of Blue (Columbia, US, 1959)" -> "Kind Of Blue di Miles Davis"
    nonisolated static func spoken(_ title: String) -> String {
        let parts = title.components(separatedBy: " - ")
        guard parts.count >= 2 else { return title }
        let artist = parts[0].replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
        let album = parts.dropFirst().joined(separator: " - ")
            .replacingOccurrences(of: #" \([^()]*\)$"#, with: "", options: .regularExpression)
        return "\(album) di \(artist)"
    }

    /// La voce italiana migliore installata (premium > enhanced > standard).
    private static var italian: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "it-IT" }
            .max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "it-IT")
    }
}
