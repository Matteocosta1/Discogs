import Foundation

/// Configurazione dell'app. I valori segreti NON stanno nel codice: arrivano da `Secrets.xcconfig`
/// (fuori da Git) attraverso l'Info.plist. Vedi la guida, capitolo "Chiavi e secret".
enum AppConfig {
    /// Discogs chiede un User-Agent che identifichi l'app.
    static let userAgent = "VinylHustler/0.1"

    /// Schema dell'URL di ritorno dal login Discogs (Info.plist > URL Types).
    static let oauthCallbackScheme = "vinylhustler"
    static let oauthCallbackURL = "vinylhustler://oauth"

    // App Discogs (https://www.discogs.com/settings/developers).
    static var discogsConsumerKey: String { info("DISCOGS_CONSUMER_KEY") }
    static var discogsConsumerSecret: String { info("DISCOGS_CONSUMER_SECRET") }

    /// Solo uso interno: token personale messo in Secrets.xcconfig (vuoto nelle versioni da distribuire).
    /// V56: nelle build Release è sempre vuoto (doppia sicurezza, oltre a Base.xcconfig).
    static var discogsPersonalToken: String {
        #if DEBUG
        return info("DISCOGS_PERSONAL_TOKEN")
        #else
        return ""
        #endif
    }

    // Supabase: solo URL e chiave pubblica (anon). La chiave di Anthropic sta SOLO sul server.
    static var supabaseURL: URL? { URL(string: info("SUPABASE_URL")) }
    static var supabaseAnonKey: String { info("SUPABASE_ANON_KEY") }

    private static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}
