import AVFoundation
import UIKit

/// I suoni dell'interfaccia, gli stessi di JARVIS (file in Resources/Suoni):
///   «tick»          tocco su un tasto
///   «avvio»         l'app si accende / la fotocamera aggancia
///   «scheda»        parte il riconoscimento ("sto guardando…")
///   «schedapronta»  disco riconosciuto
///   «apertura»      apertura dell'app (mp3 scelto da Alessandro)
///   «carica»        Vendi o Bozza: l'annuncio sta partendo (nuovo, V39)
///   «pubblico»      Pubblica tutto: suona mentre pubblica, sfuma alla fine (nuovo, V39)
/// L'errore (non riconosciuto) è un doppio segnale basso generato al volo.
/// I due nuovi sono di RescopicSound (Pixabay), scelti da Alessandro; gli altri restano quelli di sempre.
/// Si spengono in Console › Suoni dell'interfaccia.
@MainActor
enum Suoni {
    static var attivi: Bool { UserDefaults.standard.object(forKey: "suoni") as? Bool ?? true }

    static func tocco() { riproduci("tick", volume: 0.55) }
    static func avvio() { riproduci("avvio", volume: 0.7) }
    /// All'apertura dell'app (file «apertura»; se manca, il suono d'avvio di JARVIS).
    static func apertura() {
        guard attivi else { return }
        if let p = lettore("apertura", volume: 0.8) { tieni(p); p.play() } else { avvio() }
    }

    /// Parte il riconoscimento.
    static func guardo() {
        guard attivi, let p = lettore("scheda", volume: 0.75) else { return }
        lettoreScheda?.stop()
        lettoreScheda = p
        p.play()
    }

    /// Disco riconosciuto: il suono del caricamento sfuma e parte quello di "pronto".
    static func riconosciuto() {
        guard attivi else { return }
        if let p = lettoreScheda, p.isPlaying { p.setVolume(0, fadeDuration: 0.18) }
        riproduci("schedapronta", volume: 0.8)
    }

    /// Vendi / Bozza: parte l'annuncio.
    static func carica() { riproduci("carica", volume: 0.6) }

    /// L'annuncio è su Discogs.
    static func online() { riproduci("schedapronta", volume: 0.8) }

    /// Pubblica tutto: il suono gira mentre pubblica; fine() lo sfuma.
    static func pubblico() {
        guard attivi, let p = lettore("pubblico", volume: 0.6) else { return }
        lettorePubblico?.stop()
        p.numberOfLoops = -1
        lettorePubblico = p
        p.play()
    }

    static func fine() {
        guard let p = lettorePubblico else { return }
        p.setVolume(0, fadeDuration: 0.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { p.stop() }
        lettorePubblico = nil
        online()
    }

    /// Non riconosciuto.
    static func errore() {
        guard attivi else { return }
        if let p = lettoreScheda, p.isPlaying { p.setVolume(0, fadeDuration: 0.18) }
        let dati = cacheErrore ?? generaErrore()
        cacheErrore = dati
        guard let p = try? AVAudioPlayer(data: dati) else { return }
        p.volume = 0.3
        tieni(p)
        p.play()
    }

    // MARK: - Lettori

    private static var lettoreScheda: AVAudioPlayer?
    private static var lettorePubblico: AVAudioPlayer?
    private static var lettori: [AVAudioPlayer] = []
    private static var cacheErrore: Data?

    private static func lettore(_ nome: String, volume: Float) -> AVAudioPlayer? {
        guard let url = ["m4a", "mp3", "wav", "caf"].lazy
                .compactMap({ Bundle.main.url(forResource: nome, withExtension: $0) }).first,
              let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        p.volume = volume
        return p
    }

    private static func riproduci(_ nome: String, volume: Float) {
        guard attivi, let p = lettore(nome, volume: volume) else { return }
        tieni(p)
        p.play()
    }

    private static func tieni(_ p: AVAudioPlayer) {
        lettori.removeAll { !$0.isPlaying }
        lettori.append(p)
    }

    /// Due toni bassi, morbidi (come «errore» in JARVIS), scritti come WAV in memoria.
    private static func generaErrore() -> Data {
        let freq = 44100.0
        let note: [(da: Double, a: Double, inizio: Double, durata: Double)] = [(240, 200, 0, 0.12), (240, 200, 0.16, 0.12)]
        let campioni = Int(freq * 0.31)
        var pcm = [Float](repeating: 0, count: campioni)
        for n in note {
            let da = Int(n.inizio * freq), lunghezza = Int(n.durata * freq)
            var fase = 0.0
            for k in 0..<lunghezza where da + k < campioni {
                let p = Double(k) / Double(lunghezza)
                fase += 2 * .pi * (n.da + (n.a - n.da) * p) / freq
                let inviluppo = min(1, p * 25) * pow(1 - p, 1.6)
                pcm[da + k] += Float((sin(fase) + 0.25 * sin(2 * fase)) * inviluppo * 0.45)
            }
        }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let byte = UInt32(pcm.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + byte); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(44100); u32(88200); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(byte)
        for v in pcm { u16(UInt16(bitPattern: Int16(max(-1, min(1, v)) * 32767))) }
        return d
    }
}
