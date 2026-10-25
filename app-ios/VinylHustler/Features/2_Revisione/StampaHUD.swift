import SwiftUI

// V60 — le animazioni delle liste (Bozze e Magazzino), come nel mock-up approvato.
// Tutto guidato da TimelineView: niente animazioni infinite, la pagina non si muove da sola.

/// La riga che si «stampa»: si scopre dall'alto verso il basso dietro una riga verde (p3, p8).
/// `da` = quando parte la stampa della lista (nil = riga già stampata, nessun effetto).
struct StampaRiga: ViewModifier {
    let da: Date?
    var ritardo: Double = 0
    var durata: Double = 0.32

    @ViewBuilder
    func body(content: Content) -> some View {
        if let da {
            let fine = ritardo + durata + 0.05
            TimelineView(.animation(minimumInterval: 1 / 60, paused: Date().timeIntervalSince(da) > fine)) { ctx in
                let passato = max(ctx.date.timeIntervalSince(da), Date().timeIntervalSince(da))
                let f = morbido((passato - ritardo) / durata)
                content
                    .mask(alignment: .top) {
                        GeometryReader { g in
                            Rectangle().frame(width: g.size.width, height: g.size.height * CGFloat(f))
                        }
                    }
                    .overlay(alignment: .top) {
                        GeometryReader { g in
                            if f > 0 && f < 1 {
                                Rectangle().fill(Theme.glow)
                                    .frame(width: g.size.width, height: 2)
                                    .shadow(color: Theme.glow, radius: 4)
                                    .offset(y: g.size.height * CGFloat(f) - 1)
                            }
                        }
                        .allowsHitTesting(false)
                    }
            }
        } else {
            content
        }
    }
}

/// La riga che si «ritira»: sparisce da destra verso sinistra dietro una riga verde verticale
/// (Elimina nel Magazzino, Pubblica nelle Bozze). `da` = quando parte (nil = niente).
struct RitiroRiga: ViewModifier {
    let da: Date?
    var durata: Double = 0.52

    @ViewBuilder
    func body(content: Content) -> some View {
        if let da {
            TimelineView(.animation(minimumInterval: 1 / 60, paused: Date().timeIntervalSince(da) > durata + 0.05)) { ctx in
                let passato = max(ctx.date.timeIntervalSince(da), Date().timeIntervalSince(da))
                let v = morbido(passato / durata)
                content
                    .mask(alignment: .leading) {
                        GeometryReader { g in
                            Rectangle().frame(width: g.size.width * CGFloat(1 - v), height: g.size.height)
                        }
                    }
                    .overlay(alignment: .leading) {
                        GeometryReader { g in
                            if v > 0 && v < 1 {
                                Rectangle().fill(Theme.glow)
                                    .frame(width: 2, height: g.size.height)
                                    .shadow(color: Theme.glow, radius: 4)
                                    .offset(x: g.size.width * CGFloat(1 - v) - 1)
                            }
                        }
                        .allowsHitTesting(false)
                    }
            }
        } else {
            content
        }
    }
}

extension View {
    func stampa(_ da: Date?, ritardo: Double = 0, durata: Double = 0.32) -> some View {
        modifier(StampaRiga(da: da, ritardo: ritardo, durata: durata))
    }
    func ritiro(_ da: Date?, durata: Double = 0.52) -> some View {
        modifier(RitiroRiga(da: da, durata: durata))
    }
}

/// Un numero che conta da `partenza` a `valore` (i numeri in alto mentre arrivano i dati, il totale che scala).
struct NumeroConta: View {
    let valore: Double
    let da: Date?
    var partenza: Double = 0
    var ritardo: Double = 0
    var durata: Double = 0.9
    let formato: (Double) -> String

    var body: some View {
        if let da {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: Date().timeIntervalSince(da) > ritardo + durata + 0.05)) { ctx in
                let passato = max(ctx.date.timeIntervalSince(da), Date().timeIntervalSince(da))
                let k = morbido((passato - ritardo) / durata)
                Text(formato(partenza + (valore - partenza) * k))
            }
        } else {
            Text(formato(valore))
        }
    }
}

/// La barra con la percentuale mentre si legge Discogs (Magazzino): sale verso il 90% mentre aspetta,
/// arriva al 100% quando i dati ci sono. Testo in monospazio come nel mock-up.
struct BarraLettura: View {
    let inizio: Date
    let fine: Date?
    let testoFine: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: fine != nil)) { ctx in
            let t = max(0, ctx.date.timeIntervalSince(inizio))
            let pct = fine == nil ? 90 * (1 - exp(-t / 1.2)) : 100
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(fine == nil ? "LEGGO DISCOGS" : testoFine)
                    Spacer()
                    Text("\(Int(pct.rounded()))%").monospacedDigit()
                }
                .font(Theme.mono(9, .bold)).tracking(1.5)
                .foregroundStyle(Theme.glow)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.glow.opacity(0.15))
                        Capsule().fill(Theme.glow)
                            .frame(width: g.size.width * CGFloat(pct / 100))
                            .shadow(color: Theme.glow, radius: 4)
                    }
                }
                .frame(height: 3)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
