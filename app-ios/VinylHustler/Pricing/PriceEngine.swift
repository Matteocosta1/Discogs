import Foundation

/// V76 · Le regole del prezzo (Settings › Prezzi). Si parte dalla copia più economica in vendita e si aggiunge
/// il ricarico della Richiesta (quanti want ha il disco); se nessuno lo vende si parte dal suggerito di Discogs,
/// con il ricarico più alto. Mai sotto il suggerito; arrotondato per difetto alla griglia, mai sotto il minimo.
struct PriceRules: Codable, Equatable {
    /// I want fino a cui vale ogni livello: Bassa 0-50, Media 51-200, Alta 201-1.000, Altissima 1.001-5.000.
    var soglie: [Int] = [50, 200, 1000]
    /// Il primo e l'ultimo numero della tabella (0 e 5.000): chiudono la tabella; sotto il primo conta come Bassa,
    /// oltre l'ultimo come Altissima.
    var wantDa = 0
    var wantFino = 5000
    /// Ricarico (%) sulla più economica, per Bassa, Media, Alta, Altissima.
    var ricarico: [Decimal] = [10, 25, 50, 100]
    /// Ricarico (%) sul suggerito quando nessuno vende il disco.
    var ricaricoUnico: [Decimal] = [100, 150, 200, 300]
    var maiSottoSuggerito = true
    var step: Decimal = 0.5                     // griglia dei prezzi
    var minimum: Decimal = 2.5
    var reviewAbove: Double = 100               // sopra questo prezzo un disco senza codice va controllato
    var collectorThreshold: Double = 50         // --soglia-prezzo
    var collectorScore = 4                      // --soglia-collezionistico

    static let livelli = ["Bassa", "Media", "Alta", "Altissima"]

    init() {}

    /// Ripristina: Richiesta e «Mai sotto il suggerito» tornano ai valori di partenza; griglia e minimo restano.
    func ripristinata() -> PriceRules {
        var r = self
        let d = PriceRules()
        r.soglie = d.soglie
        r.wantDa = d.wantDa
        r.wantFino = d.wantFino
        r.ricarico = d.ricarico
        r.ricaricoUnico = d.ricaricoUnico
        r.maiSottoSuggerito = d.maiSottoSuggerito
        return r
    }

    /// Il livello di Richiesta (0 Bassa … 3 Altissima) per un numero di want.
    func livello(_ want: Int) -> Int {
        want <= soglie[0] ? 0 : want <= soglie[1] ? 1 : want <= soglie[2] ? 2 : 3
    }

    /// I want di ogni livello, scritti: "0-50", "51-200", "201-1.000", "1.001-5.000".
    func fascia(_ k: Int) -> String {
        switch k {
        case 0: return "\(Self.intero(wantDa))-\(Self.intero(soglie[0]))"
        case 1: return "\(Self.intero(soglie[0] + 1))-\(Self.intero(soglie[1]))"
        case 2: return "\(Self.intero(soglie[1] + 1))-\(Self.intero(soglie[2]))"
        default: return "\(Self.intero(soglie[2] + 1))-\(Self.intero(wantFino))"
        }
    }

    static func intero(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "."
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    // Le regole salvate prima della V76 si leggono lo stesso: si tengono griglia, minimo e collezionismo,
    // la Richiesta parte dai valori di partenza (scelta di Alessandro, 12/11/2026).
    private enum CodingKeys: String, CodingKey {
        case soglie, wantDa, wantFino, ricarico, ricaricoUnico, maiSottoSuggerito, step, minimum, reviewAbove, collectorThreshold, collectorScore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PriceRules()
        let s = try c.decodeIfPresent([Int].self, forKey: .soglie) ?? d.soglie
        soglie = s.count == 3 ? s : d.soglie
        let da = try c.decodeIfPresent(Int.self, forKey: .wantDa) ?? d.wantDa
        let fino = try c.decodeIfPresent(Int.self, forKey: .wantFino) ?? d.wantFino
        wantDa = max(0, min(da, soglie[0] - 1))
        wantFino = max(fino, soglie[2] + 1)
        let r = try c.decodeIfPresent([Decimal].self, forKey: .ricarico) ?? d.ricarico
        ricarico = r.count == 4 ? r : d.ricarico
        let u = try c.decodeIfPresent([Decimal].self, forKey: .ricaricoUnico) ?? d.ricaricoUnico
        ricaricoUnico = u.count == 4 ? u : d.ricaricoUnico
        maiSottoSuggerito = try c.decodeIfPresent(Bool.self, forKey: .maiSottoSuggerito) ?? d.maiSottoSuggerito
        step = try c.decodeIfPresent(Decimal.self, forKey: .step) ?? d.step
        minimum = try c.decodeIfPresent(Decimal.self, forKey: .minimum) ?? d.minimum
        reviewAbove = try c.decodeIfPresent(Double.self, forKey: .reviewAbove) ?? d.reviewAbove
        collectorThreshold = try c.decodeIfPresent(Double.self, forKey: .collectorThreshold) ?? d.collectorThreshold
        collectorScore = try c.decodeIfPresent(Int.self, forKey: .collectorScore) ?? d.collectorScore
    }
}

/// Dati di mercato di una release (get_collector_data dello script).
struct MarketData: Equatable {
    var want: Int
    var have: Int
    var numForSale: Int
    var lowestPrice: Double?
    var lowestCurrency: String?
    var formats: String = ""

    var ratio: Double { have > 0 ? Double(want) / Double(have) : (want > 0 ? .infinity : 0) }
}

/// V76 · Il conto del prezzo (Settings › Prezzi). Il conto scritto è una riga sola, quella che si legge sotto
/// il prezzo di ogni disco: «più economica 32,00 € · richiesta alta (640 want) → +50% = 48,00 €».
enum PriceEngine {
    static func compute(suggested: Double, market: MarketData?, grade: Grade, currency: String,
                        rules: PriceRules) -> (price: Decimal, calculation: String) {
        let sim = simbolo(currency)
        let sug = dec(suggested)
        guard let market else {
            let p = toGrid(sug, rules.step, rules.minimum)
            return (p, "dati di Discogs non disponibili: suggerito \(fmt(sug)) \(sim) = \(fmt(p)) \(sim)")
        }
        let copie = market.numForSale
        let piuBasso: Decimal? = {
            guard copie > 0, market.lowestCurrency == currency, let l = market.lowestPrice, l > 0 else { return nil }
            return dec(l)
        }()
        let liv = rules.livello(market.want)
        let ricarico = copie == 0 ? rules.ricaricoUnico[liv] : rules.ricarico[liv]
        let base = piuBasso ?? sug
        let partenza: String
        if let l = piuBasso {
            partenza = "più economica \(fmt(l)) \(sim)"
        } else if copie == 0 {
            partenza = "nessuno in vendita, suggerito \(fmt(sug)) \(sim)"
        } else {
            partenza = "più economica non disponibile, suggerito \(fmt(sug)) \(sim)"
        }
        let grezzo = round2(base * (1 + ricarico / 100))
        var prezzo = max(gridFloor(grezzo, rules.step), round2(rules.minimum))
        var fine = "\(fmt(prezzo)) \(sim)"
        if rules.maiSottoSuggerito, prezzo < sug {
            prezzo = toGrid(sug, rules.step, rules.minimum)
            fine = "\(fmt(grezzo)) \(sim), sotto il suggerito: \(fmt(prezzo)) \(sim)"
        }
        let richiesta = "richiesta \(PriceRules.livelli[liv].lowercased()) (\(PriceRules.intero(market.want)) want)"
        return (prezzo, "\(partenza) · \(richiesta) → \(pct(ricarico)) = \(fine)")
    }

    /// "+25%", "−5%", "0%".
    static func pct(_ x: Decimal) -> String {
        let v = NSDecimalNumber(decimal: x).doubleValue
        let n = String(format: v.rounded() == v ? "%.0f" : "%.1f", abs(v)).replacingOccurrences(of: ".", with: ",")
        return (v > 0 ? "+" : v < 0 ? "−" : "") + n + "%"
    }

    static func simbolo(_ currency: String) -> String { currency == "EUR" ? "€" : currency }

    /// Copie e prezzo più basso della concorrenza, senza i miei annunci (competition dello script).
    static func competition(_ m: MarketData, myPrices: [Double], currency: String) -> (copies: Int, lowest: Double?) {
        let lowest = m.lowestCurrency == currency ? m.lowestPrice : nil
        let others = max(m.numForSale - myPrices.count, 0)
        let maybeMe = lowest != nil && !myPrices.isEmpty && lowest! >= (myPrices.min()! - 0.005)
        return (others, maybeMe ? nil : lowest)
    }

    // MARK: - Collezionismo (dischi da far controllare prima di vendere)

    static let specialFeatures: [(name: String, pattern: String, points: Int)] = [
        ("Test Pressing", #"\btest pressing\b"#, 3),
        ("Numbered", #"\bnumbered\b"#, 2),
        ("Limited Edition", #"\blimited edition\b"#, 1),
        ("Promo", #"\b(promo|white label)\b"#, 1),
        ("First Press", #"\b(first|1st) press(ing)?\b"#, 1),
        ("Vinile colorato", #"\b(colou?red|red|blue|green|yellow|white|clear|transparent|orange|purple|pink|gold|silver|grey|gray|brown|marbled?|splatter|swirl|translucent|smoke|violet)\b"#, 1),
    ]

    static func collectorScore(_ m: MarketData, suggested: Double, rules: PriceRules) -> (score: Int, reasons: [String]) {
        var score = 0
        var reasons: [String] = []
        if m.want >= 20, m.have > 0 {
            let r = m.ratio
            let p = r >= 3 ? 3 : r >= 1.5 ? 2 : r >= 0.8 ? 1 : 0
            if p > 0 { score += p; reasons.append("want/have \(m.want)/\(m.have) (+\(p))") }
        }
        if m.want >= 20 {
            let p = m.numForSale == 0 ? 2 : m.numForSale <= 3 ? 1 : 0
            if p > 0 { score += p; reasons.append("\(m.numForSale) copie in vendita (+\(p))") }
        }
        if let low = m.lowestPrice, low >= rules.collectorThreshold { score += 1; reasons.append("più basso \(fmt(low)) (+1)") }
        let text = m.formats.lowercased()
        for f in specialFeatures {
            let target = f.name == "Vinile colorato" ? text.replacingOccurrences(of: "white label", with: "") : text
            if target.range(of: f.pattern, options: .regularExpression) != nil { score += f.points; reasons.append("\(f.name) (+\(f.points))") }
        }
        if suggested >= rules.collectorThreshold { score += 2; reasons.append("suggerito \(fmt(suggested)) (+2)") }
        return (score, reasons)
    }

    // MARK: - Griglia e arrotondamenti (in Decimal, sui centesimi, come lo script)

    static func dec(_ x: Double) -> Decimal { Decimal(string: String(format: "%.6f", x)) ?? Decimal(x) }

    static func round2(_ x: Decimal, _ mode: NSDecimalNumber.RoundingMode = .plain) -> Decimal {
        var v = x, out = Decimal()
        NSDecimalRound(&out, &v, 2, mode)
        return out
    }

    /// Per eccesso al gradino della griglia, mai sotto il minimo (to_grid).
    static func toGrid(_ price: Decimal, _ step: Decimal, _ minimum: Decimal) -> Decimal {
        let cents = max(round2(price), round2(minimum))
        var steps = cents / step, up = Decimal()
        NSDecimalRound(&up, &steps, 0, .up)
        return round2(up * step)
    }

    /// Per difetto al gradino della griglia (solo corsia lenta).
    static func gridFloor(_ price: Decimal, _ step: Decimal) -> Decimal {
        var steps = round2(price) / step, down = Decimal()
        NSDecimalRound(&down, &steps, 0, .down)
        return round2(down * step)
    }

    static func fmt(_ x: Double) -> String { String(format: "%.2f", x).replacingOccurrences(of: ".", with: ",") }
    static func fmt(_ x: Decimal) -> String { fmt(NSDecimalNumber(decimal: x).doubleValue) }
}
