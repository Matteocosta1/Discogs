import SwiftUI
import UIKit

/// V60 · proposta 11 — il REC dal vivo, con gli ologrammi alla JARVIS (scelta 1 di Alessandro, 25 ott).
/// Mentre si filma, il telefono trova le copertine nell'inquadratura (gratis, sul telefono: CopertineVive).
/// Una copertina vista in almeno 3 fotogrammi e ferma per un attimo si «aggancia»: angoli verdi, fascio di luce,
/// vinile olografico; intanto se ne prende il fotogramma e parte il riconoscimento (come uno scatto).
/// Quando arriva la risposta il cartellino si riempie con artista, titolo e prezzo.
@MainActor @Observable
final class RECVivo {
    struct Traccia: Identifiable {
        let id = UUID()
        var angoli: [CGPoint]           // nei punti dell'anteprima, smussati fotogramma dopo fotogramma
        var angoliCamera: [CGPoint]     // gli stessi, in coordinate della fotocamera (0…1): servono a ritagliare la copertina
        var centro: CGPoint
        var visti = 1
        var ultimo: Date
        var fermoDa: Date
        var agganciato: Date?
        var ordine = 0                  // 0, 1, 2… nell'ordine di aggancio (sfasa giro e scansione dell'ologramma)
        var discID: UUID?
    }

    private(set) var tracce: [Traccia] = [] {
        didSet { if haTracce != !tracce.isEmpty { haTracce = !tracce.isEmpty } }
    }
    /// Cambia solo quando le tracce passano da zero ad almeno una (la fotocamera non si ridisegna a ogni fotogramma).
    private(set) var haTracce = false
    private(set) var agganciati = 0
    /// La copertina di cui serve il fotogramma da riconoscere (una alla volta).
    private(set) var daFotografare: UUID?
    private(set) var attivo = false

    func inizia() {
        tracce = []
        agganciati = 0
        daFotografare = nil
        attivo = true
    }

    func ferma() {
        attivo = false
        daFotografare = nil
    }

    func pulisci() { tracce = [] }

    static func centro(_ q: [CGPoint]) -> CGPoint {
        guard !q.isEmpty else { return .zero }
        var x: CGFloat = 0, y: CGFloat = 0
        for p in q { x += p.x; y += p.y }
        return CGPoint(x: x / CGFloat(q.count), y: y / CGFloat(q.count))
    }

    /// Un fotogramma: le copertine trovate (4 angoli ciascuna, nei punti dell'anteprima).
    /// `camera`: gli stessi quadri in coordinate della fotocamera (stesso ordine).
    func aggiorna(_ quadri: [[CGPoint]], camera: [[CGPoint]]) {
        guard attivo else { return }
        let ora = Date()
        var libere = Array(tracce.indices)
        for (indice, q) in quadri.enumerated() where q.count == 4 {
            let qc = indice < camera.count ? camera[indice] : []
            let c = RECVivo.centro(q)
            var migliore: Int?
            var distanza: CGFloat = 110
            for i in libere {
                let d = hypot(tracce[i].centro.x - c.x, tracce[i].centro.y - c.y)
                if d < distanza { distanza = d; migliore = i }
            }
            if let i = migliore {
                libere.removeAll { $0 == i }
                var t = tracce[i]
                if distanza > 10 { t.fermoDa = ora }         // si è mosso: il «fermo» riparte
                var nuovi: [CGPoint] = []
                for k in 0..<4 {
                    let a = t.angoli[k], b = q[k]
                    nuovi.append(CGPoint(x: a.x * 0.5 + b.x * 0.5, y: a.y * 0.5 + b.y * 0.5))
                }
                t.angoli = nuovi
                t.centro = RECVivo.centro(nuovi)
                if qc.count == 4 { t.angoliCamera = qc }
                t.visti += 1
                t.ultimo = ora
                tracce[i] = t
            } else {
                tracce.append(Traccia(angoli: q, angoliCamera: qc, centro: c, ultimo: ora, fermoDa: ora))
            }
        }
        // uscita dall'inquadratura: dopo 1 s senza vederla la traccia sparisce
        tracce.removeAll { ora.timeIntervalSince($0.ultimo) > 1.0 }
        // aggancio: vista in almeno 3 fotogrammi e ferma da 0,45 s; una alla volta
        if daFotografare == nil,
           let i = tracce.firstIndex(where: { $0.agganciato == nil && $0.visti >= 3 && ora.timeIntervalSince($0.fermoDa) >= 0.45 }) {
            tracce[i].agganciato = ora
            tracce[i].ordine = agganciati
            agganciati += 1
            daFotografare = tracce[i].id
        }
    }

    /// Gli angoli (coordinate della fotocamera) della copertina da fotografare.
    func angoliCamera(_ id: UUID) -> [CGPoint] {
        tracce.first(where: { $0.id == id })?.angoliCamera ?? []
    }

    /// Il fotogramma è partito per il riconoscimento (o non c'era: disco nil).
    func fotografata(_ id: UUID, disco: UUID?) {
        if let i = tracce.firstIndex(where: { $0.id == id }) { tracce[i].discID = disco }
        if daFotografare == id { daFotografare = nil }
    }
}

/// Gli ologrammi sopra le copertine agganciate (stesso disegno del mock-up approvato, in verde Vinyl Hustler).
struct HologrammiREC: View {
    let rec: RECVivo
    let dischi: [Disc]
    var valuta = "EUR"

    /// Quello che dice il cartellino di un disco agganciato.
    private struct Cartellino {
        var riga1: String
        var riga2: String
        var analisi: Bool
        var errore: Bool
    }

    // V65: tutto più lento (come nel mock-up approvato)
    private static let neon: [(ms: Double, luce: Double)] = [(0, 0), (110, 0.9), (180, 0.15), (270, 1), (400, 0.4), (490, 1)]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let tracce = rec.tracce
            let schede = cartellini(per: tracce)
            Canvas { gc, size in
                for t in tracce { disegna(gc, t, schede[t.id], ora: ctx.date, largoVista: size.width) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func cartellini(per tracce: [RECVivo.Traccia]) -> [UUID: Cartellino] {
        var out: [UUID: Cartellino] = [:]
        for t in tracce where t.agganciato != nil {
            guard let id = t.discID, let d = dischi.first(where: { $0.id == id }) else {
                out[t.id] = Cartellino(riga1: "AGGANCIATO", riga2: "ANALISI", analisi: true, errore: false)
                continue
            }
            switch d.status {
            case .inLavorazione:
                out[t.id] = Cartellino(riga1: "ANALISI DEL DISCO", riga2: "DISCOGS", analisi: true, errore: false)
            case .daControllare, .bloccato:
                out[t.id] = Cartellino(riga1: "NON RICONOSCIUTO", riga2: "RIPROVA CON UNA FOTO", analisi: false, errore: true)
            default:
                // il titolo è «Artista - Titolo (Etichetta, Paese, Anno)»: via la parentesi finale, poi artista e titolo
                let base = d.releaseTitle.replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression)
                let trattino = base.contains(" - ") ? " - " : " – "
                let parti = base.components(separatedBy: trattino)
                let artista = parti.count > 1 ? parti[0] : base
                let titolo = parti.count > 1 ? parti.dropFirst().joined(separator: trattino) : ""
                let prezzo = d.price.map { $0.formatted(.currency(code: valuta).precision(.fractionLength(0...2))) } ?? ""
                let riga2 = [titolo, prezzo].filter { !$0.isEmpty }.joined(separator: " · ")
                out[t.id] = Cartellino(riga1: artista.uppercased(), riga2: riga2.uppercased(), analisi: false, errore: false)
            }
        }
        return out
    }

    private func verde(_ a: Double) -> Color { Theme.glow.opacity(a) }

    private func disegna(_ gc: GraphicsContext, _ t: RECVivo.Traccia, _ c: Cartellino?, ora: Date, largoVista: CGFloat) {
        var gc = gc
        let q = t.angoli
        guard q.count == 4 else { return }
        // V65: uno alla volta: si vede solo il disco al centro; quelli che vanno verso i lati si spengono piano
        let mezzo = largoVista * 0.18
        let distanza = abs(t.centro.x - largoVista / 2)
        let fuoco = 1 - min(1, max(0, Double((distanza - mezzo) / max(1, mezzo))))
        guard fuoco > 0 else { return }
        guard let quando = t.agganciato else {
            // vista ma non ancora agganciata: angoli tenui (si vede che la sta guardando)
            if t.visti >= 2 { angoli(&gc, q, scala: 1.0, alfa: 0.35 * fuoco) }
            return
        }
        let tt = ora.timeIntervalSince(quando) * 1000
        var luce = 1.0
        for passo in Self.neon where tt >= passo.ms { luce = passo.luce }
        luce *= fuoco
        gc.opacity = luce
        // 1 · angoli che agganciano la copertina (si stringono sul disco)
        let scala = CGFloat(1.28 - 0.28 * morbido(tt / 650))
        var luminoso = gc
        luminoso.addFilter(.shadow(color: verde(0.9), radius: 6))
        angoli(&luminoso, q, scala: scala, alfa: 0.95)
        // 2 · il fascio di luce e 3 · il vinile a fil di ferro sopra il bordo alto
        let alto = CGPoint(x: (q[0].x + q[1].x) / 2, y: (q[0].y + q[1].y) / 2)
        let latoAlto = hypot(q[1].x - q[0].x, q[1].y - q[0].y)
        let ap = morbido(tt / 700)
        let rx = max(36, min(64, latoAlto * 0.42)) * CGFloat(ap), ry = rx * 0.29
        let hy = alto.y - 62
        if ap > 0.05 {
            var fascio = Path()
            fascio.move(to: CGPoint(x: alto.x - 20, y: alto.y))
            fascio.addLine(to: CGPoint(x: alto.x + 20, y: alto.y))
            fascio.addLine(to: CGPoint(x: alto.x + rx, y: hy))
            fascio.addLine(to: CGPoint(x: alto.x - rx, y: hy))
            fascio.closeSubpath()
            gc.fill(fascio, with: .linearGradient(Gradient(colors: [verde(0.22), verde(0.04)]),
                                                 startPoint: CGPoint(x: 0, y: alto.y), endPoint: CGPoint(x: 0, y: hy)))
            let centro = CGPoint(x: alto.x, y: hy)
            let ellisse = { (r: CGFloat, dy: CGFloat) -> Path in
                Path(ellipseIn: CGRect(x: centro.x - rx * r, y: centro.y + dy - ry * r, width: 2 * rx * r, height: 2 * ry * r))
            }
            gc.fill(ellisse(1, 0), with: .color(verde(0.07)))                         // il velo
            gc.stroke(ellisse(1, 4), with: .color(verde(0.35)), lineWidth: 1)         // lo spessore
            gc.stroke(ellisse(1, 0), with: .color(verde(0.95)), lineWidth: 1.6)       // il bordo
            for r in [0.86, 0.74, 0.62, 0.5] as [CGFloat] {                           // i solchi
                gc.stroke(ellisse(r, 0), with: .color(verde(0.4)), lineWidth: 0.8)
            }
            gc.fill(ellisse(0.3, 0), with: .color(verde(0.28)))                       // l'etichetta
            let giro = tt / 1000 * 1.7 + Double(t.ordine)
            for s in 0..<12 {                                                         // i raggi: si vede che gira
                let an = giro + Double(s) * Double.pi / 6
                let cs = CGFloat(cos(an)), sn = CGFloat(sin(an))
                var raggio = Path()
                raggio.move(to: CGPoint(x: centro.x + cs * rx * 0.3, y: centro.y + sn * ry * 0.3))
                raggio.addLine(to: CGPoint(x: centro.x + cs * rx, y: centro.y + sn * ry))
                gc.stroke(raggio, with: .color(verde(0.15 + 0.45 * Double(sn + 1) / 2)), lineWidth: 0.8)
            }
            // la riga di scansione che attraversa l'ologramma
            let p = (ora.timeIntervalSinceReferenceDate / 1.4 + Double(t.ordine) * 0.37).truncatingRemainder(dividingBy: 1)
            let ys = hy - ry - 4 + (2 * ry + 12) * CGFloat(p)
            let k = (ys - hy) / (ry + 4)
            let lx = rx * sqrt(max(0, 1 - k * k))
            if lx > 2 {
                var riga = Path()
                riga.move(to: CGPoint(x: centro.x - lx, y: ys))
                riga.addLine(to: CGPoint(x: centro.x + lx, y: ys))
                gc.stroke(riga, with: .color(verde(0.55)), lineWidth: 1)
            }
        }
        // 4 · il cartellino sopra l'ologramma
        guard let c, tt > 500 else { return }
        let a = morbido((tt - 500) / 450)
        // il testo esce come simboli e si sistema (0,8 s dopo l'aggancio, in 0,9 s); in analisi resta mescolato
        let mescola: Double = c.analisi ? 0.55 : max(0, 1 - (tt - 800) / 900)
        let colore: Color = c.errore ? Theme.warn : Theme.glow
        let t1 = gc.resolve(Text(Glifi.rimescola(c.riga1, mescola)).font(Theme.mono(10, .bold)).foregroundStyle(Color(hex: 0xEAFFEA)))
        let t2 = gc.resolve(Text(Glifi.rimescola(c.riga2, mescola)).font(Theme.mono(9, .bold)).foregroundStyle(colore))
        let s1 = t1.measure(in: CGSize(width: 220, height: 40))
        let s2 = t2.measure(in: CGSize(width: 220, height: 40))
        let larghezza = min(220, max(s1.width, s2.width)) + 18
        let altezza = s1.height + (c.riga2.isEmpty ? 0 : s2.height + 2) + 12
        let base = hy - ry - 10                                                          // V65: uno alla volta, niente altezze alterne
        let rett = CGRect(x: alto.x - larghezza / 2, y: base - altezza, width: larghezza, height: altezza)
        var cg = gc
        cg.opacity = luce * a
        let forma = Path(roundedRect: rett, cornerRadius: 9)
        cg.fill(forma, with: .color(Color(red: 4 / 255, green: 10 / 255, blue: 6 / 255).opacity(0.82)))
        cg.stroke(forma, with: .color(colore.opacity(0.75)), lineWidth: 1)
        // asta corta dal cartellino all'ologramma
        var asta = Path()
        asta.move(to: CGPoint(x: alto.x, y: base))
        asta.addLine(to: CGPoint(x: alto.x, y: hy - ry))
        cg.stroke(asta, with: .color(verde(0.6)), lineWidth: 1.5)
        cg.draw(t1, in: CGRect(x: rett.minX + 9, y: rett.minY + 6, width: larghezza - 18, height: s1.height))
        if !c.riga2.isEmpty {
            cg.draw(t2, in: CGRect(x: rett.minX + 9, y: rett.minY + 6 + s1.height + 2, width: larghezza - 18, height: s2.height))
        }
    }

    /// Gli angoli verdi sulla copertina (lungo i suoi lati, anche se è storta), allargati di `scala` intorno al centro.
    private func angoli(_ gc: inout GraphicsContext, _ q: [CGPoint], scala: CGFloat, alfa: Double) {
        let c = RECVivo.centro(q)
        let p = q.map { CGPoint(x: c.x + ($0.x - c.x) * scala, y: c.y + ($0.y - c.y) * scala) }
        var tratti = Path()
        for i in 0..<4 {
            let a = p[i], prima = p[(i + 3) % 4], dopo = p[(i + 1) % 4]
            for v in [prima, dopo] {
                let dx = v.x - a.x, dy = v.y - a.y
                let l = max(1, hypot(dx, dy))
                let braccio = min(18, l * 0.25)
                tratti.move(to: a)
                tratti.addLine(to: CGPoint(x: a.x + dx / l * braccio, y: a.y + dy / l * braccio))
            }
        }
        gc.stroke(tratti, with: .color(verde(alfa)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
    }
}
