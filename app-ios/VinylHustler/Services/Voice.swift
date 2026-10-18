import AVFoundation
import Foundation

/// La voce di Vinyl Hustler: quando riconosce un disco te lo dice, chiamandoti per nome.
/// "Ciao Marco, questo è Kind Of Blue di Miles Davis."
/// Parla con la voce ElevenLabs di Vinyl Hustler (dal server, con la memoria condivisa delle frasi e la pronuncia
/// condivisa); oppure con la voce Apple del telefono; oppure sta zitta (Console › Voce).
@MainActor
final class Voice {
    static let shared = Voice()
    private let synth = AVSpeechSynthesizer()

    /// Nome con cui l'app ti saluta (Console). Vuoto = niente nome.
    var name: String { UserDefaults.standard.string(forKey: "userName") ?? "" }

    /// Console › Voce: "eleven" = voce Vinyl Hustler (ElevenLabs), "apple" = voce del telefono (gratis), "off" = muta.
    enum Mode: String, CaseIterable { case eleven, apple, off }
    var mode: Mode {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: "voceModo"), let m = Mode(rawValue: raw) { return m }
        // impostazione delle versioni di prima
        return d.object(forKey: "voceElevenLabs") as? Bool == false ? .apple : .eleven
    }
    /// Parla se in Console c'è una voce e se non l'hai zittita col tasto in fotocamera.
    var enabled: Bool { mode != .off && UserDefaults.standard.object(forKey: "voice") as? Bool != false }
    /// Console › "Modello veloce": ElevenLabs Flash, metà prezzo (stessa voce, un po' meno ricca).
    var fast: Bool { UserDefaults.standard.bool(forKey: "voceVeloce") }

    /// Il saluto e il titolo sono due pezzi: "Ciao Marco." si genera una volta per persona,
    /// "questo è Kind Of Blue di Miles Davis." una volta per tutti gli utenti (memoria condivisa della voce).
    func say(found discs: [Disc]) {
        sayTitles(discs.compactMap { d in d.status == .daConfermare ? Self.spoken(d.releaseTitle) : nil })
    }

    func sayTitles(_ names: [String]) {
        let body: String
        switch names.count {
        case 0: body = "Questo non lo riconosco. Prova un'altra foto."
        case 1: body = "Questo è \(names[0])."
        default: body = "Ne ho trovati \(names.count): " + names.joined(separator: "; ") + "."
        }
        speak(name.isEmpty ? [body] : ["Ciao \(name).", body])
    }

    func say(_ text: String) { speak([text]) }

    // MARK: - Voce ElevenLabs (la voce di Vinyl Hustler)

    var useEleven: Bool { mode == .eleven }
    private var player: AVAudioPlayer?
    private var turn = 0

    /// Le frasi già sentite restano sul telefono: la seconda volta parte subito e non costa niente.
    private static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Voce")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func cacheURL(_ text: String, ext: String) -> URL {
        Self.cacheDir.appendingPathComponent(Backend.sha256(text + (fast ? "|fast" : "")) + "." + ext)
    }
    /// Dopo una correzione di pronuncia le frasi salvate sul telefono vanno rifatte.
    static func clearCache() { try? FileManager.default.removeItem(at: cacheDir) }

    /// Dice i pezzi uno dopo l'altro. Una frase nuova interrompe quella in corso.
    private func speak(_ parts: [String]) {
        guard enabled else { return }
        turn += 1
        let mine = turn
        player?.stop()
        if engineReady { node.stop() }
        if synth.isSpeaking { synth.stopSpeaking(at: .word) }
        guard useEleven, Backend.shared.isConfigured else { sayApple(parts.joined(separator: " ")); return }
        Task { @MainActor in
            for (i, part) in parts.enumerated() {
                guard mine == turn else { return }
                if await sayEleven(part, turn: mine) { continue }
                // niente rete o server fermo: il resto lo dice la voce Apple
                if mine == turn { sayApple(parts[i...].joined(separator: " ")) }
                return
            }
        }
    }

    /// Un pezzo con la voce ElevenLabs; torna quando ha finito di parlare. false = non è riuscito.
    private func sayEleven(_ text: String, turn mine: Int) async -> Bool {
        // 1. già detta su questo telefono
        if let cached = (try? Data(contentsOf: cacheURL(text, ext: "wav"))) ?? (try? Data(contentsOf: cacheURL(text, ext: "mp3"))) {
            return await playAndWait(cached, turn: mine)
        }
        // 2. dal server: già detta da qualcuno (gratis) o nuova, in streaming
        if let ok = await stream(text, turn: mine) { return ok }
        // 3. riserva: frase intera in mp3
        guard mine == turn, let audio = await request(text, stream: false) else { return false }
        try? audio.data.write(to: cacheURL(text, ext: audio.ext))
        return await playAndWait(audio.data, turn: mine)
    }

    private func request(_ text: String, stream: Bool) async -> (data: Data, ext: String)? {
        guard let req = await voiceRequest(["text": text, "stream": stream, "fast": fast]),
              let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200, !result.0.isEmpty else { return nil }
        return (result.0, (result.1.mimeType ?? "").contains("wav") ? "wav" : "mp3")
    }

    private func voiceRequest(_ body: [String: Any]) async -> URLRequest? {
        guard let base = AppConfig.supabaseURL, let token = await Backend.shared.accessToken() else { return nil }
        var req = URLRequest(url: base.appendingPathComponent("functions/v1/voce"), timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func playAndWait(_ audio: Data, turn mine: Int) async -> Bool {
        guard let p = try? AVAudioPlayer(data: audio) else { return false }
        activateSession()
        player = p
        p.play()
        try? await Task.sleep(for: .seconds(p.duration + 0.05))
        return true
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: - Pronuncia condivisa (Console › Pronuncia)

    struct Rule: Decodable, Identifiable, Hashable {
        var word: String
        var sayAs: String
        var id: String { word }
    }

    /// Le regole, e se chi chiede può cambiarle (solo gli amministratori).
    static func rules() async -> (rules: [Rule], admin: Bool) {
        guard let req = await shared.voiceRequest(["task": "lexicon"]),
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
        guard let req = await shared.voiceRequest(["task": "lexicon_set", "word": word, "say": say]),
              let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return false }
        clearCache()
        return true
    }

    // MARK: - Streaming (PCM 16 bit, 24 kHz, mono)

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var engineReady = false
    private static let sampleRate = 24_000.0
    private static let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    /// Chiede la frase al server. Se è già stata detta da qualcuno arriva intera (WAV, gratis); se è nuova arriva
    /// in streaming e si suona mentre arriva. Torna quando ha finito di parlare. nil = il server non ha risposto.
    private func stream(_ text: String, turn mine: Int) async -> Bool? {
        guard let req = await voiceRequest(["text": text, "stream": true, "fast": fast]),
              let result = try? await URLSession.shared.bytes(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let bytes = result.0
        let mime = result.1.mimeType ?? ""

        // frase condivisa: arriva tutta, la si salva e la si suona
        if !mime.contains("pcm") {
            var data = Data()
            do { for try await b in bytes { data.append(b) } } catch { return nil }
            guard !data.isEmpty else { return nil }
            try? data.write(to: cacheURL(text, ext: mime.contains("wav") ? "wav" : "mp3"))
            return await playAndWait(data, turn: mine)
        }

        if !engineReady {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: Self.pcm)
            engineReady = true
        }
        activateSession()
        guard (try? engine.start()) != nil else { return nil }
        node.stop()

        let chunk = Int(Self.sampleRate * 0.2) * 2           // 0,2 s di audio a 16 bit
        var pending = Data(), all = Data()
        var startedAt: Date?
        func flush() {
            let even = pending.count - pending.count % 2
            guard even > 0 else { return }
            let piece = pending.prefix(even)
            schedule(piece)
            all.append(piece)
            pending.removeFirst(even)
            if startedAt == nil { node.play(); startedAt = Date() }
        }
        do {
            for try await byte in bytes {
                if mine != turn { node.stop(); return true }   // è arrivata un'altra frase: questa si ferma
                pending.append(byte)
                if pending.count >= chunk { flush() }
            }
        } catch {
            if startedAt == nil { return nil }
        }
        flush()
        guard let startedAt else { return nil }
        try? Self.wav(all).write(to: cacheURL(text, ext: "wav"))
        // aspetta che finisca di parlare prima del pezzo dopo
        let total = Double(all.count / 2) / Self.sampleRate
        let left = total - Date().timeIntervalSince(startedAt)
        if left > 0 { try? await Task.sleep(for: .seconds(left + 0.05)) }
        return true
    }

    /// PCM 16 bit little-endian -> buffer float, in coda al lettore.
    private func schedule(_ data: Data) {
        let frames = data.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: Self.pcm, frameCapacity: AVAudioFrameCount(frames)),
              let out = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            for i in 0..<frames {
                let s = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                out[i] = Float(s) / 32768
            }
        }
        node.scheduleBuffer(buf)
    }

    /// Un file WAV (PCM 16 bit, 24 kHz, mono) dai byte arrivati.
    private static func wav(_ pcm: Data) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + UInt32(pcm.count)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }

    /// La voce Apple del telefono (riserva, o scelta in Console).
    private func sayApple(_ text: String) {
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
