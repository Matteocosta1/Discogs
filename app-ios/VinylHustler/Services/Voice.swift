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
        if voiceID == Self.systemChoice {
            u.prefersAssistiveTechnologySettings = true      // la voce scelta in Impostazioni › Contenuti letti
            u.voice = AVSpeechSynthesisVoice(language: "it-IT")
        } else {
            u.voice = AVSpeechSynthesisVoice(identifier: voiceID) ?? Self.italian
            u.rate = AVSpeechUtteranceDefaultSpeechRate
        }
        synth.speak(u)
    }

    // MARK: - Scelta della voce (Console)

    /// "sistema" (predefinita) = quella delle impostazioni di iOS; "" = la migliore italiana installata; altrimenti l'id della voce.
    static let systemChoice = "sistema"
    var voiceID: String { UserDefaults.standard.string(forKey: "voiceID") ?? Self.systemChoice }

    /// Le voci italiane del telefono, dalla più bella (Premium, Avanzata) alla base.
    static var italianVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("it") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: "\(v.name) · Premium"
        case .enhanced: "\(v.name) · Avanzata"
        default: v.name
        }
    }

    /// True se sul telefono c'è almeno una voce italiana Avanzata o Premium.
    static var hasNiceVoice: Bool { italianVoices.contains { $0.quality != .default } }

    /// "Miles Davis - Kind Of Blue (Columbia, US, 1959)" -> "Kind Of Blue di Miles Davis"
    nonisolated static func spoken(_ title: String) -> String {
        let parts = title.components(separatedBy: " - ")
        guard parts.count >= 2 else { return title }
        let artist = parts[0].replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
        let album = parts.dropFirst().joined(separator: " - ")
            .replacingOccurrences(of: #" \([^()]*\)$"#, with: "", options: .regularExpression)
        return "\(album) di \(artist)"
    }

    /// La voce italiana migliore installata (Premium > Avanzata > base).
    private static var italian: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "it-IT" }
            .max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "it-IT")
    }
}
