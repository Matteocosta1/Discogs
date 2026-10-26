import SwiftUI
import UIKit

// V60 · p15 — ASCOLTO da Bozze e Magazzino (come nel mock-up approvato):
// sulla copertina tonda c'è il tasto ▶; toccandolo si apre la finestra del lettore alla JARVIS:
// dalla copertina parte una riga verde che si allarga, poi la finestra si apre in altezza e il contenuto
// si stampa riga per riga. In alto «ASCOLTO» e «Chiudi» (qui non c'è fotocamera: scritta, non X).
// Dentro c'è il lettore della V59 (Ascolto.shared): disco, titolo e fonte, tempo, comandi, tracce per lato.

/// Il disco da ascoltare e da dove parte la finestra (il centro della copertina toccata, sullo schermo).
struct BersaglioAscolto: Identifiable {
    let id = UUID()
    let releaseID: Int
    let titolo: String
    let origine: CGPoint
}

/// Il tasto ▶ sopra la copertina tonda: tutta la copertina è il bersaglio del tocco.
struct TastoAscolta: View {
    let nome: String
    let azione: (CGPoint) -> Void

    var body: some View {
        GeometryReader { g in
            Button {
                let f = g.frame(in: .global)
                azione(CGPoint(x: f.midX, y: f.midY))
            } label: {
                ZStack {
                    Circle().fill(Color.black.opacity(0.42))
                    Circle().stroke(Theme.glow.opacity(0.85), lineWidth: 1.5)
                        .shadow(color: Theme.glow.opacity(0.45), radius: 4)
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.glow)
                        .shadow(color: Theme.glow.opacity(0.8), radius: 3)
                        .offset(x: 1)
                }
                .frame(width: g.size.width, height: g.size.height)
                .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Ascolta \(nome)")
        }
    }
}

extension View {
    /// Presenta la finestra Ascolto sopra tutto (anche sopra la barra in basso), senza l'animazione di sistema:
    /// l'apertura e la chiusura le fa la finestra.
    func finestraAscolto(_ bersaglio: Binding<BersaglioAscolto?>, seller: Seller) -> some View {
        fullScreenCover(item: bersaglio) { b in
            FinestraAscolto(bersaglio: b) {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { bersaglio.wrappedValue = nil }
            }
            .environment(seller)
            .presentationBackground(.clear)
        }
    }
}

/// Apre la finestra senza l'animazione di sistema (la finestra fa la sua).
@MainActor
func apriFinestraAscolto(_ b: BersaglioAscolto, in stato: Binding<BersaglioAscolto?>) {
    var t = Transaction()
    t.disablesAnimations = true
    withTransaction(t) { stato.wrappedValue = b }
}

struct FinestraAscolto: View {
    let bersaglio: BersaglioAscolto
    let chiudi: () -> Void

    private enum Fase { case apre(Date), aperta, chiude(Date) }

    @Environment(Seller.self) private var seller
    @State private var fase: Fase = .apre(Date())
    private let ascolto = Ascolto.shared

    private let durataApre = 0.62
    private let durataChiude = 0.30

    private var animando: Bool {
        if case .aperta = fase { return false }
        return true
    }

    private func avanzamento(_ ora: Date) -> Double {
        switch fase {
        case .aperta: return 1
        case .apre(let d): return min(1, max(0, ora.timeIntervalSince(d) / durataApre))
        case .chiude(let d): return 1 - min(1, max(0, ora.timeIntervalSince(d) / durataChiude))
        }
    }

    var body: some View {
        GeometryReader { g in
            TimelineView(.animation(minimumInterval: 1 / 60, paused: !animando)) { ctx in
                let k = avanzamento(ctx.date)
                ZStack {
                    Color.black.opacity(0.6 * min(1, k * 1.6))
                        .contentShape(Rectangle())
                        .onTapGesture { avviaChiusura() }
                    finestra(k: k, schermo: g.size)
                }
            }
        }
        .ignoresSafeArea()
        .task { await apri() }
        .onDisappear { ascolto.chiudi() }               // comunque si chiuda, la musica si ferma
    }

    // MARK: - Apertura e chiusura

    private func apri() async {
        Suoni.tocco()
        Suoni.chatCarica()
        // finita l'apertura il contenuto è stampato: il suono del caricamento sfuma e l'orologio si ferma
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(durataApre * 1000) + 20))
            if case .apre(_) = fase {
                fase = .aperta
                Suoni.chatPronta()
            }
        }
        if let r = await seller.scheda(bersaglio.releaseID), !Task.isCancelled {
            if case .chiude(_) = fase { return }        // chiusa mentre arrivava la scheda: niente tracce caricate
            await ascolto.prepara(r)
        }
    }

    private func avviaChiusura() {
        if case .chiude(_) = fase { return }
        Suoni.tocco()
        Suoni.chatPronta()
        ascolto.chiudi()
        fase = .chiude(Date())
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(durataChiude * 1000) + 20))
            chiudi()
        }
    }

    // MARK: - La finestra

    @ViewBuilder
    private func finestra(k: Double, schermo: CGSize) -> some View {
        let w = max(10, schermo.width - 28)
        let h = min(schermo.height * 0.8, 640)
        let a = morbido(k / 0.42)                          // la riga verde che si allarga
        let b = morbido((k - 0.38) / 0.62)                 // la finestra che si apre in altezza
        let centro = CGPoint(x: schermo.width / 2, y: schermo.height / 2)
        let dx = (bersaglio.origine.x - centro.x) * CGFloat(1 - a)
        let dy = (bersaglio.origine.y - centro.y) * CGFloat(1 - a)
        ZStack {
            contenuto(k: k)
                .frame(width: w, height: h)
                .background(Color(red: 6 / 255, green: 12 / 255, blue: 8 / 255).opacity(0.97))
                .overlay { righeScansione }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.glow.opacity(0.6), lineWidth: 1))
                .shadow(color: Theme.glow.opacity(0.18), radius: 15)
                .mask {
                    Rectangle().frame(width: max(2, w * CGFloat(a)), height: max(2, h * CGFloat(b)))
                }
            // la riga verde dell'apertura (si spegne mentre la finestra si apre)
            Capsule().fill(Theme.glow)
                .frame(width: max(2, w * CGFloat(a)), height: 2)
                .shadow(color: Theme.glow, radius: 6)
                .opacity(1 - b)
                .allowsHitTesting(false)
        }
        .offset(x: dx, y: dy)
    }

    /// Le righe sottili da schermo HUD sopra la finestra.
    private var righeScansione: some View {
        Canvas { gc, size in
            var y = 0.0
            var p = Path()
            while y < size.height {
                p.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                y += 3
            }
            gc.fill(p, with: .color(Theme.glow.opacity(0.035)))
        }
        .allowsHitTesting(false)
    }

    /// Ogni blocco si stampa un po' dopo il precedente.
    private func visibile(_ k: Double, _ i: Int) -> Double {
        min(1, max(0, (k - 0.55 - Double(i) * 0.05) / 0.2))
    }

    private func contenuto(k: Double) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("ASCOLTO")
                    .font(Theme.mono(11, .bold)).tracking(2)
                    .foregroundStyle(Theme.glow)
                Spacer()
                Button("Chiudi") { avviaChiusura() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
            .opacity(min(1, max(0, (k - 0.45) / 0.2)))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    testa.opacity(visibile(k, 0))
                    tempo.opacity(visibile(k, 1))
                    comandi.opacity(visibile(k, 2))
                    tracce.opacity(visibile(k, 3))
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
            }
        }
    }

    // MARK: - Il lettore

    @ViewBuilder private var testa: some View {
        if ascolto.fonte == .video, let id = ascolto.videoID {
            VideoYouTube(videoID: id, ascolto: ascolto)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.glow.opacity(0.4), lineWidth: 1))
                .id(id)
        } else {
            HStack(spacing: 14) {
                DiscoAscolto(copertina: ascolto.copertina, gira: ascolto.suona)
                    .frame(width: 118, height: 118)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ascolto.corrente?.titolo ?? (ascolto.cercando ? "Cerco le tracce…" : "Nessuna traccia"))
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(bersaglio.titolo)
                        .font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                    Text(Ascolto.scritta(ascolto.fonteMostrata))
                        .font(Theme.mono(9, .bold)).tracking(1.5).foregroundStyle(Theme.glow).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var tempo: some View {
        VStack(spacing: 4) {
            GeometryReader { g in
                let f = ascolto.durata > 0 ? min(1, max(0, ascolto.tempo / ascolto.durata)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.glow.opacity(0.15))
                    Capsule().fill(Theme.glow)
                        .frame(width: g.size.width * CGFloat(f))
                        .shadow(color: Theme.glow.opacity(0.8), radius: 4)
                }
            }
            .frame(height: 4)
            HStack {
                Text(LettoreGrande.mmss(ascolto.tempo))
                Spacer()
                Text(LettoreGrande.mmss(ascolto.durata))
            }
            .font(Theme.mono(10)).foregroundStyle(Theme.muted).monospacedDigit()
        }
    }

    private var comandi: some View {
        HStack(spacing: 30) {
            Button { Suoni.tocco(); ascolto.indietro() } label: {
                Image(systemName: "backward.end.fill").font(.system(size: 22)).foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(ascolto.brani.isEmpty)
            .accessibilityLabel("Brano precedente")
            Button { ascolto.playPausa() } label: {
                Image(systemName: ascolto.suona ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(Color.black)
                    .frame(width: 62, height: 62)
                    .background(Theme.accent, in: Circle())
                    .shadow(color: Theme.accent.opacity(0.45), radius: 8)
            }
            .buttonStyle(.plain)
            .disabled(ascolto.corrente == nil)
            .accessibilityLabel(ascolto.suona ? "Pausa" : "Riproduci")
            Button { Suoni.tocco(); ascolto.avanti() } label: {
                Image(systemName: "forward.end.fill").font(.system(size: 22)).foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(ascolto.brani.isEmpty)
            .accessibilityLabel("Brano successivo")
        }
        .frame(maxWidth: .infinity)
    }

    /// Le tracce divise per lato (LATO A, LATO B…), con la fonte di ogni brano.
    private var tracce: some View {
        VStack(alignment: .leading, spacing: 0) {
            if ascolto.brani.isEmpty {
                Text(ascolto.cercando ? "Cerco le tracce…" : "Discogs non ha la tracklist di questo disco.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
                    .padding(14)
            }
            ForEach(ascolto.brani) { b in
                let nuovoLato = b.id == 0 || ascolto.brani[b.id - 1].lato != b.lato
                if nuovoLato && !b.lato.isEmpty {
                    Text("LATO \(b.lato)")
                        .font(Theme.mono(9, .bold)).tracking(2).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                }
                rigaBrano(b)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func rigaBrano(_ b: Ascolto.Brano) -> some View {
        let scelto = b.id == ascolto.indice
        let f = ascolto.fonteDi(b)
        return Button { Suoni.tocco(); ascolto.metti(b.id) } label: {
            HStack(spacing: 10) {
                Text(b.posizione)
                    .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    .frame(width: 26, alignment: .leading)
                Text(b.titolo)
                    .font(.system(size: 15)).foregroundStyle(scelto ? Theme.glow : Theme.text).lineLimit(1)
                Spacer(minLength: 4)
                Text(Ascolto.breve(f))
                    .font(Theme.mono(9, .bold)).tracking(1)
                    .foregroundStyle(f == .nessuna ? Theme.muted : Theme.glow)
                Text(b.durataTesto)
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(f == .nessuna && !ascolto.cercando)
        .opacity(f == .nessuna && !ascolto.cercando ? 0.45 : 1)
    }
}
