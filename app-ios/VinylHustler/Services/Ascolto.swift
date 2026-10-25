import AVFoundation
import Foundation
import MusicKit
import Observation

/// ASCOLTA (V59): le tracce del disco appena riconosciuto.
/// Per ogni brano della tracklist Discogs cerca, in quest'ordine:
///   1. Apple Music, brano intero: solo se l'utente ha l'abbonamento (e MusicKit è attivo sull'app);
///   2. Apple, anteprima di 30 secondi: per tutti, gratis (la stessa che si sente su iTunes);
///   3. il video della scheda Discogs (YouTube), se qualcuno l'ha collegato a quel brano.
/// Se non c'è niente il brano resta in lista con "—": lo spazio del lettore non resta mai vuoto finché c'è qualcosa.
@MainActor
@Observable
final class Ascolto {
    static let shared = Ascolto()

    enum Fonte: Equatable { case intero, anteprima, video, nessuna }

    struct Brano: Identifiable, Equatable {
        let id: Int
        let posizione: String          // "A1"
        let titolo: String
        let durataTesto: String        // "9:22", dalla tracklist Discogs
        var appleID: String?           // id del brano nel catalogo Apple
        var anteprima: URL?            // 30 secondi
        var secondiApple: Double?
        var video: String?             // id YouTube del video Discogs
        var secondiVideo: Double?

        /// Il lato del vinile, dalla posizione ("B2" -> "B").
        var lato: String { posizione.first.map { $0.isLetter ? String($0).uppercased() : "" } ?? "" }
    }

    private(set) var releaseID: Int?
    private(set) var titoloDisco = ""
    private(set) var artista = ""
    private(set) var copertina: URL?
    private(set) var brani: [Brano] = []
    private(set) var cercando = false
    private(set) var indice = 0
    private(set) var suona = false
    private(set) var tempo: Double = 0
    private(set) var durata: Double = 0
    private(set) var fonte: Fonte = .nessuna
    /// Il video che sta suonando adesso (lo mostra il lettore grande).
    private(set) var videoID: String?
    /// Comandi al lettore YouTube ("play", "pausa", "stop"): lo collega la vista del video.
    var comandoVideo: ((String) -> Void)?

    private var abbonato = false
    private var usatoApple = false
    private var lettore30: AVPlayer?
    private var orologio: Task<Void, Never>?

    private init() {}

    var corrente: Brano? { brani.indices.contains(indice) ? brani[indice] : nil }

    /// Da dove suonerà (o suona) un brano.
    func fonteDi(_ b: Brano) -> Fonte {
        if b.appleID != nil && abbonato { return .intero }
        if b.anteprima != nil { return .anteprima }
        if b.video != nil { return .video }
        return .nessuna
    }

    /// La fonte da scrivere sotto il lettore: quella in corso, o quella del brano scelto.
    var fonteMostrata: Fonte {
        if fonte != .nessuna { return fonte }
        return corrente.map { fonteDi($0) } ?? .nessuna
    }

    static func scritta(_ f: Fonte) -> String {
        switch f {
        case .intero: "APPLE MUSIC · BRANO INTERO"
        case .anteprima: "APPLE · ANTEPRIMA 30 S"
        case .video: "VIDEO DISCOGS · YOUTUBE"
        case .nessuna: "NON DISPONIBILE"
        }
    }

    static func breve(_ f: Fonte) -> String {
        switch f {
        case .intero: "APPLE"
        case .anteprima: "30 S"
        case .video: "VIDEO"
        case .nessuna: "—"
        }
    }

    // MARK: - Preparazione: tracklist, Apple, video

    /// Il disco riconosciuto è cambiato: nuova tracklist e nuove ricerche. Lo stesso disco: niente.
    func prepara(_ r: Release) async {
        guard r.id != releaseID else { return }
        fermaRiproduzione()
        releaseID = r.id
        titoloDisco = r.title
        artista = r.artist.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
        let img = r.sortedImages.first
        copertina = (img?.uri150 ?? img?.uri).flatMap(URL.init(string:))
        indice = 0
        let tracce = (r.tracklist ?? []).filter { ($0.type_ ?? "track") == "track" && !($0.title ?? "").isEmpty }
        var lista: [Brano] = []
        for (n, t) in tracce.enumerated() {
            lista.append(Brano(id: n, posizione: t.position ?? "", titolo: t.title ?? "", durataTesto: t.duration ?? ""))
        }
        Self.abbinaVideo(&lista, videos: r.videos ?? [])
        brani = lista
        guard !lista.isEmpty else { return }
        cercando = true
        let canzoni = await Self.cercaSuApple(r, artista: artista)
        guard releaseID == r.id else { return }              // nel frattempo è cambiato disco
        var conApple = brani
        Self.abbinaApple(&conApple, canzoni: canzoni)
        brani = conApple
        if MusicAuthorization.currentStatus == .authorized {
            abbonato = (try? await MusicSubscription.current)?.canPlayCatalogContent ?? false
        }
        cercando = false
    }

    /// Fine: il disco è stato deciso o la fotocamera si chiude.
    func chiudi() {
        fermaRiproduzione()
        releaseID = nil
        brani = []
        copertina = nil
        cercando = false
    }

    // MARK: - Comandi

    func metti(_ i: Int) {
        guard brani.indices.contains(i) else { return }
        fermaRiproduzione()
        indice = i
        let b = brani[i]
        Task { await avvia(b) }
    }

    func playPausa() {
        switch fonte {
        case .intero:
            let p = ApplicationMusicPlayer.shared
            if suona { p.pause(); suona = false } else { Task { try? await p.play() } }
        case .anteprima:
            guard let p = lettore30 else { return }
            if suona {
                p.pause()
            } else {
                if tempo >= durata - 0.5 { p.seek(to: .zero) }
                p.play()
            }
        case .video:
            comandoVideo?(suona ? "pausa" : "play")
        case .nessuna:
            metti(indice)
        }
    }

    func avanti() { if !brani.isEmpty { metti((indice + 1) % brani.count) } }
    func indietro() { if !brani.isEmpty { metti((indice + brani.count - 1) % brani.count) } }

    /// Il lettore YouTube racconta dov'è arrivato.
    func statoVideo(tempo t: Double, durata d: Double, suona s: Bool) {
        guard fonte == .video else { return }
        tempo = t
        if d > 0 { durata = d }
        suona = s
    }

    /// Il lettore grande si è chiuso mentre c'era un video: il video si ferma (YouTube vuole che si veda).
    func videoChiuso(_ id: String) {
        guard fonte == .video, videoID == id else { return }      // solo se è ancora quel video
        comandoVideo = nil
        videoID = nil
        fonte = .nessuna
        suona = false
        tempo = 0
        durata = 0
    }

    // MARK: - Riproduzione

    private func avvia(_ b: Brano) async {
        if let id = b.appleID, await puoIntero(), await suonaIntero(id: id, brano: b) { return }
        guard indice == b.id else { return }
        if let u = b.anteprima {
            suonaAnteprima(u)
        } else if let v = b.video {
            fonte = .video
            videoID = v
            durata = b.secondiVideo ?? 0
            tempo = 0
        } else {
            fonte = .nessuna
        }
    }

    /// Abbonamento Apple Music: la prima volta l'iPhone chiede il permesso.
    private func puoIntero() async -> Bool {
        var stato = MusicAuthorization.currentStatus
        if stato == .notDetermined { stato = await MusicAuthorization.request() }
        guard stato == .authorized else { abbonato = false; return false }
        let ok = (try? await MusicSubscription.current)?.canPlayCatalogContent ?? false
        abbonato = ok
        return ok
    }

    private func suonaIntero(id: String, brano b: Brano) async -> Bool {
        do {
            let richiesta = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
            guard let song = try await richiesta.response().items.first, indice == b.id else { return false }
            let p = ApplicationMusicPlayer.shared
            p.queue = ApplicationMusicPlayer.Queue(for: [song])
            try await p.play()
            usatoApple = true
            fonte = .intero
            durata = song.duration ?? b.secondiApple ?? 0
            tempo = 0
            suona = true
            avviaOrologio()
            return true
        } catch {
            return false                    // MusicKit non attivo o brano non suonabile: si passa all'anteprima
        }
    }

    private func suonaAnteprima(_ u: URL) {
        let sessione = AVAudioSession.sharedInstance()
        try? sessione.setCategory(.playback, mode: .default)
        try? sessione.setActive(true)
        let p = AVPlayer(url: u)
        lettore30 = p
        p.play()
        fonte = .anteprima
        durata = 30
        tempo = 0
        suona = true
        avviaOrologio()
    }

    private func avviaOrologio() {
        orologio?.cancel()
        orologio = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.leggi()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func leggi() {
        switch fonte {
        case .intero:
            let p = ApplicationMusicPlayer.shared
            tempo = p.playbackTime
            suona = p.state.playbackStatus == .playing
        case .anteprima:
            guard let p = lettore30 else { return }
            let t = p.currentTime().seconds
            if t.isFinite { tempo = t }
            if let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 { durata = d }
            suona = p.timeControlStatus != .paused
        case .video, .nessuna:
            break
        }
    }

    private func fermaRiproduzione() {
        orologio?.cancel()
        orologio = nil
        if usatoApple {
            ApplicationMusicPlayer.shared.stop()
            usatoApple = false
        }
        lettore30?.pause()
        lettore30 = nil
        if fonte == .video { comandoVideo?("stop") }
        videoID = nil
        fonte = .nessuna
        suona = false
        tempo = 0
        durata = 0
    }

    // MARK: - Ricerche e abbinamenti

    /// "So What (Live)" -> "so what"
    nonisolated static func norma(_ s: String) -> String {
        var t = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        t = t.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func simili(_ a: String, _ b: String) -> Bool {
        guard a.count >= 3, b.count >= 3 else { return !a.isEmpty && a == b }
        return a == b || a.contains(b) || b.contains(a)
    }

    /// Video YouTube della scheda: a ogni brano quello col titolo che lo contiene.
    nonisolated static func abbinaVideo(_ lista: inout [Brano], videos: [ReleaseVideo]) {
        var utili: [VideoUtile] = []
        for v in videos {
            guard let id = youtubeID(v.uri ?? "") else { continue }
            utili.append(VideoUtile(id: id, titolo: norma(v.title ?? ""), secondi: v.duration.map { Double($0) }))
        }
        for i in lista.indices {
            let t = norma(lista[i].titolo)
            guard t.count >= 3, let v = utili.first(where: { $0.titolo.contains(t) }) else { continue }
            lista[i].video = v.id
            lista[i].secondiVideo = v.secondi
        }
    }

    struct VideoUtile { var id: String; var titolo: String; var secondi: Double? }

    nonisolated static func youtubeID(_ uri: String) -> String? {
        guard let c = URLComponents(string: uri), let host = c.host?.lowercased() else { return nil }
        if host.contains("youtu.be") { return c.path.split(separator: "/").first.map(String.init) }
        guard host.contains("youtube") else { return nil }
        if let v = c.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty { return v }
        let parti = c.path.split(separator: "/")
        if let i = parti.firstIndex(where: { $0 == "embed" || $0 == "shorts" }), i + 1 < parti.count { return String(parti[i + 1]) }
        return nil
    }

    /// I brani Apple abbinati a quelli di Discogs: per titolo, oppure in ordine se il numero è lo stesso.
    nonisolated static func abbinaApple(_ lista: inout [Brano], canzoni: [VoceApple]) {
        guard !canzoni.isEmpty else { return }
        let ordinate = canzoni.sorted { ($0.discNumber ?? 1, $0.trackNumber ?? 0) < ($1.discNumber ?? 1, $1.trackNumber ?? 0) }
        var usate = Set<Int>()
        for i in lista.indices {
            let t = norma(lista[i].titolo)
            if let k = ordinate.indices.first(where: { !usate.contains($0) && simili(norma(ordinate[$0].trackName ?? ""), t) }) {
                usate.insert(k)
                applica(&lista[i], ordinate[k])
            }
        }
        // stessa quantità di brani e quasi nessun titolo abbinato: si va in ordine
        if usate.count < lista.count / 2, ordinate.count == lista.count {
            for i in lista.indices { applica(&lista[i], ordinate[i]) }
        }
    }

    nonisolated private static func applica(_ b: inout Brano, _ c: VoceApple) {
        b.appleID = c.trackId.map(String.init)
        b.anteprima = c.previewUrl.flatMap(URL.init(string:))
        b.secondiApple = c.trackTimeMillis.map { Double($0) / 1000 }
    }

    /// Una voce della ricerca Apple (iTunes Search API: gratis, senza account).
    struct VoceApple: Decodable, Sendable {
        var wrapperType: String?
        var kind: String?
        var collectionId: Int?
        var collectionName: String?
        var artistName: String?
        var trackId: Int?
        var trackName: String?
        var previewUrl: String?
        var trackTimeMillis: Int?
        var trackNumber: Int?
        var discNumber: Int?
    }

    private struct RispostaApple: Decodable { var results: [VoceApple] }

    /// L'album su Apple: prima col codice a barre (esatto), poi per artista e titolo.
    nonisolated static func cercaSuApple(_ r: Release, artista: String) async -> [VoceApple] {
        let paese = (Locale.current.region?.identifier ?? "IT").lowercased()
        if let upc = r.barcode {
            let canzoni = await brani(query: ["upc": upc, "entity": "song", "country": paese, "limit": "200"], percorso: "lookup")
            if !canzoni.isEmpty { return canzoni }
        }
        let album = await chiedi(percorso: "search", query: ["term": "\(artista) \(r.title)", "entity": "album",
                                                            "country": paese, "limit": "10"])
        let titolo = norma(r.title), chi = norma(artista)
        guard let scelto = album.first(where: { a in
            simili(norma(a.collectionName ?? ""), titolo) && (chi.isEmpty || simili(norma(a.artistName ?? ""), chi))
        }), let id = scelto.collectionId else { return [] }
        return await brani(query: ["id": String(id), "entity": "song", "country": paese, "limit": "200"], percorso: "lookup")
    }

    nonisolated private static func brani(query: [String: String], percorso: String) async -> [VoceApple] {
        await chiedi(percorso: percorso, query: query).filter { $0.wrapperType == "track" && ($0.kind ?? "song") == "song" }
    }

    nonisolated private static func chiedi(percorso: String, query: [String: String]) async -> [VoceApple] {
        var c = URLComponents(string: "https://itunes.apple.com/\(percorso)")!
        c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
        guard let risposta = try? await URLSession.shared.data(for: req),
              let r = try? JSONDecoder().decode(RispostaApple.self, from: risposta.0) else { return [] }
        return r.results
    }
}
