import AVFoundation
import Foundation

/// La voce di Vinyl Hustler: quando riconosce un disco te lo dice, chiamandoti per nome.
/// "Ciao Marco, questo è Kind Of Blue di Miles Davis."
/// Parla con la voce ElevenLabs di Vinyl Hustler (dal server); se non c'è rete, con la voce Apple del telefono.
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

    // MARK: - Voce ElevenLabs (la voce di Vinyl Hustler)

    /// Console › "Voce Vinyl Hustler": la voce ElevenLabs dal server (funzione `voce`). Se manca la rete
    /// o il server non risponde, parla la voce Apple: l'app non resta mai muta.
    var useEleven: Bool { UserDefaults.standard.object(forKey: "voceElevenLabs") as? Bool ?? true }
    private var player: AVAudioPlayer?
    private var turn = 0

    /// Le frasi già sentite restano sul telefono: la seconda volta parte subito e non costa niente.
    private static func cacheURL(_ text: String, ext: String = "mp3") -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Voce")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(Backend.sha256(text) + "." + ext)
    }

    private func elevenAudio(_ text: String) async -> Data? {
        let file = Self.cacheURL(text)
        if let cached = try? Data(contentsOf: file) { return cached }
        guard let base = AppConfig.supabaseURL, let token = await Backend.shared.accessToken() else { return nil }
        var req = URLRequest(url: base.appendingPathComponent("functions/v1/voce"), timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        guard let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200, !result.0.isEmpty else { return nil }
        let data = result.0
        try? data.write(to: file)
        return data
    }

    func say(_ text: String) {
        guard enabled else { return }
        turn += 1
        let mine = turn
        player?.stop()
        if engineReady { node.stop() }
        if synth.isSpeaking { synth.stopSpeaking(at: .word) }
        guard useEleven, Backend.shared.isConfigured else { sayApple(text); return }
        Task { @MainActor in
            // 1. già detta su questo telefono: parte subito, gratis
            let wav = Self.cacheURL(text, ext: "wav"), mp3 = Self.cacheURL(text)
            if let cached = (try? Data(contentsOf: wav)) ?? (try? Data(contentsOf: mp3)) {
                play(cached)
                return
            }
            // 2. in streaming: parla mentre ElevenLabs genera la frase
            if await stream(text, turn: mine) { return }
            guard mine == turn else { return }
            // 3. riserva: la frase intera in mp3, poi la voce Apple
            if let audio = await elevenAudio(text), mine == turn, play(audio) { return }
            if mine == turn { sayApple(text) }
        }
    }

    @discardableResult
    private func play(_ audio: Data) -> Bool {
        guard let p = try? AVAudioPlayer(data: audio) else { return false }
        activateSession()
        player = p
        p.play()
        return true
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: - Streaming (PCM 16 bit, 24 kHz, mono)

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var engineReady = false
    private static let sampleRate = 24_000.0
    private static let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    /// Chiede la frase in streaming e la suona mentre arriva (parte dopo ~0,2 s di audio).
    /// Alla fine la salva come WAV, così la prossima volta è istantanea. false = non è partita: si usa la riserva.
    private func stream(_ text: String, turn mine: Int) async -> Bool {
        guard let base = AppConfig.supabaseURL, let token = await Backend.shared.accessToken() else { return false }
        var req = URLRequest(url: base.appendingPathComponent("functions/v1/voce"), timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "stream": true])
        guard let result = try? await URLSession.shared.bytes(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              (result.1.mimeType ?? "").contains("pcm") else { return false }
        let bytes = result.0

        if !engineReady {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: Self.pcm)
            engineReady = true
        }
        activateSession()
        guard (try? engine.start()) != nil else { return false }
        node.stop()

        let chunk = Int(Self.sampleRate * 0.2) * 2           // 0,2 s di audio a 16 bit
        var pending = Data(), all = Data()
        var started = false
        func flush() {
            let even = pending.count - pending.count % 2
            guard even > 0 else { return }
            let piece = pending.prefix(even)
            schedule(piece)
            all.append(piece)
            pending.removeFirst(even)
            if !started { node.play(); started = true }
        }
        do {
            for try await byte in bytes {
                if mine != turn { node.stop(); return true }   // è arrivata un'altra frase: questa si ferma
                pending.append(byte)
                if pending.count >= chunk { flush() }
            }
        } catch {
            if !started { return false }
        }
        flush()
        guard started else { return false }
        try? Self.wav(all).write(to: Self.cacheURL(text, ext: "wav"))
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
