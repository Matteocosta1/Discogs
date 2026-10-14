import Foundation

/// Configurazione dell'app. I valori segreti NON stanno nel codice: arrivano da `Secrets.xcconfig`
/// (fuori da Git) attraverso l'Info.plist. Vedi la guida, capitolo "Chiavi e secret".
enum AppConfig {
    /// Discogs chiede un User-Agent che identifichi l'app.
    static let userAgent = "DiscosizerSeller/0.1 +https://discosizer.it"

    /// Schema dell'URL di ritorno dal login Discogs (Info.plist > URL Types).
    static let oauthCallbackScheme = "discosizer"
    static let oauthCallbackURL = "discosizer://oauth"

    // App Discogs (https://www.discogs.com/settings/developers).
    static var discogsConsumerKey: String { info("DISCOGS_CONSUMER_KEY") }
    static var discogsConsumerSecret: String { info("DISCOGS_CONSUMER_SECRET") }

    // Supabase: solo URL e chiave pubblica (anon). La chiave di Anthropic sta SOLO sul server.
    static var supabaseURL: URL? { URL(string: info("SUPABASE_URL")) }
    static var supabaseAnonKey: String { info("SUPABASE_ANON_KEY") }

    private static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}
