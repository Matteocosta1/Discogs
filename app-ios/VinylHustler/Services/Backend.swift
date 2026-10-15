import AuthenticationServices
import Foundation
import Supabase

/// Collegamento a Supabase: login dell'utente dell'app (Sign in with Apple) e funzioni sul server.
/// La chiave di Anthropic NON è mai nell'app: la usa solo la funzione `ai-cover` sul server.
/// Senza Supabase configurato l'app funziona lo stesso in modalità Super veloce (niente AI).
final class Backend: @unchecked Sendable {
    static let shared = Backend()
    let client: SupabaseClient?

    private init() {
        if let url = AppConfig.supabaseURL, !AppConfig.supabaseAnonKey.isEmpty {
            client = SupabaseClient(supabaseURL: url, supabaseKey: AppConfig.supabaseAnonKey)
        } else {
            client = nil
        }
    }

    var isConfigured: Bool { client != nil }

    func accessToken() async -> String? {
        try? await client?.auth.session.accessToken
    }

    /// Da chiamare con il risultato di SignInWithAppleButton (idToken + nonce non cifrato).
    func signInWithApple(idToken: String, nonce: String) async throws {
        guard let client else { return }
        try await client.auth.signInWithIdToken(credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
    }

    func signOut() async {
        try? await client?.auth.signOut()
    }
}

/// Risposta dell'AI al confronto delle copertine (stesso schema di AI_COVER_SCHEMA).
struct AICoverChoice: Codable {
    var releaseId: Int
    var confidence: String      // high / medium / low
    var reason: String
    var cost: Double?           // euro, calcolati dal server
}

/// Cosa l'AI legge sulla foto (stesso schema di AI_READ_SCHEMA).
struct AIRead: Codable {
    var artist: String
    var title: String
    var label: String
    var catno: String
    var barcode: String
    var compilation: Bool
    var recognizedArtist: String
    var recognizedTitle: String
    var cost: Double?
}

enum AIError: LocalizedError {
    case notConfigured, notSignedIn, server(String), budget
    var errorDescription: String? {
        switch self {
        case .notConfigured: "AI non configurata (Supabase)"
        case .notSignedIn: "Accedi all'app per usare l'AI"
        case .server(let m): "AI: \(m)"
        case .budget: "Tetto di spesa AI del mese raggiunto"
        }
    }
}

/// Chiamate alla funzione `ai-cover` su Supabase.
struct AIService {
    struct CandidateImages: Encodable {
        var releaseId: Int
        var title: String
        var images: [String]            // JPEG in base64, lato lungo 768 px
    }

    func matchCovers(photos: [Data], candidates: [CandidateImages]) async throws -> AICoverChoice {
        try await call(["task": "match", "photos": photos.map { $0.base64EncodedString() }, "candidates": candidates])
    }

    func read(photos: [Data]) async throws -> AIRead {
        try await call(["task": "read", "photos": photos.map { $0.base64EncodedString() }])
    }

    private func call<T: Decodable>(_ payload: [String: any Encodable]) async throws -> T {
        guard let base = AppConfig.supabaseURL else { throw AIError.notConfigured }
        guard let token = await Backend.shared.accessToken() else { throw AIError.notSignedIn }
        var req = URLRequest(url: base.appendingPathComponent("functions/v1/ai-cover"), timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try encoder.encode(AnyEncodableDict(payload))
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 402 { throw AIError.budget }
        guard status == 200 else { throw AIError.server(String(decoding: data, as: UTF8.self)) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}

/// Dizionario di valori Encodable diversi (per il corpo della richiesta).
private struct AnyEncodableDict: Encodable {
    let values: [String: any Encodable]
    init(_ values: [String: any Encodable]) { self.values = values }

    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for (k, v) in values { try c.encode(v, forKey: Key(stringValue: k)) }
    }
}
