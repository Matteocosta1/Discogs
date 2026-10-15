import AuthenticationServices
import Foundation
import Security
import UIKit

/// Credenziali Discogs dell'utente.
/// - personalToken: il token personale (come lo script). Va bene per l'uso interno.
/// - oauth: login "Accedi con Discogs" per i clienti dell'app (OAuth 1.0a, firma PLAINTEXT su HTTPS).
///
/// IMPORTANTE: Discogs limita le richieste PER INDIRIZZO IP (60 al minuto). Per questo le chiamate partono
/// dal telefono di ogni utente e non da un server comune: con un server tutti i clienti dividerebbero gli
/// stessi 60 al minuto. Di conseguenza il consumer secret dell'app deve stare nell'app (vedi la guida).
enum DiscogsCredentials: Codable, Equatable {
    case personalToken(String)
    case oauth(token: String, secret: String)

    func authorizationHeader() -> String {
        switch self {
        case .personalToken(let token):
            return "Discogs token=\(token)"
        case .oauth(let token, let secret):
            return OAuth1.header([
                "oauth_token": token,
                "oauth_signature": "\(AppConfig.discogsConsumerSecret)&\(secret)",
            ])
        }
    }
}

enum OAuth1 {
    static func header(_ extra: [String: String]) -> String {
        var params = [
            "oauth_consumer_key": AppConfig.discogsConsumerKey,
            "oauth_nonce": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            "oauth_signature_method": "PLAINTEXT",
            "oauth_timestamp": String(Int(Date().timeIntervalSince1970)),
            "oauth_version": "1.0",
        ]
        params.merge(extra) { _, new in new }
        let parts = params.sorted { $0.key < $1.key }.map { "\($0.key)=\"\(encode($0.value))\"" }
        return "OAuth " + parts.joined(separator: ", ")
    }

    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func parseForm(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        for pair in String(decoding: data, as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        return out
    }
}

/// "Accedi con Discogs": request token -> pagina di autorizzazione Discogs -> access token.
@MainActor
final class DiscogsLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var authSession: ASWebAuthenticationSession?
    enum LoginError: LocalizedError {
        case missingAppKeys, refused(String), cancelled
        var errorDescription: String? {
            switch self {
            case .missingAppKeys: "Mancano DISCOGS_CONSUMER_KEY / SECRET in Secrets.xcconfig"
            case .refused(let m): "Discogs ha rifiutato il login: \(m)"
            case .cancelled: "Login annullato"
            }
        }
    }

    func login() async throws -> DiscogsCredentials {
        guard !AppConfig.discogsConsumerKey.isEmpty, !AppConfig.discogsConsumerSecret.isEmpty else {
            throw LoginError.missingAppKeys
        }
        // 1. request token
        var req = URLRequest(url: URL(string: "https://api.discogs.com/oauth/request_token")!)
        req.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(OAuth1.header(["oauth_signature": "\(AppConfig.discogsConsumerSecret)&",
                                    "oauth_callback": AppConfig.oauthCallbackURL]),
                     forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let temp = OAuth1.parseForm(data)
        guard let token = temp["oauth_token"], let tokenSecret = temp["oauth_token_secret"] else {
            throw LoginError.refused(String(decoding: data, as: UTF8.self))
        }
        // 2. l'utente autorizza l'app sul sito Discogs
        let authURL = URL(string: "https://discogs.com/oauth/authorize?oauth_token=\(token)")!
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: AppConfig.oauthCallbackScheme) { url, error in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? LoginError.cancelled) }
            }
            session.presentationContextProvider = self
            authSession = session
            if !session.start() { cont.resume(throwing: LoginError.cancelled) }
        }
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let verifier = query.first(where: { $0.name == "oauth_verifier" })?.value else { throw LoginError.cancelled }
        // 3. access token
        var acc = URLRequest(url: URL(string: "https://api.discogs.com/oauth/access_token")!)
        acc.httpMethod = "POST"
        acc.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
        acc.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        acc.setValue(OAuth1.header(["oauth_token": token, "oauth_verifier": verifier,
                                    "oauth_signature": "\(AppConfig.discogsConsumerSecret)&\(tokenSecret)"]),
                     forHTTPHeaderField: "Authorization")
        let (accData, _) = try await URLSession.shared.data(for: acc)
        let final = OAuth1.parseForm(accData)
        guard let t = final["oauth_token"], let s = final["oauth_token_secret"] else {
            throw LoginError.refused(String(decoding: accData, as: UTF8.self))
        }
        return .oauth(token: t, secret: s)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}

/// Le credenziali si salvano nel Portachiavi (Keychain), mai in chiaro.
enum CredentialStore {
    private static let account = "discogs-credentials"

    static func save(_ credentials: DiscogsCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        delete()
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: account, kSecValueData: data,
                                     kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load() -> DiscogsCredentials? {
        var item: CFTypeRef?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: account, kSecReturnData: true]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(DiscogsCredentials.self, from: data)
    }

    static func delete() {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
    }
}
