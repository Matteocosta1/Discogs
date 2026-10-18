import AVFoundation
import Foundation
import NaturalLanguage

/// La voce di Vinyl Hustler: quando riconosce un disco te lo dice, chiamandoti per nome.
/// "Ciao Marco, questo è Kind Of Blue di Miles Davis."
/// Dalla V49 parla solo con la voce Apple del telefono: gratis per tutti, anche senza rete.
/// Per pronunciare bene i titoli, la frase si divide in pezzi: le parole dell'app in italiano,
/// album e artista con la voce della loro lingua (inglese, francese, tedesca…), riconosciuta dal telefono.
/// Le parole difficili si correggono in Console › Voce › Pronuncia (valgono per tutti gli utenti).
@MainActor
final class Voice {
    static let shared = Voice()
    private let synth = AVSpeechSynthesizer()

    /// Nome con cui l'app ti saluta (Console). Vuoto = niente nome.
    var name: String { UserDefaults.standard.string(forKey: "userName") ?? "" }

    /// Console › Voce: "apple" = voce del telefono, "off" = muta.
    /// "eleven" (la voce a pagamento delle versioni fino alla V48) ora vale come "apple".
    enum Mode: String, CaseIterable { case apple, off }
    var mode: Mode { UserDefaults.standard.string(forKey: "voceModo") == "off" ? .off : .apple }
    /// Parla se in Console c'è una voce e se non l'hai zittita col tasto in fotocamera.
    var enabled: Bool { mode != .off && UserDefaults.standard.object(forKey: "voice") as? Bool != false }

    // MARK: - Cosa dice

    /// Un pezzo di frase: in italiano (le parole dell'app) o nella lingua del titolo.
    struct Segment {
        var text: String
        var italian: Bool
        static func it(_ t: String) -> Segment { Segment(text: t, italian: true) }
        static func title(_ t: String) -> Segment { Segment(text: t, italian: false) }
    }

    func say(found discs: [Disc]) {
        sayReleases(discs.compactMap { d in d.status == .daConfermare ? d.releaseTitle : nil })
    }

    /// titles: "Miles Davis - Kind Of Blue (Columbia, US, 1959)", come il titolo dei dischi.
    func sayReleases(_ titles: [String]) {
        var segs: [Segment] = name.isEmpty ? [] : [.it("Ciao \(name).")]
        switch titles.count {
        case 0:
            segs.append(.it("Questo non lo riconosco. Prova un'altra foto."))
        case 1:
            segs.append(.it("Questo è"))
            segs += Self.segments(titles[0])
        default:
            segs.append(.it("Ne ho trovati \(titles.count):"))
            for (i, t) in titles.enumerated() {
                segs += Self.segments(t)
                if i < titles.count - 1 { segs.append(.it(";")) }
            }
        }
        speak(segs)
    }

    func say(_ text: String) { speak([.it(text)]) }

    /// "Miles Davis - Kind Of Blue (…)" -> [Kind Of Blue] [di] [Miles Davis]
    static func segments(_ title: String) -> [Segment] {
        guard let p = parts(title) else { return [.title(title)] }
        return [.title(p.album), .it("di"), .title(p.artist)]
    }

    /// Album e artista dal titolo del disco, senza "(2)" dopo l'artista e senza "(etichetta, paese, anno)".
    nonisolated static func parts(_ title: String) -> (album: String, artist: String)? {
        let pieces = title.components(separatedBy: " - ")
        guard pieces.count >= 2 else { return nil }
        let artist = pieces[0].replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
        let album = pieces.dropFirst().joined(separator: " - ")
            .replacingOccurrences(of: #" \([^()]*\)$"#, with: "", options: .regularExpression)
        return (album, artist)
    }

    /// "Miles Davis - Kind Of Blue (Columbia, US, 1959)" -> "Kind Of Blue di Miles Davis"
    nonisolated static func spoken(_ title: String) -> String {
        guard let p = parts(title) else { return title }
        return "\(p.album) di \(p.artist)"
    }

    // MARK: - Come lo dice

    /// Dice i pezzi uno dopo l'altro. Una frase nuova interrompe quella in corso.
    private func speak(_ segs: [Segment]) {
        guard enabled else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        if Self.lexicon == nil { Task { await Self.loadLexicon() } }   // la prima volta: le regole arrivano per la prossima frase
        for seg in segs { synth.speak(utterance(seg)) }
    }

    private func utterance(_ seg: Segment) -> AVSpeechUtterance {
        let fixed = Self.applyLexicon(seg)
        let u = AVSpeechUtterance(attributedString: fixed.text)
        u.postUtteranceDelay = 0.02
        if fixed.italian {
            if voiceID == Self.systemChoice {
                u.prefersAssistiveTechnologySettings = true      // la voce scelta in Impostazioni › Contenuti letti
                u.voice = AVSpeechSynthesisVoice(language: "it-IT")
            } else {
                u.voice = AVSpeechSynthesisVoice(identifier: voiceID) ?? Self.best("it")
            }
        } else {
            let lang = Self.language(of: seg.text)
            u.voice = lang == "it" ? Self.best("it") : (Self.best(lang) ?? Self.best("en"))
        }
        return u
    }

    /// La lingua di un titolo: "en", "fr", "de", "es", "pt", "it"… Nel dubbio inglese, la lingua dei dischi.
    nonisolated static func language(of text: String) -> String {
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.english, .italian, .french, .german, .spanish, .portuguese, .dutch, .swedish]
        r.languageHints = [.english: 0.6, .italian: 0.12, .french: 0.08, .german: 0.07, .spanish: 0.07,
                           .portuguese: 0.03, .dutch: 0.02, .swedish: 0.01]
        r.processString(text)
        guard let best = r.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }), best.value >= 0.6 else {
            return "en"
        }
        return best.key.rawValue
    }

    /// La voce più bella installata per una lingua (Premium > Avanzata > base).
    static func best(_ lang: String) -> AVSpeechSynthesisVoice? {
        let preferred = ["en": "en-GB", "it": "it-IT", "fr": "fr-FR", "de": "de-DE", "es": "es-ES", "pt": "pt-PT"][lang]
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(lang) }
            .max { a, b in
                if a.quality != b.quality { return a.quality.rawValue < b.quality.rawValue }
                return (a.language == preferred ? 1 : 0) < (b.language == preferred ? 1 : 0)
            } ?? AVSpeechSynthesisVoice(language: preferred ?? lang)
    }

    // MARK: - Pronuncia condivisa (Console › Pronuncia)

    struct Rule: Decodable, Identifiable, Hashable {
        var word: String
        var sayAs: String
        var id: String { word }
        /// "/ʃɑːˈdeɪ/" = pronuncia fonetica (alfabeto IPA), detta dalla voce della lingua del titolo.
        var isIPA: Bool { sayAs.count > 2 && sayAs.hasPrefix("/") && sayAs.hasSuffix("/") }
    }

    private static var lexicon: [Rule]?

    static func loadLexicon() async {
        lexicon = await rules().rules
    }

    /// Le regole di pronuncia applicate a un pezzo. Una parola scritta "all'italiana" (Màils Dèivis)
    /// si dice con la voce italiana; una pronuncia fonetica /…/ con la voce della lingua del titolo.
    private static func applyLexicon(_ seg: Segment) -> (text: NSAttributedString, italian: Bool) {
        var text = seg.text
        var italian = seg.italian
        var ipa: [(String, String)] = []          // (parola, pronuncia) da marcare dopo
        for r in lexicon ?? [] where !r.word.isEmpty {
            guard text.range(of: r.word, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }
            if r.isIPA {
                ipa.append((r.word, String(r.sayAs.dropFirst().dropLast())))
            } else {
                text = text.replacingOccurrences(of: r.word, with: r.sayAs, options: [.caseInsensitive, .diacriticInsensitive])
                italian = true
            }
        }
        let out = NSMutableAttributedString(string: text)
        let key = NSAttributedString.Key(rawValue: AVSpeechSynthesisIPANotationAttribute)
        for item in ipa {
            let ns = text as NSString
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let found = ns.range(of: item.0, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                if found.location == NSNotFound { break }
                out.addAttribute(key, value: item.1, range: found)
                let next = found.location + found.length
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        return (out, italian)
    }

    /// Le regole, e se chi chiede può cambiarle (solo gli amministratori).
    static func rules() async -> (rules: [Rule], admin: Bool) {
        guard let req = await voiceRequest(["task": "lexicon"]),
              let result = try? await URLSession.shared.data(for: req) else { return ([], false) }
        struct Out: Decodable { var rules: [Rule]; var admin: Bool? }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        guard let out = try? d.decode(Out.self, from: result.0) else { return ([], false) }
        return (out.rules, out.admin ?? false)
    }

    /// Salva come si dice una parola (vuoto = toglie la regola). Vale per tutti gli utenti. Solo amministratori.
    @discardableResult
    static func setRule(word: String, say: String) async -> Bool {
        guard let req = await voiceRequest(["task": "lexicon_set", "word": word, "say": say]),
              let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return false }
        await loadLexicon()
        return true
    }

    /// Le regole stanno sul server (funzione "voce", tabella voice_lexicon).
    private static func voiceRequest(_ body: [String: Any]) async -> URLRequest? {
        guard let base = AppConfig.supabaseURL, let token = await Backend.shared.accessToken() else { return nil }
        var req = URLRequest(url: base.appendingPathComponent("functions/v1/voce"), timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - Scelta della voce italiana (Console)

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

    /// True se sul telefono c'è almeno una voce Avanzata o Premium per la lingua ("it", "en").
    static func hasNiceVoice(_ lang: String) -> Bool {
        AVSpeechSynthesisVoice.speechVoices().contains { $0.language.hasPrefix(lang) && $0.quality != .default }
    }
}
