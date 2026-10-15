import AuthenticationServices
import CryptoKit
import Foundation
import Supabase

/// Collegamento a Supabase: login dell'utente dell'app (Sign in with Apple) e funzioni sul server.
/// La chiave di Anthropic NON è mai nell'app: la usa solo la funzione `ai-cover` sul server.
/// Senza accesso l'app funziona lo stesso: barcode e scritte lette sul telefono (niente AI).
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

    /// SHA-256 esadecimale del nonce (Apple vuole quello cifrato, Supabase quello in chiaro).
    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func signOut() async {
        try? await client?.auth.signOut()
    }
}

/// Un disco visto dall'AI nelle foto (schema SCAN della funzione ai-cover).
struct AIRecord: Codable {
    var artist: String
    var title: String
    var label: String
    var catno: String
    var barcode: String
    var year: String
    var images: [Int]           // in quali foto si vede (numerate da 1)

    /// "Miles Davis - Kind Of Blue"
    var line: String { [artist, title].filter { !$0.isEmpty }.joined(separator: " - ") }
}

struct AIScan: Codable {
    var records: [AIRecord]
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
    /// Tutti i dischi che si vedono nelle foto (o nei fotogrammi di un video).
    func scan(photos: [Data]) async throws -> AIScan {
        try await call(["task": "scan", "photos": photos.map { $0.base64EncodedString() }])
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
