import SwiftUI
import UIKit

/// V60 · proposta 11 — il REC dal vivo (V67: con l'aggancio alla Tony Stark, vedi HologrammiREC).
/// Mentre si filma, il telefono trova le copertine nell'inquadratura (gratis, sul telefono: CopertineVive).
/// Una copertina vista in almeno 3 fotogrammi e ferma per un attimo si «aggancia»: intanto se ne prende
/// il fotogramma e parte il riconoscimento (come uno scatto). Quando arriva la risposta l'etichetta si riempie
/// con artista, titolo e prezzo.
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
        var ordine = 0                  // 0, 1, 2… nell'ordine di aggancio (il numero «01» dell'etichetta)
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

/// V67 — l'AGGANCIO alla Tony Stark (al posto degli ologrammi, come nel mock-up approvato il 26 ott):
/// · cerca: sulle copertine viste ma non ancora agganciate quattro angoli tenui, un po' larghi, che respirano;
/// · aggancio: gli angoli scattano sulla copertina in 0,22 s (con un filo di rimbalzo) e al centro il mirino
///   ruota di un quarto di giro e si blocca;
/// · etichetta sopra l'angolo in alto a sinistra: «01 · LOCK / ANALISI…», poi artista, titolo e prezzo che si decodificano.
/// Tutti insieme: ogni disco resta agganciato finché è nell'inquadratura. Niente linee, niente fasci, niente vinile.
struct HologrammiREC: View {
    let rec: RECVivo
    let dischi: [Disc]
    var valuta = "EUR"
    /// Quando ogni cartellino ha avuto i dati veri (per farli decodificare in quel momento).
    @State private var pronti: [UUID: Date] = [:]

    /// Quello che dice l'etichetta di un disco agganciato.
    private struct Cartellino {
        var riga1: String
        var riga2: String
        var analisi: Bool
    }

    var body: some View {
        let schede = cartellini(per: rec.tracce)
        let conDati = Set(schede.filter { !$0.value.analisi }.map(\.key))
        TimelineView(.animation(minimumInterval: 1.0 / 120)) { ctx in
            let tracce = rec.tracce
            Canvas { gc, size in
                for t in tracce { disegna(gc, t, schede[t.id], ora: ctx.date, larghezza: size.width) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: conDati, initial: true) { _, nuovi in
            let ora = Date()
            for id in nuovi where pronti[id] == nil { pronti[id] = ora }
        }
    }

    private func cartellini(per tracce: [RECVivo.Traccia]) -> [UUID: Cartellino] {
        var out: [UUID: Cartellino] = [:]
        for t in tracce where t.agganciato != nil {
            guard let id = t.discID, let d = dischi.first(where: { $0.id == id }) else {
                out[t.id] = Cartellino(riga1: "LOCK", riga2: "ANALISI…", analisi: true)
                continue
            }
            switch d.status {
            case .inLavorazione:
                out[t.id] = Cartellino(riga1: "LOCK", riga2: "ANALISI…", analisi: true)
            case .daControllare, .bloccato:
                out[t.id] = Cartellino(riga1: "NON RICONOSCIUTO", riga2: "RIPROVA CON UNA FOTO", analisi: false)
            default:
                // il titolo è «Artista - Titolo (Etichetta, Paese, Anno)»: via la parentesi finale, poi artista e titolo
                let base = d.releaseTitle.replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression)
                let trattino = base.contains(" - ") ? " - " : " – "
                let parti = base.components(separatedBy: trattino)
                let artista = parti.count > 1 ? parti[0] : base
                let titolo = parti.count > 1 ? parti.dropFirst().joined(separator: trattino) : ""
                let prezzo = d.price.map { $0.formatted(.currency(code: valuta).precision(.fractionLength(0...2))) } ?? ""
                let riga2 = [titolo, prezzo].filter { !$0.isEmpty }.joined(separator: " · ")
                out[t.id] = Cartellino(riga1: artista.uppercased(), riga2: riga2.uppercased(), analisi: false)
            }
        }
        return out
    }

    private func verde(_ a: Double) -> Color { Theme.glow.opacity(max(0, min(1, a))) }

    /// Curva con un filo di rimbalzo (lo «scatto» degli angoli).
    private static func scatto(_ x: Double) -> Double {
        let c = min(1, max(0, x)), c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(c - 1, 3) + c1 * pow(c - 1, 2)
    }

    private func disegna(_ gc: GraphicsContext, _ t: RECVivo.Traccia, _ c: Cartellino?, ora: Date, larghezza: CGFloat) {
        var gc = gc
        let q = t.angoli
        guard q.count == 4 else { return }
        guard let quando = t.agganciato else {
            // cerca: angoli tenui un po' larghi che respirano
            guard t.visti >= 2 else { return }
            let r = 0.5 + 0.5 * sin(ora.timeIntervalSinceReferenceDate * 6.25)
            angoli(&gc, q, scala: 1.12 + 0.02 * CGFloat(r), alfa: 0.25 + 0.2 * r, spessore: 1.4)
            return
        }
        let tt = ora.timeIntervalSince(quando) * 1000
        // 1 · gli angoli scattano sulla copertina
        let scala = CGFloat(1.35 - 0.35 * Self.scatto(tt / 220))
        var luminoso = gc
        luminoso.addFilter(.shadow(color: verde(0.9), radius: 6))
        angoli(&luminoso, q, scala: scala, alfa: 0.95, spessore: 2.6)
        // 2 · il mirino (target): quattro archi che ruotano di un quarto di giro e si bloccano
        let centro = t.centro
        let lato = (hypot(q[1].x - q[0].x, q[1].y - q[0].y) + hypot(q[3].x - q[0].x, q[3].y - q[0].y)) / 2
        let ap = morbido(tt / 260)
        let giro = (1 - morbido(tt / 320)) * Double.pi / 2
        let raggio = lato * (0.18 + 0.08 * CGFloat(1 - ap))
        let alfaMirino = (tt < 700 ? 0.85 : 0.85 - 0.5 * min(1, (tt - 700) / 400)) * ap
        for k in 0..<4 {
            let a0 = giro + Double(k) * Double.pi / 2 + 0.35
            var arco = Path()
            arco.addArc(center: centro, radius: raggio, startAngle: .radians(a0), endAngle: .radians(a0 + Double.pi / 2 - 0.7), clockwise: false)
            luminoso.stroke(arco, with: .color(verde(alfaMirino)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        luminoso.fill(Path(ellipseIn: CGRect(x: centro.x - 1.8, y: centro.y - 1.8, width: 3.6, height: 3.6)), with: .color(verde(alfaMirino)))
        // 3 · l'etichetta sopra l'angolo in alto a sinistra
        guard let c, tt > 180 else { return }
        let a = morbido((tt - 180) / 220)
        let numero = String(format: "%02d", t.ordine + 1)
        let mescola: Double = c.analisi ? 0 : pronti[t.id].map { max(0, 1 - ora.timeIntervalSince($0) / 0.42) } ?? 1
        let t1 = gc.resolve(Text("\(numero) · " + Glifi.rimescola(c.riga1, mescola)).font(Theme.mono(10, .bold)).foregroundStyle(Color(hex: 0xEAFFEA)))
        let t2 = gc.resolve(Text(Glifi.rimescola(c.riga2, mescola)).font(Theme.mono(9, .bold)).foregroundStyle(Theme.glow))
        let s1 = t1.measure(in: CGSize(width: 230, height: 40))
        let s2 = t2.measure(in: CGSize(width: 230, height: 40))
        let larga = min(230, max(s1.width, s2.width)) + 16
        let alta = s1.height + s2.height + 12
        let sinistra = q.min(by: { $0.x + $0.y < $1.x + $1.y }) ?? q[0]          // l'angolo in alto a sinistra
        let x = min(max(4, sinistra.x - 5), max(4, larghezza - larga - 4))
        let rett = CGRect(x: x, y: sinistra.y - 8 - alta, width: larga, height: alta)
        var cg = gc
        cg.opacity = a
        let forma = Path(roundedRect: rett, cornerRadius: 7)
        cg.fill(forma, with: .color(Color(red: 4 / 255, green: 10 / 255, blue: 6 / 255).opacity(0.82)))
        cg.stroke(forma, with: .color(verde(0.75)), lineWidth: 1)
        cg.draw(t1, in: CGRect(x: rett.minX + 8, y: rett.minY + 5, width: larga - 16, height: s1.height))
        cg.draw(t2, in: CGRect(x: rett.minX + 8, y: rett.minY + 7 + s1.height, width: larga - 16, height: s2.height))
    }

    /// Gli angoli verdi sulla copertina (lungo i suoi lati, anche se è storta), allargati di `scala` intorno al centro.
    private func angoli(_ gc: inout GraphicsContext, _ q: [CGPoint], scala: CGFloat, alfa: Double, spessore: CGFloat) {
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
        gc.stroke(tratti, with: .color(verde(alfa)), style: StrokeStyle(lineWidth: spessore, lineCap: .round, lineJoin: .round))
    }
}
