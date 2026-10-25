import AVFoundation
import UIKit

/// I suoni dell'interfaccia (V60): i file di JARVIS, con la stessa logica di JARVIS (file in Resources/Suoni).
/// Lo stesso suono vuol dire sempre la stessa cosa, come nel mock-up approvato:
///   «tick»            un tocco: sezioni, Vendi/Bozza, passi, tracce; un tick leggero per ogni icona all'avvio;
///                     nel REC un tick per ogni disco agganciato
///   «clicktesta»      le icone tonde in alto (X della fotocamera e del lettore, Seleziona, grafico, menu)
///   «apertura»        l'app si apre (mp3 scelto da Alessandro: resta quello di prima)
///   «aperturacamera»  la fotocamera si apre
///   «scheda» → «schedapronta»   qualcosa carica → è pronto (il primo sfuma quando parte il secondo):
///                     scatto → disco riconosciuto, Statistiche che contano → grafico disegnato
///   «chatcarica»      il testo che si stampa (Bozze, Magazzino, Settings, finestra Ascolto); sfuma con `chatPronta()`
///   «chatsvuota»      qualcosa che si toglie: Elimina, Pubblica che svuota le Bozze, ordine annullato
///   «pronto»          il «fatto»: online su Discogs, Spedito, Pubblica finita, fine del REC
/// L'errore (non riconosciuto) è un doppio segnale basso generato al volo.
/// Si spengono in Settings › Suoni dell'interfaccia.
@MainActor
enum Suoni {
    static var attivi: Bool { UserDefaults.standard.object(forKey: "suoni") as? Bool ?? true }

    // MARK: - I suoni

    /// Un tocco.
    static func tocco() { riproduci("tick", volume: 1.0) }
    /// Un'icona in basso che si carica all'avvio (più leggero del tocco).
    static func icona() { riproduci("tick", volume: 0.6) }
    /// Le icone tonde in alto.
    static func testa() { riproduci("clicktesta", volume: 1.0) }
    /// L'app si apre (file «apertura»).
    static func apertura() { riproduci("apertura", volume: 0.8) }
    /// La fotocamera si apre.
    static func camera() { riproduci("aperturacamera", volume: 1.0) }
    /// Il «fatto».
    static func fatto() { riproduci("pronto", volume: 1.0) }
    /// Qualcosa si toglie o si svuota.
    static func svuota() { riproduci("chatsvuota", volume: 1.0) }

    /// Qualcosa carica («scheda»): sfuma quando arriva `schedaPronta()`.
    static func schedaApre() {
        guard attivi, let p = lettore("scheda", volume: 1.0) else { return }
        lettoreScheda?.stop()
        lettoreScheda = p
        p.play()
    }
    /// È pronto: il caricamento sfuma e parte «schedapronta».
    static func schedaPronta() {
        guard attivi else { return }
        sfuma(lettoreScheda, 0.18)
        lettoreScheda = nil
        riproduci("schedapronta", volume: 1.0)
    }
    /// Il testo che si stampa: sfuma con `chatPronta()`.
    static func chatCarica() {
        guard attivi, let p = lettore("chatcarica", volume: 0.7) else { return }
        lettoreChat?.stop()
        lettoreChat = p
        p.play()
    }
    static func chatPronta() {
        sfuma(lettoreChat, 0.25)
        lettoreChat = nil
    }

    // MARK: - I nomi di prima (chi li chiama non cambia: cambia solo il suono)

    static func avvio() { camera() }
    /// Dopo lo scatto, mentre cerca il disco.
    static func guardo() { schedaApre() }
    /// Disco riconosciuto.
    static func riconosciuto() { schedaPronta() }
    /// Si apre una scheda accessoria (scheda annuncio, Versioni).
    static func apri() { tocco() }
    static func click() { tocco() }
    /// Vendi / Bozza: parte l'annuncio.
    static func carica() { tocco() }
    /// L'annuncio è su Discogs.
    static func online() { fatto() }
    /// Pubblica tutto: tocco alla partenza, «fatto» alla fine.
    static func pubblico() { tocco() }
    static func fine() { fatto() }
    /// Spunte, − / + del prezzo, Seleziona.
    static func seleziona() { tocco() }
    /// Discogs rifiuta o non risponde.
    static func nego() { errore() }
    static func nuovoOrdine() { riproduci("schedapronta", volume: 1.0) }
    /// Statistiche: il caricamento lo fanno `schedaApre` / `schedaPronta`.
    static func elaboro() {}
    static func pronto() {}

    /// Non riconosciuto.
    static func errore() {
        guard attivi else { return }
        sfuma(lettoreScheda, 0.18)
        lettoreScheda = nil
        let dati = cacheErrore ?? generaErrore()
        cacheErrore = dati
        guard let p = try? AVAudioPlayer(data: dati) else { return }
        p.volume = 0.3
        tieni(p)
        p.play()
    }

    // MARK: - Lettori

    private static var lettoreScheda: AVAudioPlayer?
    private static var lettoreChat: AVAudioPlayer?
    private static var lettori: [AVAudioPlayer] = []
    private static var cacheErrore: Data?

    private static func sfuma(_ p: AVAudioPlayer?, _ secondi: TimeInterval) {
        guard let p, p.isPlaying else { return }
        p.setVolume(0, fadeDuration: secondi)
        DispatchQueue.main.asyncAfter(deadline: .now() + secondi + 0.02) { p.stop() }
    }

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
