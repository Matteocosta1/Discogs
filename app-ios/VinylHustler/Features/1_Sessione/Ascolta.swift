import SwiftUI
import UIKit
import WebKit

// MARK: - Il riquadro del disco in alto (come il Satellite di JARVIS, nel verde Discosizer) — V59

/// Sotto "VINYL HUSTLER": titolo, artista, anno, paese, catalogo, etichetta e formato del disco riconosciuto.
/// Si apre dall'alto con una linea di scansione; V60: le scritte escono come simboli e si sistemano riga per riga.
struct PannelloDisco: View {
    let release: Release
    let versione: String
    /// V64: 0 = pieno; 1 = senza cartellini e formato (telefoni piccoli); 2 = anche senza la riga DISCO / VERSIONE.
    var stretto = 0
    /// Quando il riquadro è comparso: da qui partono le decodifiche (una nuova release = un riquadro nuovo, con .id).
    @State private var aperto = Date()
    @State private var scan: CGFloat = 0
    @State private var scanVisibile = true

    private var artista: String {
        release.artist.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
    }
    /// V64: ha righe che si possono togliere quando lo spazio non basta (cartellini o formato)?
    static func haExtra(_ r: Release) -> Bool {
        let p = PannelloDisco(release: r, versione: "")
        return !p.cartellini.isEmpty || !p.etichettaFormato.isEmpty
    }
    private var cartellini: [String] {
        [release.year.map(String.init) ?? "", release.country ?? "", release.labels?.first?.catno ?? ""]
            .filter { !$0.isEmpty && $0.lowercased() != "none" }
    }
    private var etichettaFormato: String {
        [release.labels?.first?.name ?? "", release.formatoBreve].filter { !$0.isEmpty }.joined(separator: " · ").uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if stretto < 2 {
            riga(0) {
                HStack {
                    Text("● DISCO")
                    Spacer(minLength: 8)
                    if !versione.isEmpty { decodifica("VERSIONE \(versione)", 0) }
                }
                .font(Theme.mono(9, .bold)).tracking(1.5).foregroundStyle(Theme.glow)
            }
            }
            riga(1) {
                decodifica(release.title.uppercased(), 1)
                    .font(Theme.mono(15, .heavy)).tracking(1)
                    .foregroundStyle(Color(hex: 0xEAFFEA)).lineLimit(2)
            }
            riga(2) {
                decodifica(artista.uppercased(), 2)
                    .font(Theme.mono(11, .bold)).tracking(1.5)
                    .foregroundStyle(Theme.accent).lineLimit(1)
            }
            if !cartellini.isEmpty && stretto == 0 {
                riga(3) {
                    HStack(spacing: 6) {
                        ForEach(cartellini, id: \.self) { c in
                            decodifica(c.uppercased(), 3)
                                .font(Theme.mono(9, .bold)).tracking(1)
                                .foregroundStyle(Color(hex: 0xD9FFD9)).lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.glow.opacity(0.5), lineWidth: 1))
                        }
                    }
                }
            }
            if !etichettaFormato.isEmpty && stretto == 0 {
                riga(4) {
                    decodifica(etichettaFormato, 4)
                        .font(Theme.mono(9, .semibold)).tracking(1.2)
                        .foregroundStyle(Color(hex: 0x8FD88F)).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Color(red: 0.016, green: 0.03, blue: 0.02).opacity(0.78), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.glow.opacity(0.55), lineWidth: 1))
        .overlay(alignment: .top) {
            // la linea di scansione: passa una volta sola, dall'alto in basso
            GeometryReader { g in
                Rectangle().fill(Theme.glow).frame(height: 2)
                    .shadow(color: Theme.glow, radius: 6)
                    .offset(y: scan * g.size.height)
                    .opacity(scanVisibile ? 1 : 0)
            }
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: Theme.glow.opacity(0.25), radius: 10)
        .task {
            withAnimation(.easeOut(duration: 0.9)) { scan = 1 }
            try? await Task.sleep(for: .milliseconds(950))
            withAnimation(.easeOut(duration: 0.3)) { scanVisibile = false }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([release.title, artista, etichettaFormato].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// Le righe si vedono subito: sono i simboli che diventano il testo, una riga dopo l'altra (come nel mock-up:
    /// 200 ms, poi 110 ms tra una riga e la successiva, 420 ms per sistemarsi).
    private func riga<C: View>(_ i: Int, @ViewBuilder _ contenuto: () -> C) -> some View {
        contenuto()
    }

    private func decodifica(_ testo: String, _ i: Int) -> TestoDecodifica {
        TestoDecodifica(testo: testo, da: aperto, ritardo: 0.2 + Double(i) * 0.11, durata: 0.42)
    }
}

// MARK: - Il lettore piccolo (sotto la scheda): si tira su col dito o si tocca

struct LettorePiccolo: View {
    let ascolto: Ascolto
    /// V63: con più dischi da decidere, quale suona («2/3»).
    var numero: String = ""
    let apri: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Capsule().fill(Color(hex: 0xEAFFEA).opacity(0.45)).frame(width: 40, height: 5)
            HStack(spacing: 10) {
                DiscoGira(copertina: ascolto.copertina, gira: ascolto.suona)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    if let b = ascolto.corrente {
                        Text(b.posizione.isEmpty ? b.titolo : "\(b.posizione) · \(b.titolo)")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(numero.isEmpty ? Ascolto.scritta(ascolto.fonteMostrata) : numero + " · " + Ascolto.scritta(ascolto.fonteMostrata))
                            .font(Theme.mono(9, .semibold)).tracking(1.5).foregroundStyle(Theme.glow).lineLimit(1)
                    } else {
                        Text("CERCO LE TRACCE…")
                            .font(Theme.mono(10, .semibold)).tracking(1.5).foregroundStyle(Theme.glow)
                    }
                }
                Spacer(minLength: 4)
                if ascolto.suona { BarreSuono().frame(width: 15, height: 14) }
                Button {
                    ascolto.playPausa()
                    if ascolto.fonteMostrata == .video { apri() }      // il video si guarda nel lettore grande
                } label: {
                    Image(systemName: ascolto.suona ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(Color.black)
                        .frame(width: 38, height: 38)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(ascolto.corrente == nil)
                .accessibilityLabel(ascolto.suona ? "Pausa" : "Riproduci")
            }
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 10)
        .background(Color(hex: 0x070F09).opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.glow.opacity(0.3), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { apri() }
        .gesture(DragGesture(minimumDistance: 8).onEnded { v in
            if v.translation.height < -40 { apri() }
        })
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Apre il lettore con le tracce del disco")
    }
}

// MARK: - Il lettore grande (sale dal basso, come la tendina PROTOCOLLI di JARVIS ma al contrario)

struct LettoreGrande: View {
    let ascolto: Ascolto
    let release: Release?
    /// V60: la X in alto (sezione con la fotocamera: si chiude con la X nel cerchio).
    var chiudi: () -> Void = {}
    /// La maniglia: il dito che tira giù (di quanto) e quando lascia.
    var trascinando: (CGFloat) -> Void = { _ in }
    var rilasciato: (CGFloat) -> Void = { _ in }
    /// V63: i dischi da decidere (con il REC possono essere più di uno): si sceglie quale ascoltare.
    var dischi: [DiscoFila] = []
    var attivo: UUID? = nil
    var scegli: (UUID) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Capsule().fill(Color(hex: 0xEAFFEA).opacity(0.45)).frame(width: 44, height: 5)
                HStack {
                    Text("ASCOLTA")
                        .font(Theme.mono(13, .bold)).tracking(3)
                        .foregroundStyle(Theme.glow).shadow(color: Theme.glow.opacity(0.5), radius: 5)
                    Spacer()
                    Text(sottotitolo)
                        .font(Theme.mono(9, .semibold)).tracking(1.5)
                        .foregroundStyle(Color(hex: 0x8FD88F)).lineLimit(1)
                    Button { chiudi() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 36, height: 36)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Theme.accent.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Chiudi il lettore")
                }
            }
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 6)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { v in trascinando(v.translation.height) }
                .onEnded { v in rilasciato(v.translation.height) })
            .accessibilityHint("Tira giù per chiudere il lettore")

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    if dischi.count > 1 { filaDischi }
                    oraSuona
                    tracce
                }
                .padding(.horizontal, 14).padding(.bottom, 30)
            }
        }
    }

    /// «DISCHI · 3» e le copertine tonde: quella che suona ha l'anello verde acceso.
    private var filaDischi: some View {
        HStack(spacing: 10) {
            Text("DISCHI · \(dischi.count)")
                .font(Theme.mono(9, .bold)).tracking(1.5).foregroundStyle(Theme.glow)
                .fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(dischi) { d in
                        let on = d.id == attivo
                        Button { scegli(d.id) } label: {
                            AsyncImage(url: d.copertina) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                                .frame(width: 40, height: 40)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(on ? Theme.glow : Theme.glow.opacity(0.25), lineWidth: 1.5))
                                .shadow(color: Theme.glow.opacity(on ? 0.6 : 0), radius: 6)
                                .opacity(on ? 1 : 0.6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(d.titolo)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var sottotitolo: String {
        [release?.labels?.first?.catno ?? "", release?.formatoBreve ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // il riquadro di quello che suona (dal lettore MUSICA di JARVIS)
    private var oraSuona: some View {
        VStack(spacing: 10) {
            if ascolto.fonte == .video, let id = ascolto.videoID {
                VideoYouTube(videoID: id, ascolto: ascolto)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .id(id)
            } else {
                DiscoAscolto(copertina: ascolto.copertina, gira: ascolto.suona)
                    .frame(width: 210, height: 210)
            }
            VStack(spacing: 2) {
                Text(ascolto.corrente?.titolo ?? (ascolto.cercando ? "Cerco le tracce…" : "Nessuna traccia"))
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(ascolto.artista).font(.system(size: 14)).foregroundStyle(Color(hex: 0xB7C9B9)).lineLimit(1)
                Text(albumLato)
                    .font(Theme.mono(9, .semibold)).tracking(1.5).foregroundStyle(Theme.glow).lineLimit(1)
            }
            .multilineTextAlignment(.center)
            if ascolto.durata > 0 {
                HStack(spacing: 8) {
                    Text(Self.mmss(ascolto.tempo)).frame(width: 38, alignment: .leading)
                    GeometryReader { g in
                        let f = min(1, max(0, ascolto.tempo / max(ascolto.durata, 1)))
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.glow.opacity(0.15))
                            RoundedRectangle(cornerRadius: 2).fill(Theme.glow)
                                .frame(width: g.size.width * f)
                                .shadow(color: Theme.glow.opacity(0.7), radius: 4)
                        }
                        .frame(height: 4)
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: 14)
                    Text(Self.mmss(ascolto.durata)).frame(width: 38, alignment: .trailing)
                }
                .font(Theme.mono(10, .semibold))
                .foregroundStyle(Color(hex: 0x7D8F80))
                .monospacedDigit()
            }
            HStack(spacing: 22) {
                tasto("backward.end.fill", "Brano precedente") { ascolto.indietro() }
                Button { ascolto.playPausa() } label: {
                    Image(systemName: ascolto.suona ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .bold)).foregroundStyle(Color(hex: 0x06100A))
                        .frame(width: 62, height: 62)
                        .background(Theme.glow, in: Circle())
                        .shadow(color: Theme.glow.opacity(0.55), radius: 9)
                }
                .buttonStyle(.plain)
                .disabled(ascolto.corrente == nil)
                .accessibilityLabel(ascolto.suona ? "Pausa" : "Riproduci")
                tasto("forward.end.fill", "Brano successivo") { ascolto.avanti() }
            }
            Text(Ascolto.scritta(ascolto.fonteMostrata))
                .font(Theme.mono(8, .semibold)).tracking(2).foregroundStyle(Color(hex: 0x7D8F80))
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(RadialGradient(colors: [Theme.glow.opacity(0.10), Color(hex: 0x060D08).opacity(0.6)],
                                   center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 280),
                    in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.glow.opacity(0.28), lineWidth: 1))
    }

    private var albumLato: String {
        let lato = ascolto.corrente?.lato ?? ""
        return ascolto.titoloDisco.uppercased() + (lato.isEmpty ? "" : " · LATO \(lato)")
    }

    // la tracklist del disco (da Discogs), con la fonte di ogni brano
    private var tracce: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("TRACCE")
                .font(Theme.mono(10, .bold)).tracking(2).foregroundStyle(Color(hex: 0x8FD88F))
                .padding(.horizontal, 6).padding(.vertical, 4)
            if ascolto.brani.isEmpty {
                Text(ascolto.cercando ? "Cerco le tracce…" : "Discogs non ha la tracklist di questo disco.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted).padding(.horizontal, 6)
            }
            ForEach(ascolto.brani) { b in
                let scelto = b.id == ascolto.indice
                let f = ascolto.fonteDi(b)
                Button { ascolto.metti(b.id) } label: {
                    HStack(spacing: 10) {
                        Text(b.posizione)
                            .font(Theme.mono(11, .bold)).foregroundStyle(scelto ? Theme.glow : Color(hex: 0x7D8F80))
                            .frame(width: 26, alignment: .leading)
                        Text(b.titolo)
                            .font(.system(size: 14, weight: scelto ? .bold : .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Ascolto.breve(f))
                            .font(Theme.mono(8, .bold)).tracking(1)
                            .foregroundStyle(f == .video ? Color(hex: 0xFF8A80) : (f == .nessuna ? Theme.muted : Theme.glow))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(f == .video ? Color(hex: 0xFF8A80) : (f == .nessuna ? Theme.muted : Theme.glow), lineWidth: 1))
                        Text(b.durataTesto)
                            .font(Theme.mono(11)).foregroundStyle(Color(hex: 0x7D8F80))
                            .frame(width: 40, alignment: .trailing)
                    }
                    .padding(.vertical, 9).padding(.horizontal, 8)
                    .background(scelto ? Theme.glow.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(f == .nessuna && !ascolto.cercando)
            }
        }
    }

    private func tasto(_ simbolo: String, _ nome: String, azione: @escaping () -> Void) -> some View {
        Button { azione() } label: {
            Image(systemName: simbolo)
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.glow)
                .frame(width: 42, height: 42)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(ascolto.brani.isEmpty)
        .accessibilityLabel(nome)
    }

    static func mmss(_ s: Double) -> String {
        let t = Int(max(0, s.isFinite ? s : 0))
        return "\(t / 60):" + String(format: "%02d", t % 60)
    }
}

// MARK: - Dischi che girano

/// La copertina Discogs in un cerchio che gira mentre suona (piccolo, nel lettore in basso).
struct DiscoGira: View {
    let copertina: URL?
    let gira: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120, paused: !gira)) { ctx in
            let gradi = gira ? ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) / 6 * 360 : 0
            AsyncImage(url: copertina) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                .clipShape(Circle())
                .overlay(Circle().fill(Color.black).frame(width: 5, height: 5))
                .overlay(Circle().stroke(Theme.glow.opacity(0.6), lineWidth: 1))
                .rotationEffect(.degrees(gradi))
        }
        .accessibilityHidden(true)
    }
}

/// Il disco del lettore grande (dal lettore MUSICA di JARVIS): anello a tacche, spettro e copertina che gira.
struct DiscoAscolto: View {
    let copertina: URL?
    let gira: Bool

    var body: some View {
        GeometryReader { g in
            let W = min(g.size.width, g.size.height)
            TimelineView(.animation(minimumInterval: 1.0 / 120, paused: !gira)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                ZStack {
                    Canvas { gc, _ in DiscoAscolto.anelli(gc, W: W, t: t, suona: gira) }
                    AsyncImage(url: copertina) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                        .frame(width: W * 0.6, height: W * 0.6)
                        .clipShape(Circle())
                        .overlay(Circle().fill(Color(hex: 0x060D08)).frame(width: W * 0.07, height: W * 0.07))
                        .overlay(Circle().stroke(Theme.glow.opacity(0.4), lineWidth: 1))
                        .rotationEffect(.degrees(gira ? t.truncatingRemainder(dividingBy: 6) / 6 * 360 : 0))
                }
                .frame(width: W, height: W)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private static func punto(_ c: CGFloat, _ g: Double, _ r: CGFloat) -> CGPoint {
        CGPoint(x: c + CGFloat(cos(g)) * r, y: c + CGFloat(sin(g)) * r)
    }

    static func anelli(_ gc: GraphicsContext, W: CGFloat, t: Double, suona: Bool) {
        let c = W / 2, R = W * 0.47, u = W / 480
        gc.stroke(Path(ellipseIn: CGRect(x: c - R, y: c - R, width: R * 2, height: R * 2)),
                  with: .color(Theme.glow.opacity(0.35)), lineWidth: 2 * u)
        var tacche = Path()
        for k in 0..<120 {
            let g = Double(k) / 120 * 2 * Double.pi - t * 0.05
            let l: CGFloat = (k % 10 == 0 ? 14 : 6) * u
            tacche.move(to: punto(c, g, R))
            tacche.addLine(to: punto(c, g, R - l))
        }
        gc.stroke(tacche, with: .color(Theme.glow.opacity(0.2)), lineWidth: 2 * u)
        var spettro = Path()
        let ms = t * 1000
        for k in 0..<72 {
            let g = Double(k) / 72 * 2 * Double.pi
            let v = suona ? 0.35 + 0.65 * abs(sin(ms / 260 + Double(k) * 0.7) * sin(ms / 410 + Double(k) * 1.3)) : 0.08
            let r0 = W * 0.33, r1 = r0 + CGFloat(v) * W * 0.08
            spettro.move(to: punto(c, g, r0))
            spettro.addLine(to: punto(c, g, r1))
        }
        var s = gc
        s.addFilter(.shadow(color: Theme.glow, radius: 4 * u))
        s.stroke(spettro, with: .color(Theme.glow), lineWidth: 3 * u)
    }
}

/// Le tre barrette che saltano mentre suona.
struct BarreSuono: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { k in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.glow)
                        .frame(width: 3, height: 4 + 10 * abs(sin(t * 6 + Double(k) * 1.1)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Il video Discogs (lettore ufficiale di YouTube, dentro l'app)

/// Il lettore ufficiale di YouTube: il video si vede (come chiede YouTube) e parte da solo.
/// Racconta all'Ascolto tempo, durata e play/pausa; i tasti del lettore lo comandano.
struct VideoYouTube: UIViewRepresentable {
    let videoID: String
    let ascolto: Ascolto

    func makeCoordinator() -> Ponte { Ponte(ascolto: ascolto, videoID: videoID) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator, name: "vh")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        let sicuro = videoID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        web.loadHTMLString(Self.pagina(sicuro), baseURL: URL(string: "https://vinylhustler.app"))
        ascolto.comandoVideo = { [weak web] c in
            web?.evaluateJavaScript("cmd('\(c)')", completionHandler: nil)
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static func dismantleUIView(_ web: WKWebView, coordinator: Ponte) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "vh")
        web.stopLoading()
        let a = coordinator.ascolto, id = coordinator.videoID
        Task { @MainActor in a.videoChiuso(id) }
    }

    final class Ponte: NSObject, WKScriptMessageHandler {
        let ascolto: Ascolto
        let videoID: String
        init(ascolto: Ascolto, videoID: String) {
            self.ascolto = ascolto
            self.videoID = videoID
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let d = message.body as? [String: Any] else { return }
            let t = (d["t"] as? NSNumber)?.doubleValue ?? 0
            let durata = (d["d"] as? NSNumber)?.doubleValue ?? 0
            let s = (d["s"] as? NSNumber)?.boolValue ?? false
            let a = ascolto
            Task { @MainActor in a.statoVideo(tempo: t, durata: durata, suona: s) }
        }
    }

    static func pagina(_ id: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}#p{position:absolute;left:0;top:0;width:100%;height:100%}</style>
        </head><body><div id="p"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        var player;
        function onYouTubeIframeAPIReady(){
          player=new YT.Player('p',{width:'100%',height:'100%',videoId:'\(id)',
            playerVars:{playsinline:1,autoplay:1,rel:0,modestbranding:1,origin:'https://vinylhustler.app'},
            events:{onReady:function(e){e.target.playVideo();},onStateChange:invia}});
          setInterval(invia,500);
        }
        function invia(){
          if(!player||!player.getCurrentTime)return;
          window.webkit.messageHandlers.vh.postMessage({t:player.getCurrentTime()||0,d:player.getDuration()||0,
            s:(player.getPlayerState&&player.getPlayerState()==1)});
        }
        function cmd(c){ if(!player)return; if(c=='play')player.playVideo(); else if(c=='pausa')player.pauseVideo(); else if(c=='stop')player.stopVideo(); }
        </script></body></html>
        """
    }
}

/// V63: un disco nella fila del lettore grande.
struct DiscoFila: Identifiable {
    let id: UUID
    let copertina: URL?
    let titolo: String
}
