import Foundation
import UIKit

/// La memoria condivisa dei dischi (funzione `memoria` su Supabase): ogni disco confermato da un utente
/// (Vendi o Bozza) insegna all'app. La volta dopo, a chiunque, lo stesso disco si riconosce subito e gratis.
/// Si salva solo testo: cosa ha letto l'AI, l'impronta della foto (64 bit), la release giusta. Niente foto.
enum Memoria {
    /// Un disco ricordato.
    struct Ricordo: Decodable {
        var releaseId: Int
        var title: String?
        var coverUrl: String?
        var confirmations: Int?

        var candidate: Candidate { Candidate(id: releaseId, title: title ?? "Release \(releaseId)", coverURL: coverUrl) }
    }

    struct Risposta: Decodable {
        var photo: Ricordo?
        var reads: [String: Ricordo]?
    }

    /// Cerca nella memoria: per impronta della foto e/o per quello che ha letto l'AI.
    static func cerca(impronta: String?, letture: [String] = []) async -> Risposta? {
        guard impronta != nil || !letture.isEmpty else { return nil }
        var body: [String: Any] = ["task": "lookup", "reads": letture]
        if let impronta { body["dhash"] = impronta }
        guard let data = await chiama(body) else { return nil }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try? d.decode(Risposta.self, from: data)
    }

    /// Insegna: questo disco (impronta / lettura) è questa release.
    static func impara(impronta: String?, lettura: String?, release: Int, titolo: String, copertina: String?) async {
        var body: [String: Any] = ["task": "learn", "release_id": release, "title": titolo]
        if let impronta { body["dhash"] = impronta }
        if let lettura, !lettura.isEmpty { body["read"] = lettura }
        if let copertina { body["cover"] = copertina }
        _ = await chiama(body)
    }

    private static func chiama(_ body: [String: Any]) async -> Data? {
        guard let base = AppConfig.supabaseURL, let token = await Backend.shared.accessToken() else { return nil }
        var req = URLRequest(url: base.appendingPathComponent("functions/v1/memoria"), timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return result.0
    }

    /// Impronta della foto (dHash, 64 bit, 16 cifre esadecimali). Si guarda il quadrato centrale (dove sta
    /// la copertina), in bianco e nero 9×8: due foto dello stesso disco danno impronte quasi uguali.
    static func impronta(_ image: UIImage) -> String? {
        guard let cg = image.normalizedCGImage(maxSide: 512) else { return nil }
        let side = Int(Double(min(cg.width, cg.height)) * 0.8)
        let rect = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
        guard let square = cg.cropping(to: rect) else { return nil }
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(square, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var hash: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                hash <<= 1
                if pixels[y * w + x] > pixels[y * w + x + 1] { hash |= 1 }
            }
        }
        // copertine quasi tinta unita (tutta nera, tutta bianca) danno impronte troppo simili tra loro: meglio non usarle
        guard (12...52).contains(hash.nonzeroBitCount) else { return nil }
        return String(format: "%016llx", hash)
    }
}
