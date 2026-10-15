import Foundation

/// Regole del prezzo (default identici a vendi.py; modificabili dalla Console).
struct PriceRules: Codable, Equatable {
    var zeroCopiesPremium: Decimal = 100        // nessuna copia in vendita: +100%
    var fewCopies = 2                           // 1-2 copie: "poche"
    var fewCopiesPremium: Decimal = 50
    var someCopies = 5                          // 3-5 copie: "alcune"
    var someCopiesPremium: Decimal = 25
    var demandSteps: [DemandStep] = [.init(above: 1, premium: 10), .init(above: 2, premium: 25), .init(above: 4, premium: 50)]
    var slowLaneBelow: Double = 1.0             // want/have sotto: corsia LENTA
    var hotLaneAbove: Double = 2.0              // want/have sopra: corsia CALDA
    var slowDiscount: Decimal = 5               // corsia lenta: % sotto la concorrenza
    var lanesOff = false
    var step: Decimal = 2.5                     // griglia dei prezzi
    var minimum: Decimal = 2.5
    var reviewAbove: Double = 100               // sopra questo prezzo un disco senza codice va controllato
    var collectorThreshold: Double = 50         // --soglia-prezzo
    var collectorScore = 4                      // --soglia-collezionistico

    struct DemandStep: Codable, Equatable {
        var above: Double
        var premium: Decimal
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

/// Porta esatta di compute_price / standard_price / to_grid / collector_score di vendi.py.
/// I test in VinylHustlerTests confrontano i risultati con quelli dello script Python.
enum PriceEngine {
    static func compute(suggested: Double, market: MarketData?, grade: Grade, currency: String,
                        rules: PriceRules, competitors: (copies: Int, lowest: Double?)? = nil) -> (price: Decimal, calculation: String) {
        guard let market, !rules.lanesOff else { return standard(suggested, market, grade, currency, rules) }
        let ratio = market.ratio
        let comp = competitors ?? competition(market, myPrices: [], currency: currency)
        let prefix: String
        if ratio < rules.slowLaneBelow {
            let lane = "corsia LENTA (want/have \(fmt(ratio)) < \(rules.slowLaneBelow))"
            if comp.copies > 0, let low = comp.lowest, low > 0 {
                let lowD = dec(low)
                let target = round2(lowD * (1 - rules.slowDiscount / 100))
                let down = gridFloor(target, rules.step)
                let floor = toGrid(dec(suggested), rules.step, rules.minimum)
                let text = "\(lane): \(rules.slowDiscount)% sotto concorrenza \(fmt(lowD)) = \(fmt(target)) → griglia per difetto \(fmt(down))"
                if down < floor {
                    return (floor, "\(text); sotto il suggerito \(grade.discogs) \(fmt(suggested)): prezzo = suggerito sulla griglia \(fmt(floor)) \(currency)")
                }
                return (down, "\(text) \(currency)")
            }
            prefix = "\(lane): nessun concorrente da sottoquotare, regola NORMALE"
        } else if ratio > rules.hotLaneAbove {
            prefix = "corsia CALDA (want/have \(fmt(ratio)) > \(rules.hotLaneAbove)): premi a scalini"
        } else {
            prefix = "corsia NORMALE (want/have \(fmt(ratio)) tra \(rules.slowLaneBelow) e \(rules.hotLaneAbove))"
        }
        let (price, calc) = standard(suggested, market, grade, currency, rules)
        return (price, "\(prefix); \(calc)")
    }

    /// Regola standard: base = più basso in vendita (mai sotto il suggerito) + premi, poi griglia per eccesso.
    static func standard(_ suggested: Double, _ market: MarketData?, _ grade: Grade, _ currency: String,
                         _ rules: PriceRules) -> (Decimal, String) {
        var steps = ["suggerito \(grade.discogs) \(fmt(suggested))"]
        func finish(_ raw: Decimal) -> (Decimal, String) {
            let price = toGrid(raw, rules.step, rules.minimum)
            steps[steps.count - 1] += " → arrotondato a griglia \(fmt(rules.step)) = \(fmt(price)) \(currency)"
            return (price, steps.joined(separator: "; "))
        }
        guard let market else {
            steps = ["dati del marketplace non disponibili: prezzo = suggerito \(fmt(suggested)) \(currency)"]
            return finish(dec(suggested))
        }
        let copies = market.numForSale
        let lowest = market.lowestCurrency == currency ? market.lowestPrice : nil
        let base: Double
        if copies == 0 || lowest == nil || lowest == 0 {
            base = suggested
            steps.append(copies == 0 ? "nessun prezzo in vendita" : "prezzo più basso non disponibile")
            steps.append("base = suggerito \(fmt(base))")
        } else {
            steps.append("più basso in vendita \(fmt(lowest!))")
            base = max(lowest!, suggested)
            steps.append("base = \(lowest! >= suggested ? "più basso in vendita" : "suggerito (soglia minima)") \(fmt(base))")
        }
        var total: Decimal = 0
        if copies == 0 {
            total += rules.zeroCopiesPremium; steps.append("0 copie in vendita +\(rules.zeroCopiesPremium)%")
        } else if copies <= rules.fewCopies {
            total += rules.fewCopiesPremium; steps.append("\(copies) copie in vendita +\(rules.fewCopiesPremium)%")
        } else if copies <= rules.someCopies {
            total += rules.someCopiesPremium; steps.append("\(copies) copie in vendita +\(rules.someCopiesPremium)%")
        } else {
            steps.append("\(copies) copie in vendita: nessun premio scarsità")
        }
        let ratioText = "want/have \(market.want)/\(market.have)" + (market.have > 0 ? " = \(fmt(market.ratio))" : "")
        if let step = rules.demandSteps.sorted(by: { $0.above < $1.above }).last(where: { market.ratio > $0.above }) {
            total += step.premium; steps.append("\(ratioText) > \(step.above) +\(step.premium)%")
        } else {
            steps.append("\(ratioText): nessun premio richiesta")
        }
        let raw = round2(dec(base) * (1 + total / 100))
        steps.append("prezzo = \(fmt(base)) × (1 + \(total)%) = \(fmt(raw)) \(currency)")
        return finish(raw)
    }

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
