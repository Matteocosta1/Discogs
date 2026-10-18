import AVFoundation
import Foundation
import Observation

/// Gli estratti di 30 secondi dei brani, da Apple Music (iTunes Search API: gratis, senza abbonamento,
/// non conta nelle 60 richieste al minuto di Discogs). Si cercano artista e album, poi si abbinano
/// i brani della lista tracce di Discogs per titolo.
enum Anteprime {
    struct Song: Decodable {
        var trackName: String?
        var collectionName: String?
        var previewUrl: String?
    }
    private struct Response: Decodable { var results: [Song] }

    /// Titolo normalizzato per il confronto: minuscolo, senza accenti, senza "(Remastered)" e simili.
    nonisolated static func key(_ s: String) -> String {
        let noParens = s.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        let folded = noParens.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// Per ogni titolo di traccia, l'indirizzo dell'estratto (se Apple Music lo ha).
    static func find(artist: String, album: String, tracks: [String]) async -> [String: URL] {
        let artistClean = artist.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: "\(artistClean) \(album)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "IT"),
        ]
        guard let url = comps.url,
              let result = try? await URLSession.shared.data(from: url),
              let songs = try? JSONDecoder().decode(Response.self, from: result.0).results else { return [:] }
        let albumKey = key(album)
        // prima i brani dello stesso album, poi gli altri (raccolte, ristampe)
        let sorted = songs.sorted { a, b in
            let ia = key(a.collectionName ?? "").contains(albumKey) ? 0 : 1
            let ib = key(b.collectionName ?? "").contains(albumKey) ? 0 : 1
            return ia < ib
        }
        var out: [String: URL] = [:]
        for t in tracks {
            let k = key(t)
            guard !k.isEmpty else { continue }
            let hit = sorted.first { s in
                let sk = key(s.trackName ?? "")
                return sk == k || (k.count > 4 && sk.count > 4 && (sk.hasPrefix(k) || k.hasPrefix(sk)))
            }
            if let p = hit?.previewUrl, let u = URL(string: p) { out[t] = u }
        }
        return out
    }
}

/// Il lettore degli estratti: uno alla volta, si ferma da solo alla fine.
@Observable
final class AnteprimaPlayer {
    private(set) var playing: String?          // il titolo della traccia che sta suonando
    private(set) var progress = 0.0
    private var player: AVPlayer?
    private var observer: Any?

    func toggle(_ title: String, url: URL) {
        if playing == title { stop(); return }
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let p = AVPlayer(url: url)
        player = p
        playing = title
        progress = 0
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self, let item = self.player?.currentItem else { return }
            let total = item.duration.seconds
            guard total.isFinite, total > 0 else { return }
            self.progress = min(1, time.seconds / total)
            if time.seconds >= total - 0.1 { self.stop() }
        }
        p.play()
    }

    func stop() {
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        playing = nil
        progress = 0
    }
}
