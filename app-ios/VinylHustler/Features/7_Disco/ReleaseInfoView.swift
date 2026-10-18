import SwiftUI

/// SCHEDA DEL DISCO — tracce con l'ascolto di 30 secondi, artisti (biografia e link), video.
/// Si apre toccando la copertina nella fotocamera o "Tracce e artista" nella scheda annuncio.
/// Serve anche a controllare che la stampa sia quella giusta: stesse tracce, stessa durata.
struct ReleaseInfoView: View {
    let releaseID: Int

    @Environment(Seller.self) private var seller
    @Environment(\.dismiss) private var dismiss
    @State private var release: Release?
    @State private var previews: [String: URL] = [:]
    @State private var lookingUp = true
    @State private var error: String?
    @State private var player = AnteprimaPlayer()

    var body: some View {
        NavigationStack {
            ScrollView {
                if let release {
                    VStack(alignment: .leading, spacing: 18) {
                        header(release)
                        tracks(release)
                        artists(release)
                        videos(release)
                        Text("Data provided by Discogs. Anteprime audio da Apple Music.")
                            .font(.caption2).foregroundStyle(Theme.muted)
                    }
                    .padding()
                } else if let error {
                    Text(error).foregroundStyle(Theme.warn).padding(.top, 60)
                } else {
                    ProgressView("Leggo il disco…").tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .background(Theme.bg)
            .navigationTitle("Il disco")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fatto") { dismiss() }.tint(Theme.accent) } }
            .task { await load() }
            .onDisappear { player.stop() }
        }
        .preferredColorScheme(.dark)
    }

    private func load() async {
        do {
            let r = try await seller.client.release(releaseID)
            withAnimation(.snappy) { release = r }
            let titles = (r.tracklist ?? []).filter { !($0.position ?? "").isEmpty }.compactMap(\.title)
            let found = await Anteprime.find(artist: r.artist, album: r.title, tracks: titles)
            withAnimation(.snappy) { previews = found; lookingUp = false }
        } catch {
            self.error = "Non riesco a leggere il disco: \(error.localizedDescription)"
        }
    }

    // MARK: - Pezzi

    private func header(_ r: Release) -> some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: r.sortedImages.first?.uri150.flatMap(URL.init(string:))) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { Theme.panelHigh }
            }
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(r.title).font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.text)
                Text(r.artist).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                Text([r.labels?.first?.name, r.country, r.year.map { String($0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                if let url = URL(string: "https://www.discogs.com/release/\(r.id)") {
                    Link(destination: url) {
                        Label("Apri su Discogs", systemImage: "arrow.up.right.square").font(.system(size: 13, weight: .semibold))
                    }
                    .tint(Theme.accent)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func tracks(_ r: Release) -> some View {
        let list = r.tracklist ?? []
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                HUDLabel(title: "Tracce")
                Spacer()
                if lookingUp {
                    ProgressView().controlSize(.mini).tint(Theme.accent)
                } else if !previews.isEmpty {
                    Text("\(previews.count) DA ASCOLTARE").font(Theme.mono(11, .bold)).tracking(1).foregroundStyle(Theme.accent)
                }
            }
            .padding(.bottom, 8)
            if list.isEmpty {
                Text("Discogs non ha la lista delle tracce di questa stampa.").font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
            ForEach(Array(list.enumerated()), id: \.offset) { _, t in
                if (t.position ?? "").isEmpty {
                    Text((t.title ?? "").uppercased()).font(Theme.mono(11, .bold)).tracking(1).foregroundStyle(Theme.muted)
                        .padding(.top, 10).padding(.bottom, 4)
                } else {
                    trackRow(t)
                }
            }
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private func trackRow(_ t: Track) -> some View {
        let title = t.title ?? ""
        let url = previews[title]
        let on = player.playing == title
        return Button {
            guard let url else { return }
            Suoni.click()
            player.toggle(title, url: url)
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(t.position ?? "").font(Theme.mono(12, .bold)).foregroundStyle(Theme.muted).frame(width: 30, alignment: .leading)
                    Text(title).font(.system(size: 15, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.glow : Theme.text).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    if let d = t.duration, !d.isEmpty {
                        Text(d).font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    }
                    Image(systemName: on ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(url == nil ? Theme.panelHigh : (on ? Theme.glow : Theme.accent))
                        .symbolEffect(.pulse, isActive: on)
                }
                .padding(.vertical, 9)
                // la barra dell'estratto che scorre sotto la traccia che suona
                GeometryReader { geo in
                    Capsule().fill(Theme.glow).frame(width: geo.size.width * (on ? player.progress : 0), height: 2)
                        .animation(.linear(duration: 0.25), value: player.progress)
                }
                .frame(height: 2)
                .opacity(on ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .accessibilityLabel(url == nil ? title : (on ? "Ferma \(title)" : "Ascolta \(title)"))
    }

    @ViewBuilder
    private func artists(_ r: Release) -> some View {
        let people = (r.artists ?? []).filter { ($0.id ?? 0) > 0 && $0.name != "Various" }
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HUDLabel(title: people.count == 1 ? "Artista" : "Artisti")
                ForEach(people, id: \.self) { a in
                    NavigationLink {
                        ArtistView(artistID: a.id ?? 0, fallbackName: a.name)
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle").foregroundStyle(Theme.accent)
                            Text(a.name.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression))
                                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                            Spacer()
                            Text("Biografia e link").font(.system(size: 13)).foregroundStyle(Theme.muted)
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                        }
                        .padding(14)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func videos(_ r: Release) -> some View {
        let list = (r.videos ?? []).prefix(8)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HUDLabel(title: "Video")
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.offset) { i, v in
                        if let url = URL(string: v.uri) {
                            Link(destination: url) {
                                HStack(spacing: 10) {
                                    Image(systemName: "play.rectangle.fill").foregroundStyle(Theme.warn)
                                    Text(v.title ?? "Video").font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(1)
                                    Spacer()
                                    if let s = v.duration { Text(String(format: "%ld:%02ld", s / 60, s % 60)).font(Theme.mono(12)).foregroundStyle(Theme.muted) }
                                }
                                .padding(.vertical, 10)
                            }
                            if i < list.count - 1 { Divider().overlay(Theme.line) }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
        }
    }
}

/// PAGINA ARTISTA — foto, biografia, sito ufficiale, Wikipedia, Bandcamp… e una ricerca Google.
struct ArtistView: View {
    let artistID: Int
    let fallbackName: String

    @Environment(Seller.self) private var seller
    @State private var artist: ArtistInfo?
    @State private var expanded = false
    @State private var failed = false

    private var name: String {
        (artist?.name ?? fallbackName).replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    AsyncImage(url: artist?.images?.first?.uri150.flatMap(URL.init(string:))) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() } else {
                            ZStack { Theme.panelHigh; Image(systemName: "person.fill").foregroundStyle(Theme.muted) }
                        }
                    }
                    .frame(width: 84, height: 84)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Theme.accent.opacity(0.8), lineWidth: 1.5))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                        if let real = artist?.realname, !real.isEmpty, real != name {
                            Text(real).font(.system(size: 14)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                if let bio = artist?.cleanProfile, !bio.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HUDLabel(title: "Biografia")
                        Text(bio).font(.system(size: 15)).foregroundStyle(Theme.text)
                            .lineLimit(expanded ? nil : 6)
                        Button(expanded ? "Meno" : "Leggi tutto") { withAnimation(.snappy) { expanded.toggle() } }
                            .font(.system(size: 14, weight: .semibold)).tint(Theme.accent)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                } else if artist == nil && !failed {
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HUDLabel(title: "Link")
                    VStack(spacing: 0) {
                        ForEach(Array(links.enumerated()), id: \.offset) { _, item in
                            Link(destination: item.url) {
                                HStack(spacing: 10) {
                                    Image(systemName: item.icon).foregroundStyle(Theme.accent).frame(width: 22)
                                    Text(item.title).font(.system(size: 15)).foregroundStyle(Theme.text)
                                    Spacer()
                                    Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                                }
                                .padding(.vertical, 11)
                            }
                            Divider().overlay(Theme.line)
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                }
                Text("Data provided by Discogs.").font(.caption2).foregroundStyle(Theme.muted)
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { artist = try await seller.client.artist(artistID) } catch { failed = true }
        }
    }

    struct LinkItem {
        var title: String
        var url: URL
        var icon: String
    }

    /// I link dell'artista con un nome chiaro, poi Discogs e Google.
    private var links: [LinkItem] {
        var out: [LinkItem] = []
        for raw in artist?.urls ?? [] {
            let fixed = raw.hasPrefix("http") ? raw : "https://" + raw
            guard let u = URL(string: fixed), let host = u.host?.lowercased() else { continue }
            out.append(Self.label(host: host, url: u))
        }
        // prima Wikipedia e il sito ufficiale, poi il resto
        out.sort { Self.rank($0.title) < Self.rank($1.title) }
        if let u = URL(string: "https://www.discogs.com/artist/\(artistID)") { out.append(LinkItem(title: "Discogs", url: u, icon: "record.circle")) }
        var g = URLComponents(string: "https://www.google.com/search")!
        g.queryItems = [URLQueryItem(name: "q", value: "\(name) musicista")]
        if let u = g.url { out.append(LinkItem(title: "Cerca su Google", url: u, icon: "magnifyingglass")) }
        return out
    }

    private static func label(host: String, url: URL) -> LinkItem {
        let known: [(String, String, String)] = [
            ("wikipedia.org", "Wikipedia", "book"),
            ("bandcamp.com", "Bandcamp", "music.note"),
            ("soundcloud.com", "SoundCloud", "waveform"),
            ("instagram.com", "Instagram", "camera"),
            ("facebook.com", "Facebook", "person.2"),
            ("twitter.com", "X / Twitter", "bubble.left"),
            ("x.com", "X / Twitter", "bubble.left"),
            ("youtube.com", "YouTube", "play.rectangle"),
            ("spotify.com", "Spotify", "music.note.list"),
            ("apple.com", "Apple Music", "music.note"),
            ("myspace.com", "Myspace", "globe"),
            ("allmusic.com", "AllMusic", "music.mic"),
            ("musicbrainz.org", "MusicBrainz", "music.mic"),
            ("imdb.com", "IMDb", "film"),
        ]
        for (domain, title, icon) in known where host.hasSuffix(domain) {
            let lang = domain == "wikipedia.org" ? " (\(host.split(separator: ".").first.map(String.init)?.uppercased() ?? ""))" : ""
            return LinkItem(title: title + lang, url: url, icon: icon)
        }
        return LinkItem(title: "Sito ufficiale · \(host.replacingOccurrences(of: "www.", with: ""))", url: url, icon: "globe")
    }

    private static func rank(_ title: String) -> Int {
        if title.hasPrefix("Wikipedia (IT") { return 0 }
        if title.hasPrefix("Wikipedia") { return 1 }
        if title.hasPrefix("Sito ufficiale") { return 2 }
        return 3
    }
}
