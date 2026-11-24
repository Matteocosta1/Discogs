import AVFoundation
import SwiftUI
import UIKit

// V79 — Cerca › la scheda del disco, Scansiona e Scava (come nel mock-up approvato).

extension VoceCerca {
    /// «Artista - Titolo (etichetta, paese, anno)» del riconoscimento → senza la parentesi finale.
    static func dalRiconoscimento(_ c: Candidate) -> VoceCerca {
        let nome = c.title.replacingOccurrences(of: #"\s*\([^()]*\)\s*$"#, with: "", options: .regularExpression)
        return VoceCerca(id: c.id, nome: nome, miniatura: c.coverURL)
    }
}

/// La Wantlist toccata da qui (Discogs non dice in una richiesta sola se un disco è già nella Wantlist).
enum WantlistLocale {
    static let chiave = "wantlistV79"
    static func contiene(_ id: Int) -> Bool { (UserDefaults.standard.array(forKey: chiave) as? [Int] ?? []).contains(id) }
    static func segna(_ id: Int, _ si: Bool) {
        var l = UserDefaults.standard.array(forKey: chiave) as? [Int] ?? []
        l.removeAll { $0 == id }
        if si { l.append(id) }
        UserDefaults.standard.set(l, forKey: chiave)
    }
}

// MARK: - La scheda del disco

struct SchedaCerca: View {
    let voce: VoceCerca
    @Environment(Seller.self) private var seller
    @Environment(\.dismiss) private var dismiss
    @State private var attuale = 0                 // la stampa scelta (release id)
    @State private var release: Release?
    @State private var versioni: [MasterVersion] = []
    @State private var inWantlist = false
    @State private var lavoro = false
    @State private var ascolta: BersaglioAscolto?
    @State private var copie = false                // V83: COPIE · N, la pagina di Discogs con tutte le copie in vendita
    private let carrello = Carrello.shared
    private let prezzi = PrezziCerca.shared

    private var id: Int { attuale == 0 ? voce.id : attuale }
    private var copertina: URL? {
        let img = release?.sortedImages.first
        return (img?.uri ?? img?.uri150).flatMap(URL.init(string:)) ?? voce.copertina ?? voce.miniatura
    }
    private var artista: String {
        let a = release?.artist.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression) ?? ""
        return a.isEmpty ? voce.artista : a
    }
    private var titolo: String { release?.title ?? voce.album }
    private var meta: String {
        let anno = release?.year.map { String($0) } ?? voce.anno
        let riga1 = [anno, release?.country ?? voce.paese, release?.formats?.first.map { f in ([f.name ?? ""] + (f.descriptions ?? []).prefix(2)).filter { !$0.isEmpty }.joined(separator: ", ") } ?? voce.formato]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let riga2 = [release?.labels?.first?.name ?? voce.etichetta, voce.genere].filter { !$0.isEmpty }.joined(separator: " · ")
        return [riga1, riga2].filter { !$0.isEmpty }.joined(separator: "\n")
    }
    private var nome: String { artista.isEmpty ? titolo : "\(artista) – \(titolo)" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        AsyncImage(url: copertina) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                            .frame(width: 112, height: 112)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(artista).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted).lineLimit(1)
                            Text(titolo).font(.system(size: 20, weight: .bold)).lineLimit(3)
                            Text(meta).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                    numeri
                    HStack(spacing: 8) {
                        Button { mettiNelCarrello() } label: {
                            Text(carrello.contiene(id) ? "Nel carrello ✓" : "Aggiungi al carrello")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(carrello.contiene(id) ? Theme.money : Color.black)
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(carrello.contiene(id) ? Theme.military : Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        Button { Task { await wantlist() } } label: {
                            tastoBordo(inWantlist ? "In Wantlist ✓" : "Wantlist", acceso: inWantlist)
                        }
                        .buttonStyle(.plain)
                        .disabled(lavoro)
                    }
                    HStack(spacing: 8) {
                        GeometryReader { g in
                            Button {
                                let f = g.frame(in: .global)
                                apriFinestraAscolto(BersaglioAscolto(releaseID: id, titolo: nome, origine: CGPoint(x: f.midX, y: f.midY)), in: $ascolta)
                            } label: { tastoBordo("Ascolta", acceso: false) }
                            .buttonStyle(.plain)
                        }
                        .frame(height: 44)
                        if let url = URL(string: "https://www.discogs.com/sell/release/\(id)?ev=rb") {
                            Link(destination: url) { tastoBordo("Compra su Discogs", acceso: false) }
                                .simultaneousGesture(TapGesture().onEnded { Suoni.tocco() })
                        }
                    }
                    if !versioni.isEmpty {
                        Text("VERSIONI · \(versioni.count)").font(Theme.mono(10, .bold)).tracking(2).foregroundStyle(Theme.glow)
                            .padding(.top, 4)
                        VStack(spacing: 0) {
                            ForEach(Array(versioni.enumerated()), id: \.element.id) { coppia in
                                rigaVersione(coppia.element, ultima: coppia.offset == versioni.count - 1)
                            }
                        }
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    Text("Dati di Discogs. This application uses Discogs’ API but is not affiliated with, sponsored or endorsed by Discogs.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .sfondoHUD()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("DISCO").font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { Suoni.testa(); dismiss() }.foregroundStyle(Theme.accent)
                }
            }
            .task(id: id) { await carica() }
            .finestraAscolto($ascolta, seller: seller)
            .sheet(isPresented: $copie) {
                CopieView(releaseID: id, quante: prezzi.prezzo(id)?.inVendita, nome: nome)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var numeri: some View {
        let p = prezzi.prezzo(id)
        return HStack(spacing: 6) {
            // V83: le voci di Discogs («from», «For Sale»); FOR SALE apre COPIE: tutte le copie in vendita, dentro l'app
            numero("FROM", p?.da.map { soldiIT($0, p?.valuta ?? seller.currency) } ?? (p == nil ? "…" : "—"), Theme.money)
            Button { Suoni.tocco(); copie = true } label: {
                numero("FOR SALE ↗", p.map { "\($0.inVendita)" } ?? "…", Theme.text, titoloAcceso: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Apre tutte le copie in vendita")
            // V81: i termini di Discogs, nello stesso ordine della pagina del disco: Have, poi Want
            numero("HAVE", (release?.community?.have ?? voce.have).formatted(.number.locale(Locale(identifier: "it_IT"))), Theme.text)
            numero("WANT", (release?.community?.want ?? voce.want).formatted(.number.locale(Locale(identifier: "it_IT"))), Theme.text)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func numero(_ titolo: String, _ valore: String, _ colore: Color, titoloAcceso: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(titolo).font(Theme.mono(8.5, .bold)).tracking(1.1).foregroundStyle(titoloAcceso ? Theme.accent : Theme.muted)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(valore).font(.system(size: 15, weight: .bold)).foregroundStyle(colore).lineLimit(1).minimumScaleFactor(0.7)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tastoBordo(_ t: String, acceso: Bool) -> some View {
        Text(t).font(.system(size: 15, weight: .semibold))
            .foregroundStyle(acceso ? Theme.money : Theme.accent)
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(acceso ? Theme.military : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(acceso ? Color.clear : Theme.accent, lineWidth: 1.5))
            .contentShape(Rectangle())
    }

    private func rigaVersione(_ v: MasterVersion, ultima: Bool) -> some View {
        let scelta = v.id == id
        let p = prezzi.prezzo(v.id)
        let testo = [v.released ?? "", v.country ?? "", v.format ?? "", v.label ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return Button {
            guard !scelta else { return }
            Suoni.tocco()
            attuale = v.id
        } label: {
            HStack(spacing: 10) {
                if scelta { Circle().fill(Theme.glow).frame(width: 7, height: 7) }
                Text(testo).font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 6)
                Text(PrezziCerca.testo(p)).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.money).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(scelta ? Theme.glow.opacity(0.08) : Color.clear)
            .overlay(alignment: .bottom) { if !ultima { Rectangle().fill(Theme.line).frame(height: 0.5) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task { await prezzi.carica(v.id, client: seller.client, valuta: seller.currency) }
    }

    private func carica() async {
        inWantlist = WantlistLocale.contiene(id)
        async let p: Void = prezzi.carica(id, client: seller.client, valuta: seller.currency, bassa: false)
        release = await seller.scheda(id)
        await p
        if versioni.isEmpty, let m = release?.masterId ?? voce.masterID, m > 0,
           let v = try? await seller.client.masterVersions(m) {
            versioni = v
        }
    }

    private func mettiNelCarrello() {
        if carrello.contiene(id) { carrello.togli(id); Suoni.svuota(); return }
        let v = VoceCerca(id: id, nome: nome, miniatura: (release?.sortedImages.first?.uri150) ?? voce.miniatura?.absoluteString)
        carrello.metti(v, prezzo: prezzi.prezzo(id), valuta: seller.currency)
        Suoni.tocco()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func wantlist() async {
        lavoro = true
        defer { lavoro = false }
        let aggiungi = !inWantlist
        do {
            try await seller.client.wantlist(seller.username, releaseID: id, aggiungi: aggiungi)
            inWantlist = aggiungi
            WantlistLocale.segna(id, aggiungi)
            if aggiungi { Suoni.fatto(); UINotificationFeedbackGenerator().notificationOccurred(.success) } else { Suoni.svuota() }
        } catch {
            Suoni.nego()
        }
    }
}

// MARK: - Scansiona: fotografi un disco (anche in un negozio) e si apre la sua scheda con prezzo e copie su Discogs

struct ScansionaView: View {
    let trovato: (VoceCerca) -> Void
    @Environment(Seller.self) private var seller
    @Environment(\.dismiss) private var dismiss
    @State private var motore = MotoreOcchio()
    @State private var rec = RECVivo()
    @State private var pronto = false
    @State private var stato = "INQUADRA UN DISCO"
    @State private var lavoro = false
    @State private var preso = false
    @State private var lampo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("SCANSIONA").font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow)
                Spacer()
                Button { Suoni.testa(); motore.ferma(); dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.accent)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.45), in: Circle())
                        .overlay(Circle().stroke(Theme.accent.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Chiudi")
            }
            ZStack {
                Color.black
                AnteprimaOcchio(motore: motore, rec: rec).opacity(pronto ? 1 : 0)
                angoli.allowsHitTesting(false)
                Color.white.opacity(lampo ? 0.85 : 0).allowsHitTesting(false)
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(stato)
                .font(Theme.mono(11, .semibold)).tracking(2.5).foregroundStyle(Theme.accent)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.black.opacity(0.5), in: Capsule())
                .frame(maxWidth: .infinity)
            Button(action: scatta) {
                ZStack {
                    Circle().stroke(Theme.accent, lineWidth: 3).frame(width: 74, height: 74)
                    Circle().fill(Theme.accent).frame(width: 58, height: 58)
                    if lavoro { ProgressView().tint(.black) } else {
                        Image(systemName: "camera.fill").font(.system(size: 19, weight: .bold)).foregroundStyle(Color.black)
                    }
                }
                .shadow(color: Theme.accent.opacity(0.6), radius: 10)
            }
            .buttonStyle(.plain)
            .disabled(!pronto || lavoro)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Scatta una foto")
            Text("Anche in un negozio: fotografi la copertina e vedi subito prezzo e copie su Discogs.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.top, 18)
        .background(Color(red: 0.043, green: 0.059, blue: 0.047).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            guard await AVCaptureDevice.requestAccess(for: .video) else { stato = "ACCESSO NEGATO · IMPOSTAZIONI › FOTOCAMERA"; return }
            let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in motore.avvia { c.resume(returning: $0) } }
            pronto = ok
            if !ok { stato = "FOTOCAMERA NON DISPONIBILE" }
        }
        .onDisappear { motore.ferma() }
    }

    /// I quattro angoli verdi: tenui mentre cerca, accesi sulla copertina quando la trova («LOCK»).
    private var angoli: some View {
        GeometryReader { g in
            let lato = preso ? min(g.size.width, g.size.height) * 0.62 : min(g.size.width, g.size.height) * 0.78
            let r = CGRect(x: (g.size.width - lato) / 2, y: (g.size.height - lato) / 2, width: lato, height: lato)
            Path { p in
                let b: CGFloat = 24
                let vertici: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(r.minX, r.minY, 1, 1), (r.maxX, r.minY, -1, 1),
                                                                      (r.minX, r.maxY, 1, -1), (r.maxX, r.maxY, -1, -1)]
                for (x, y, sx, sy) in vertici {
                    p.move(to: CGPoint(x: x, y: y + sy * b)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x + sx * b, y: y))
                }
            }
            .stroke(Theme.glow.opacity(preso ? 1 : 0.45), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .shadow(color: Theme.glow.opacity(preso ? 0.8 : 0), radius: 6)
            .animation(.spring(duration: 0.35, bounce: 0.4), value: preso)
        }
    }

    private func scatta() {
        guard pronto, !lavoro else { return }
        Suoni.tocco()
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        withAnimation(.easeOut(duration: 0.06)) { lampo = true }
        withAnimation(.easeIn(duration: 0.45).delay(0.06)) { lampo = false }
        lavoro = true
        preso = false
        stato = "ANALISI"
        Suoni.schedaApre()
        motore.scatta { dati in
            DispatchQueue.global(qos: .userInitiated).async {
                let img = dati.flatMap { OcchioView.riduci($0) }.flatMap(UIImage.init(data:))
                Task { @MainActor in await riconosci(img) }
            }
        }
    }

    private func riconosci(_ img: UIImage?) async {
        guard let img else { lavoro = false; stato = "SCATTO NON RIUSCITO · RIPROVA"; Suoni.errore(); return }
        let conAI = await Backend.shared.accessToken() != nil
        let esito = await Recognizer(client: seller.client, ai: conAI ? AIService() : nil).scan([img], video: false)
        lavoro = false
        guard let c = esito.found.first?.candidates.first else {
            stato = "NON RICONOSCIUTO · RIPROVA"
            Suoni.errore()
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        let v = VoceCerca.dalRiconoscimento(c)
        preso = true
        stato = "● LOCK · " + (v.artista.isEmpty ? v.album : v.artista).uppercased()
        Suoni.schedaPronta()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        try? await Task.sleep(for: .milliseconds(900))
        motore.ferma()
        trovato(v)
    }
}

// MARK: - Scava: un disco alla volta, parte subito la prima traccia; a sinistra salti, a destra nel carrello

struct ScavaView: View {
    let voci: [VoceCerca]
    @Environment(Seller.self) private var seller
    @Environment(\.dismiss) private var dismiss
    @State private var pos = 0
    @State private var spinta: CGFloat = 0
    @State private var scheda: VoceCerca?
    @State private var leggo = true
    private let ascolto = Ascolto.shared
    private let carrello = Carrello.shared
    private let prezzi = PrezziCerca.shared

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("SCAVA").font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow)
                Text(pos < voci.count ? "\(pos + 1) / \(voci.count)" : "").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                Spacer()
                Button("Chiudi") { Suoni.testa(); ascolto.chiudi(); dismiss() }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            if pos < voci.count {
                carta(voci[pos])
                brano
                comandi
                Text("Scorri: a sinistra salti, a destra nel carrello. Tocca la copertina per la scheda.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            } else {
                Spacer()
                Text("FINITI").font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow)
                Text("Hai sfogliato tutti i dischi").font(.system(size: 15)).foregroundStyle(Theme.muted)
                Spacer()
            }
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 16)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            Suoni.chatCarica()
            try? await Task.sleep(for: .milliseconds(500))
            Suoni.chatPronta()
        }
        .task(id: pos) { await suonaDisco() }
        .onDisappear { ascolto.chiudi() }
        .sheet(item: $scheda) { v in SchedaCerca(voce: v).environment(seller) }
    }

    private func carta(_ v: VoceCerca) -> some View {
        GeometryReader { g in
            let lato = max(120, min(g.size.width, g.size.height - 96, 520))
            VStack(alignment: .leading, spacing: 8) {
                AsyncImage(url: v.copertina ?? v.miniatura) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                    .frame(width: lato, height: lato)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
                    .frame(maxWidth: .infinity)
                    .onTapGesture { Suoni.tocco(); scheda = v }
                Text(v.nome).font(.system(size: 20, weight: .bold)).lineLimit(1)
                Text(v.meta).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                let p = prezzi.prezzo(v.id)
                (Text(PrezziCerca.testo(p)).foregroundColor(Theme.money).fontWeight(.bold)
                    + Text((p.map { $0.da == nil ? "" : " · \($0.inVendita) in vendita" } ?? "") + (carrello.contiene(v.id) ? " · nel carrello" : "")))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .overlay(alignment: .topLeading) { etichetta("CARRELLO", Theme.glow).opacity(Double(max(0, spinta / 90))).padding(18) }
            .overlay(alignment: .topTrailing) { etichetta("SALTA", Theme.text).opacity(Double(max(0, -spinta / 90))).padding(18) }
            .offset(x: spinta)
            .rotationEffect(.degrees(Double(spinta / 22)))
            .gesture(DragGesture(minimumDistance: 8)
                .onChanged { spinta = $0.translation.width }
                .onEnded { e in
                    if e.translation.width > 90 { vai(tieni: true) }
                    else if e.translation.width < -90 { vai(tieni: false) }
                    else { withAnimation(.spring(duration: 0.3)) { spinta = 0 } }
                })
            .task { await prezzi.carica(v.id, client: seller.client, valuta: seller.currency) }
        }
    }

    private func etichetta(_ t: String, _ c: Color) -> some View {
        Text(t).font(Theme.mono(13, .bold)).tracking(2).foregroundStyle(c)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(c, lineWidth: 2))
    }

    private var brano: some View {
        VStack(spacing: 6) {
            HStack {
                Text(ascolto.corrente.map { "\($0.posizione) · \($0.titolo.uppercased())" } ?? (ascolto.cercando || leggo ? "CERCO LE TRACCE…" : "NESSUNA TRACCIA"))
                    .lineLimit(1)
                Spacer()
                if ascolto.durata > 0 { Text("\(LettoreGrande.mmss(ascolto.tempo)) / \(LettoreGrande.mmss(ascolto.durata))").monospacedDigit() }
            }
            .font(Theme.mono(11)).tracking(1).foregroundStyle(Theme.glow)
            GeometryReader { g in
                let f = ascolto.durata > 0 ? min(1, max(0, ascolto.tempo / ascolto.durata)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.glow.opacity(0.15))
                    Capsule().fill(Theme.glow).frame(width: g.size.width * CGFloat(f)).shadow(color: Theme.glow.opacity(0.8), radius: 4)
                }
            }
            .frame(height: 4)
        }
    }

    private var comandi: some View {
        HStack(spacing: 30) {
            tondo("xmark", "Salta") { vai(tieni: false) }
            Button { Suoni.tocco(); ascolto.playPausa() } label: {
                Image(systemName: ascolto.suona ? "pause.fill" : "play.fill").font(.system(size: 24, weight: .bold)).foregroundStyle(Color.black)
                    .frame(width: 68, height: 68).background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ascolto.suona ? "Pausa" : "Riproduci")
            tondo("cart.badge.plus", "Nel carrello") { vai(tieni: true) }
        }
    }

    private func tondo(_ simbolo: String, _ nome: String, _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            Image(systemName: simbolo).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 58, height: 58)
                .overlay(Circle().stroke(Theme.accent.opacity(0.45), lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(nome)
    }

    private func vai(tieni: Bool) {
        guard pos < voci.count else { return }
        let v = voci[pos]
        if tieni && !carrello.contiene(v.id) {
            carrello.metti(v, prezzo: prezzi.prezzo(v.id), valuta: seller.currency)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        Suoni.tocco()
        withAnimation(.easeIn(duration: 0.3)) { spinta = tieni ? 480 : -480 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { spinta = 0; pos += 1 }
        }
    }

    /// La prima traccia che si può ascoltare parte da sola.
    private func suonaDisco() async {
        guard pos < voci.count else { ascolto.chiudi(); return }
        let id = voci[pos].id
        leggo = true
        defer { leggo = false }
        guard let r = await seller.scheda(id), !Task.isCancelled else { return }
        await ascolto.prepara(r)
        guard !Task.isCancelled, ascolto.releaseID == id else { return }
        if let i = ascolto.brani.firstIndex(where: { ascolto.fonteDi($0) != .nessuna }) { ascolto.metti(i) }
    }
}
