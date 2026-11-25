import AVFoundation
import SwiftUI
import QuartzCore
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
                        // V84: For Sale prende il posto di «Compra su Discogs»: apre COPIE, tutte le copie in vendita dentro l'app
                        Button { Suoni.tocco(); copie = true } label: {
                            tastoBordo(prezzi.prezzo(id).map { "For Sale · \($0.inVendita)" } ?? "For Sale", acceso: false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Apre tutte le copie in vendita")
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
            // V84: le voci di Discogs; For Sale ora è il tasto sotto, accanto ad Ascolta
            numero("FROM", p?.da.map { soldiIT($0, p?.valuta ?? seller.currency) } ?? (p == nil ? "…" : "—"), Theme.money)
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
    /// V85: Digging continua da solo con le pagine dopo (tutte le uscite, non solo quelle già lette).
    @State private var voci: [VoceCerca]
    let totale: Int?
    let sorgente: SorgenteDigging?
    @State private var rifornisco = false
    @State private var fermo = false                // la pagina dopo non è arrivata (rete): la fila finisce qui
    @Environment(Seller.self) private var seller
    @Environment(\.dismiss) private var dismiss
    /// Il disco fermo al centro: quello che suona (cambia quando una copertina si ferma, non mentre scorrono).
    @State private var pos = 0
    @State private var scheda: VoceCerca?
    // V86 · il Cover Flow (come la tab PAGINE di JARVIS): `off` è la copertina al centro (anche a metà fra due)
    @State private var off: Double = 0
    @State private var corsa: CorsaFlusso?
    @State private var off0: Double = 0
    @State private var asse: AsseDito = .nessuno
    @State private var cartaSu: Int?
    @State private var alzata: CGFloat = 0
    @State private var vola: Int?
    /// V87 · giù sulla copertina al centro: la finestra ASCOLTO con le tracce del disco.
    @State private var tracce: BersaglioAscolto?
    @State private var leggo = true
    /// V90 · C «Cinema»: la traccia è un video e la copertina è ferma al centro: si allarga a tutta larghezza in 16:9.
    @State private var cinema = false
    private let ascolto = Ascolto.shared
    private let carrello = Carrello.shared
    private let prezzi = PrezziCerca.shared

    init(voci: [VoceCerca], totale: Int? = nil, sorgente: SorgenteDigging? = nil) {
        _voci = State(initialValue: voci)
        self.totale = totale
        self.sorgente = sorgente
    }

    /// Quanti in tutto: quelli detti da Discogs, mai meno di quelli già in fila.
    private var quanti: Int { max(totale ?? voci.count, voci.count) }
    private var finiti: Bool { !rifornisco && (fermo || (sorgente?.finita ?? true)) }
    /// Cambia quando cambia il disco davanti (anche se arriva dopo, a fine fila).
    private var discoDavanti: Int { pos < voci.count ? voci[pos].id : 0 }

    private enum AsseDito { case nessuno, lato, su, giu, nulla }

    /// V90 · Il video YouTube della traccia sta sulla copertina al centro (non mentre è aperta la finestra delle tracce,
    /// che ha il suo lettore: due lettori insieme suonerebbero due volte).
    private var videoMostrato: Bool {
        tracce == nil && ascolto.fonte == .video && ascolto.videoID != nil && pos < voci.count && ascolto.releaseID == voci[pos].id
    }
    /// Il cinema si apre quando la copertina col video è ferma al centro; scorrendo si richiude.
    private var cinemaAperto: Bool { videoMostrato && corsa == nil && asse != .lato && abs(off - Double(pos)) < 0.02 }

    /// Il viaggio verso una copertina (inerzia del dito, un tocco di lato, ✕, il carrello): rallenta arrivando.
    private struct CorsaFlusso: Equatable {
        let id = UUID()
        let da: Double, a: Double
        let inizio: Date
        let durata: Double
        func off(_ t: Date) -> Double {
            let u = min(1, max(0, t.timeIntervalSince(inizio) / durata))
            return da + (a - da) * (1 - pow(1 - u, 3))
        }
    }

    private func offAdesso(_ t: Date) -> Double { corsa?.off(t) ?? off }
    private func indice(_ o: Double) -> Int { min(max(0, Int(o.rounded())), max(0, voci.count - 1)) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120, paused: corsa == nil)) { tl in
            let o = offAdesso(tl.date)
            let k = indice(o)
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Text("DIGGING").font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow)
                    Text(voci.isEmpty ? "" : "\(RigaCerca.numero(k + 1)) / \(RigaCerca.numero(quanti))").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Chiudi") { Suoni.testa(); ascolto.chiudi(); dismiss() }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                if !voci.isEmpty {
                    flusso(o)
                    info(voci[k])
                    brano
                    comandi
                    Text(videoMostrato ? "Scorri le copertine. Sul video: pausa; il nome apre la scheda; su: nel carrello; giù: le tracce."
                                       : "Scorri le copertine. Tocca quella al centro per la scheda; su: nel carrello; giù: le tracce.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                } else if !finiti {
                    Spacer()
                    ProgressView().tint(Theme.accent)
                    Spacer()
                } else {
                    Spacer()
                    Text("FINITI").font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow)
                    Text("Hai sfogliato tutti i dischi").font(.system(size: 15)).foregroundStyle(Theme.muted)
                    Spacer()
                }
            }
            // lo scatto quando una copertina passa al centro (col dito o mentre corre)
            .onChange(of: k) { _, _ in if asse == .lato || corsa != nil { Suoni.tocco() } }
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 16)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            Suoni.chatCarica()
            try? await Task.sleep(for: .milliseconds(500))
            Suoni.chatPronta()
        }
        .task(id: discoDavanti) { await suonaDisco() }
        .task(id: discoDavanti) {
            // il prezzo solo della copertina ferma al centro: scorrendo non parte una richiesta per ogni disco
            guard pos < voci.count else { return }
            await prezzi.carica(voci[pos].id, client: seller.client, valuta: seller.currency)
        }
        .task(id: pos) { await rifornisci() }
        .onDisappear { if tracce == nil { ascolto.chiudi() } }           // V87: con le tracce aperte sopra la musica continua
        .onChange(of: cinemaAperto) { _, v in withAnimation(.easeInOut(duration: 0.4)) { cinema = v } }
        .onChange(of: tracce == nil) { _, chiusa in
            // V90: chiusa la finestra delle tracce, se la traccia scelta è un video riparte qui, sulla copertina
            guard chiusa, ascolto.fonte == .nessuna, let b = ascolto.corrente, ascolto.fonteDi(b) == .video,
                  pos < voci.count, ascolto.releaseID == voci[pos].id else { return }
            ascolto.metti(ascolto.indice)
        }
        .sheet(item: $scheda) { v in SchedaCerca(voce: v).environment(seller) }
        .finestraAscolto($tracce, seller: seller)
    }

    // MARK: Cover Flow

    /// Il lato della copertina al centro e dove sta, nello spazio che c'è.
    private static func misure(_ W: Double, _ H: Double) -> (cw: Double, top: Double) {
        let cw = max(120, min(W * 0.6, H - 34, 330))
        return (cw, max(4, (H - 30 - cw) / 2))
    }

    /// Le copertine a dischi: quella al centro guarda te, le altre ai lati girate di 62° e impilate, più scure; sotto la riga
    /// di luce verde e il riflesso, come il Cover Flow di Apple.
    private func flusso(_ o: Double) -> some View {
        GeometryReader { g in
            let W = Double(g.size.width), H = Double(g.size.height)
            let (cw, top) = Self.misure(W, H)
            let fuori = g.frame(in: .global)
            let centroCopertina = CGPoint(x: fuori.minX + W / 2, y: fuori.minY + top + cw / 2)
            // V90 · C: il cinema a tutta larghezza, 16:9, mai meno di 200 di altezza (il minimo del lettore di YouTube)
            let wv = W - 36, hv = min(H - 34, max(200, wv * 9 / 16))
            let wc = cinema ? wv : cw, hc = cinema ? hv : cw
            let zonaVideo: CGRect? = videoMostrato ? CGRect(x: W / 2 - wc / 2, y: top + (cw - hc) / 2, width: wc, height: hc) : nil
            ZStack(alignment: .topLeading) {
                LinearGradient(stops: [.init(color: Theme.glow.opacity(0), location: 0), .init(color: Theme.glow.opacity(0.75), location: 0.3),
                                       .init(color: Theme.glow.opacity(0.75), location: 0.7), .init(color: Theme.glow.opacity(0), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: max(0, W - 36), height: 1)
                    .shadow(color: Theme.glow, radius: 3)
                    .offset(x: 18, y: top + cw + 6)
                    .zIndex(300)
                    .allowsHitTesting(false)
                ForEach(Array(voci.enumerated()), id: \.element.id) { i, v in
                    let d = Double(i) - o, ad = abs(d)
                    if ad <= 3.6 {
                        let su = cartaSu == i ? alzata : 0
                        let u = min(1, max(0, Double(-su) / (cw * 1.1)))
                        let alCentro = i == pos, video = alCentro && videoMostrato
                        let w = alCentro ? wc : cw, h = alCentro ? hc : cw
                        let scosta = cinema && !alCentro ? (d < 0 ? -1.0 : 1.0) * cw * 0.9 : 0  // C: le altre si fanno da parte
                        copertina(v, w: w, h: h, scuro: 0.45 * min(1, ad), video: video)
                            .modifier(FlussoCoverFlow(d: d, cw: cw))
                            .scaleEffect(CGFloat(vola == i ? 0.82 : 1 - 0.18 * u))
                            .offset(y: vola == i ? CGFloat(-cw * 1.4) : su)
                            .opacity(vola == i ? 0 : (ad > 3.2 ? 0 : min(1, 3.6 - ad)) * (1 - 0.75 * u) * (cinema && !alCentro ? 0.3 : 1))
                            .offset(x: W / 2 - w / 2 + scosta, y: top + (cw - h) / 2)
                            .zIndex(200 - (ad * 10).rounded())
                            .allowsHitTesting(video)                                 // sul video i tocchi sono del lettore di YouTube
                    }
                }
            }
            .frame(width: W, height: H, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { segue($0, W: W, cw: cw, zonaVideo: zonaVideo) }
                    .onEnded { fine($0, W: W, cw: cw, origine: centroCopertina, zonaVideo: zonaVideo) }
            )
        }
        .padding(.horizontal, -18)                                         // le copertine di lato arrivano ai bordi dello schermo
        .clipped()
    }

    private func copertina(_ v: VoceCerca, w: Double, h: Double, scuro: Double, video: Bool) -> some View {
        let forma = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let foto = AsyncImage(url: v.copertina ?? v.miniatura) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
        return foto
            .frame(width: w, height: h)
            .overlay {
                // V90 · il lettore ufficiale di YouTube al posto della copertina (si vede tutto, niente sopra)
                if video, let id = ascolto.videoID {
                    VideoYouTube(videoID: id, ascolto: ascolto).id(id)
                }
            }
            .overlay(Color.black.opacity(scuro).allowsHitTesting(false))
            .clipShape(forma)
            .shadow(color: .black.opacity(0.65), radius: 18, y: 9)
            // il riflesso sotto, che sfuma (si gira con la copertina)
            .overlay(alignment: .top) {
                foto
                    .frame(width: w, height: h)
                    .overlay(Color.black.opacity(video ? 1 : scuro))
                    .clipShape(forma)
                    .scaleEffect(x: 1, y: -1)
                    .mask(LinearGradient(stops: [.init(color: .black.opacity(0.22), location: 0), .init(color: .clear, location: 0.28)],
                                         startPoint: .top, endPoint: .bottom))
                    .offset(y: h + 3)
                    .allowsHitTesting(false)
            }
    }

    /// La copertina sotto il dito (la più davanti fra quelle che lo contengono), con la stessa prospettiva.
    private func cartaSotto(_ x: Double, W: Double, cw: Double) -> Int? {
        let o = offAdesso(Date())
        var meglio: (i: Int, z: Double)?
        let P = cw * 2.3
        for i in voci.indices {
            let d = Double(i) - o, ad = abs(d)
            guard ad <= 3.2 else { continue }
            let a = min(1, ad), sg: Double = d < 0 ? -1 : (d > 0 ? 1 : 0)
            let px = sg * (a * cw * 0.64 + max(0, ad - 1) * cw * 0.26), z = -(a * 0.34 + max(0, ad - 1) * 0.06) * cw
            let k = P / (P - z), centro = W / 2 + px * k, mezzo = cw / 2 * cos(a * 62 * .pi / 180) * k
            if abs(x - centro) <= max(6, mezzo), meglio.map({ 200 - ad * 10 > $0.z }) ?? true { meglio = (i, 200 - ad * 10) }
        }
        return meglio?.i
    }

    private func segue(_ v: DragGesture.Value, W: Double, cw: Double, zonaVideo: CGRect?) {
        guard vola == nil, !voci.isEmpty else { return }
        let dx = Double(v.translation.width), dy = Double(v.translation.height)
        if asse == .nessuno {
            guard hypot(dx, dy) >= 6 else { return }
            off = offAdesso(Date())
            corsa = nil
            off0 = off
            // V90 · nel cinema la copertina al centro è larga quanto lo schermo
            let carta = zonaVideo?.contains(v.startLocation) == true ? Optional(pos) : cartaSotto(Double(v.startLocation.x), W: W, cw: cw)
            let alCentro = carta != nil && carta == indice(off)
            asse = abs(dx) >= abs(dy) ? .lato : (alCentro ? (dy < 0 ? .su : .giu) : .nulla)
            cartaSu = asse == .su || asse == .giu ? carta : nil
        }
        switch asse {
        case .lato:
            // V88: un disco alla volta («tac, tac, tac»): il dito sposta al massimo di una copertina, qualunque sia la spinta
            let n = Double(voci.count - 1), k0 = off0.rounded()
            let o = min(k0 + 1, max(k0 - 1, off0 - dx / (cw * 0.32)))
            off = o < 0 ? o * 0.35 : (o > n ? n + (o - n) * 0.35 : o)          // ai capi si allunga appena e torna
        case .su:
            alzata = CGFloat(min(0, dy))
        case .giu:
            alzata = CGFloat(max(0, dy) * 0.45)                                // V87: scende poco, con resistenza
        default:
            break
        }
    }

    private func fine(_ v: DragGesture.Value, W: Double, cw: Double, origine: CGPoint, zonaVideo: CGRect?) {
        defer { asse = .nessuno }
        guard vola == nil, !voci.isEmpty else { return }
        switch asse {
        case .lato:
            // V88: sempre una copertina alla volta: conta solo il verso del dito, non la velocità né la forza
            let k0 = Int(off0.rounded()), dx = Double(v.translation.width), vx = Double(v.velocity.width)
            let colpo = abs(dx) > 10 && abs(vx) > 300                            // un colpetto breve vale come uno lungo
            if dx < -cw * 0.12 || (colpo && vx < 0) { vaiA(k0 + 1) }
            else if dx > cw * 0.12 || (colpo && vx > 0) { vaiA(k0 - 1) }
            else { vaiA(k0) }
        case .su:
            if -Double(v.translation.height) > cw * 0.45 || v.velocity.height < -500 {
                nelCarrello()
            } else {
                withAnimation(.spring(duration: 0.26, bounce: 0.35)) { alzata = 0 }
                Task { @MainActor in try? await Task.sleep(for: .milliseconds(270)); if alzata == 0 { cartaSu = nil } }
            }
        case .giu:
            // V87: giù sulla copertina al centro: la finestra ASCOLTO con le tracce; la traccia scelta continua in Digging
            let apre = Double(alzata) > cw * 0.1
            withAnimation(.spring(duration: 0.26, bounce: 0.35)) { alzata = 0 }
            Task { @MainActor in try? await Task.sleep(for: .milliseconds(270)); if alzata == 0 { cartaSu = nil } }
            let k = indice(offAdesso(Date()))
            if apre, voci.indices.contains(k) {
                apriFinestraAscolto(BersaglioAscolto(releaseID: voci[k].id, titolo: voci[k].nome, origine: origine, continua: true), in: $tracce)
            }
        case .nulla:
            break
        case .nessuno:
            // un tocco: di lato la porta al centro, al centro apre la scheda (V90: sul video lo comanda YouTube)
            if zonaVideo?.contains(v.startLocation) == true { return }
            guard let i = cartaSotto(Double(v.startLocation.x), W: W, cw: cw), voci.indices.contains(i) else { return }
            if i != indice(offAdesso(Date())) { Suoni.tocco(); vaiA(i) }
            else { Suoni.tocco(); scheda = voci[i] }
        }
    }

    /// Porta la copertina `k` al centro; quando si ferma, suona.
    private func vaiA(_ k: Int) {
        guard !voci.isEmpty else { return }
        let a = Double(min(max(0, k), voci.count - 1))
        let da = offAdesso(Date())
        let c = CorsaFlusso(da: da, a: a, inizio: Date(), durata: min(0.7, 0.26 + abs(a - da) * 0.07))
        corsa = c
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(c.durata))
            guard corsa?.id == c.id else { return }
            off = c.a
            corsa = nil
            pos = Int(c.a)
        }
    }

    /// Nel carrello (il tasto o la copertina tirata su): sale e sparisce, poi passa alla prossima.
    private func nelCarrello() {
        let k = indice(offAdesso(Date()))
        guard voci.indices.contains(k) else { return }
        let v = voci[k]
        if !carrello.contiene(v.id) {
            carrello.metti(v, prezzo: prezzi.prezzo(v.id), valuta: seller.currency)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        Suoni.tocco()
        cartaSu = k
        withAnimation(.timingCurve(0.4, 0, 0.6, 1, duration: 0.28)) { vola = k }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { vola = nil; alzata = 0; cartaSu = nil }
            if k < voci.count - 1 { vaiA(k + 1) }
        }
    }

    /// ✕: la prossima.
    private func salta() {
        Suoni.tocco()
        let k = indice(offAdesso(Date()))
        if k < voci.count - 1 { vaiA(k + 1) }
    }

    private func info(_ v: VoceCerca) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(v.nome).font(.system(size: 20, weight: .bold)).lineLimit(1)
                .onTapGesture { if videoMostrato { Suoni.tocco(); scheda = v } }      // V90: col video la scheda si apre dal nome
            Text(v.meta).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
            let p = prezzi.prezzo(v.id)
            (Text(PrezziCerca.testo(p)).foregroundColor(Theme.money).fontWeight(.bold)
                + Text((p.map { $0.da == nil ? "" : " · \($0.inVendita) in vendita" } ?? "") + (carrello.contiene(v.id) ? " · nel carrello" : "")))
                .font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            tondo("xmark", "Salta") { salta() }
            Button { Suoni.tocco(); ascolto.playPausa() } label: {
                Image(systemName: ascolto.suona ? "pause.fill" : "play.fill").font(.system(size: 24, weight: .bold)).foregroundStyle(Color.black)
                    .frame(width: 68, height: 68).background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ascolto.suona ? "Pausa" : "Riproduci")
            tondo("cart.badge.plus", "Nel carrello") { nelCarrello() }
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

    /// Quando mancano pochi dischi alla fine della fila, legge la pagina dopo.
    private func rifornisci() async {
        guard pos >= voci.count - 3, !rifornisco, let s = sorgente, !s.finita else { return }
        rifornisco = true
        defer { rifornisco = false }
        let nuove = await s.altre(dopo: voci)
        if nuove.isEmpty && !s.finita { fermo = true }
        voci += nuove
    }

    /// La prima traccia che si può ascoltare parte da sola.
    private func suonaDisco() async {
        guard pos < voci.count else { ascolto.chiudi(); return }
        let id = voci[pos].id
        leggo = true
        defer { leggo = false }
        guard let r = await seller.scheda(id), !Task.isCancelled else { return }
        await seller.preparaAscolto(r)                  // V90 · B: se la stampa è muta, le tracce della principale
        guard !Task.isCancelled, ascolto.releaseID == id else { return }
        if let i = ascolto.brani.firstIndex(where: { ascolto.fonteDi($0) != .nessuna }) { ascolto.metti(i) }
    }
}


/// V86 · Il Cover Flow di Digging (come la tab PAGINE di JARVIS): la copertina `d` posti dal centro si sposta di lato, va
/// indietro e gira di 62° attorno al suo asse, con la prospettiva centrata sulla copertina.
private struct FlussoCoverFlow: GeometryEffect {
    let d: Double
    let cw: Double

    var animatableData: EmptyAnimatableData {
        get { EmptyAnimatableData() }
        set {}
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let ad = abs(d), a = min(1, ad), sg: Double = d < 0 ? -1 : (d > 0 ? 1 : 0)
        let x = sg * (a * cw * 0.64 + max(0, ad - 1) * cw * 0.26)
        let rot = -sg * a * 62 * .pi / 180
        let z = -(a * 0.34 + max(0, ad - 1) * 0.06) * cw
        let mx = Double(size.width) / 2, my = Double(size.height) / 2
        var m = CATransform3DMakeTranslation(-mx, -my, 0)
        m = CATransform3DConcat(m, CATransform3DMakeRotation(rot, 0, 1, 0))
        m = CATransform3DConcat(m, CATransform3DMakeTranslation(x, 0, z))
        var prospettiva = CATransform3DIdentity
        prospettiva.m34 = -1 / (cw * 2.3)
        m = CATransform3DConcat(m, prospettiva)
        m = CATransform3DConcat(m, CATransform3DMakeTranslation(mx, my, 0))
        return ProjectionTransform(m)
    }
}
