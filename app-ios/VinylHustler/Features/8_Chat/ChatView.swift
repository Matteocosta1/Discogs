import AuthenticationServices
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// V68 — CHAT (sesta icona, dopo Ordini), come nel mock-up approvato:
/// in alto «CHAT · N» e INVITA; cerca per nome Discogs (Aggiungi / Scrivi); elenco delle chat con
/// CONTATTO / RICHIESTA e i non letti. Nella chat: testo e schede disco, Segnala e Blocca nel tasto ⋯.
/// V74: nome in Chat («Nome · account Discogs», chiesto la prima volta), tasto + con Foto · Galleria · Disco,
/// foto private a schermo intero (Segnala), schede Annuncio (Apri su Discogs) e Parere (Alza · Giusto · Abbassa).
struct ChatView: View {
    @Environment(Seller.self) private var seller
    private var store: ChatStore { ChatStore.shared }
    @State private var cerca = ""
    @State private var trovati: [UtenteChat] = []
    @State private var aperta: UUID?
    @State private var chiediNome = false
    @AppStorage("chatNomeConfermato") private var nomeConfermato = false
    @Environment(\.sezioneVisibile) private var visibile

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(store.conversazioni.isEmpty ? "CHAT" : "CHAT · \(store.conversazioni.count)")
                        .font(Theme.mono(10, .bold)).tracking(2).foregroundStyle(Theme.glow)
                    Spacer()
                    ShareLink(item: "Ciao! Uso Vinyl Hustler per vendere dischi su Discogs. Scaricala e cercami nella Chat: sono \(store.mioNome.isEmpty ? seller.username : store.mioNome).") {
                        Text("INVITA").font(Theme.mono(10, .bold)).tracking(1.5).foregroundStyle(Theme.glow)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.glow.opacity(0.5), lineWidth: 1))
                    }
                }
                .padding(.top, 14)
                if !store.accesso {
                    accedi
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                        TextField("Cerca per nome Discogs", text: $cerca)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(Color(red: 0.46, green: 0.46, blue: 0.5).opacity(0.24), in: RoundedRectangle(cornerRadius: 12))
                    if store.nomeOccupato {
                        Text("Il nome «\(ChatStore.nomeImpostato) · \(seller.username)» è già usato da un altro telefono: gli altri non ti trovano. Cambialo con «Nome» in Settings.")
                            .font(.system(size: 13)).foregroundStyle(Theme.warn)
                    }
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if cerca.trimmingCharacters(in: .whitespaces).count >= 2 { risultati } else { elenco }
                        }
                        .padding(.bottom, 20)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .padding(.horizontal, 16)

            if let aperta {
                ConversazioneView(altro: aperta) {
                    Suoni.testa()
                    withAnimation(.snappy(duration: 0.32)) { self.aperta = nil }
                }
                .transition(.move(edge: .trailing))
                .zIndex(1)
            }
        }
        .sfondoHUD()
        .task(id: cerca) {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            trovati = await store.cerca(cerca)
        }
        .onChange(of: visibile, initial: true) { _, v in
            store.visibile = v
            if v { store.riparti(discogs: seller.username) }   // aprendo la Chat si rilegge subito
            if v, store.accesso, !nomeConfermato { chiediNome = true }
        }
        .sheet(isPresented: $chiediNome, onDismiss: { nomeConfermato = true }) {
            NomeChat(discogs: seller.username) { store.riparti(discogs: seller.username) }
        }
    }

    private func apri(_ id: UUID) {
        Suoni.tocco()
        cerca = ""
        withAnimation(.snappy(duration: 0.32)) { aperta = id }
    }

    @ViewBuilder private var elenco: some View {
        let lista = store.conversazioni
        if lista.isEmpty {
            Text("Nessuna chat. Cerca un utente per nome Discogs o mandagli un invito.")
                .font(.system(size: 14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).padding(.top, 30)
        }
        ForEach(lista) { c in
            Button { apri(c.id) } label: {
                RigaChat(nome: store.nome(c.id), sotto: anteprima(c.ultimo), ora: ChatData.breve(c.ultimo.creato),
                         tag: c.richiesta ? "RICHIESTA" : (store.contatti.contains(c.id) ? "CONTATTO" : nil),
                         nuovi: c.nonLetti)
            }
            .buttonStyle(.plain)
        }
        if let e = store.errore { Text(e).font(.system(size: 12)).foregroundStyle(Theme.warn) }
    }

    @ViewBuilder private var risultati: some View {
        Text("UTENTI DI VINYL HUSTLER · \(trovati.count)")
            .font(Theme.mono(9, .bold)).tracking(1.8).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        if trovati.isEmpty {
            Text("Nessuno con questo nome usa l\u{2019}app. Mandagli un invito.")
                .font(.system(size: 14)).foregroundStyle(Theme.muted).padding(.top, 20)
        }
        ForEach(trovati) { u in
            HStack(spacing: 12) {
                Avatar(nome: u.nome ?? "?")
                VStack(alignment: .leading, spacing: 3) {
                    Text(u.nome ?? "utente").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(store.contatti.contains(u.id) ? "Nei tuoi contatti" : "Usa Vinyl Hustler")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 4)
                if !store.contatti.contains(u.id) {
                    Button("Aggiungi") { Suoni.tocco(); Task { await store.aggiungi(u.id) } }
                        .buttonStyle(PillolaChat(piena: false))
                }
                Button("Scrivi") { apri(u.id) }.buttonStyle(PillolaChat(piena: true))
            }
            .padding(12)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var accedi: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("La chat passa dal server di Vinyl Hustler: accedi con Apple una volta sola.")
                .font(.system(size: 14)).foregroundStyle(Theme.muted)
            AccessoApple {
                store.riparti(discogs: seller.username)
                if !nomeConfermato { chiediNome = true }
            }
            Spacer()
        }
        .padding(.top, 10)
    }

    private func anteprima(_ m: MsgChat) -> String {
        let mio = m.da == store.io ? "Tu: " : ""
        if m.foto != nil { return mio + "Foto" }
        if let d = m.disco { return mio + (m.tipo == "parere" ? "Parere · " : "Annuncio · ") + d.titolo }
        return mio + (m.testo ?? "")
    }
}

// MARK: - La conversazione

struct ConversazioneView: View {
    let altro: UUID
    let chiudi: () -> Void
    private var store: ChatStore { ChatStore.shared }
    @State private var testo = ""
    @State private var invio = false
    @State private var scegliDisco = false
    @State private var menu = false
    @State private var segnalato = false
    @State private var allega = false
    @State private var dopoAllega: Allega?
    @State private var fotocamera = false
    @State private var galleria = false
    @State private var scelta: PhotosPickerItem?
    @State private var fotoAperta: MsgChat?
    @State private var invioFoto = false

    enum Allega { case foto, galleria, disco }

    private var bloccato: Bool { store.bloccati.contains(altro) }
    private var richiesta: Bool { store.conversazioni.first(where: { $0.id == altro })?.richiesta ?? false }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("Chiudi", action: chiudi)
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
                Avatar(nome: store.nome(altro))
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.nome(altro)).font(.system(size: 16, weight: .bold)).lineLimit(1)
                    Text(bloccato ? "BLOCCATO" : (richiesta ? "RICHIESTA · NON È TRA I CONTATTI"
                                                  : (store.contatti.contains(altro) ? "CONTATTO" : "USA VINYL HUSTLER")))
                        .font(Theme.mono(9)).tracking(1.5).foregroundStyle(Theme.glow).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { Suoni.tocco(); menu = true } label: {
                    Text("⋯").font(.system(size: 18)).foregroundStyle(Theme.glow)
                        .frame(width: 38, height: 38)
                        .overlay(Circle().stroke(Theme.glow.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Segnala o blocca")
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)

            if bloccato || richiesta { avviso.padding(.horizontal, 14).padding(.bottom, 8) }

            ScrollViewReader { lettore in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.messaggi(con: altro)) { m in riga(m).id(m.id) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { if let u = store.messaggi(con: altro).last { lettore.scrollTo(u.id, anchor: .bottom) } }
                .onChange(of: store.messaggi(con: altro).count) { _, _ in
                    if let u = store.messaggi(con: altro).last {
                        withAnimation(.easeOut(duration: 0.25)) { lettore.scrollTo(u.id, anchor: .bottom) }
                    }
                    Task { await store.segnaLetti(altro) }
                }
            }

            if let e = store.errore { Text(e).font(.system(size: 12)).foregroundStyle(Theme.warn).padding(.horizontal, 14) }

            HStack(spacing: 8) {
                Button { Suoni.tocco(); allega = true } label: {
                    ZStack {
                        if invioFoto { ProgressView().tint(Theme.glow) }
                        else { Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.glow) }
                    }
                    .frame(width: 42, height: 42)
                    .overlay(Circle().stroke(Theme.glow.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(invioFoto)
                .accessibilityLabel("Allega una foto o un disco")
                TextField("Scrivi", text: $testo)
                    .font(.system(size: 16))
                    .padding(.horizontal, 14).frame(height: 42)
                    .background(Theme.panelHigh, in: Capsule())
                    .submitLabel(.send)
                    .onSubmit(invia)
                Button(action: invia) {
                    Text("Invia").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.black)
                        .padding(.horizontal, 16).frame(height: 42)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(invio || testo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(bloccato || richiesta)
            .opacity(bloccato || richiesta ? 0.35 : 1)
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(Theme.bg)
        .task { await store.segnaLetti(altro) }
        .sheet(isPresented: $allega, onDismiss: {
            // una sola schermata alla volta: quella scelta si apre quando ALLEGA è chiuso
            switch dopoAllega {
            case .foto: fotocamera = true
            case .galleria: galleria = true
            case .disco: scegliDisco = true
            case nil: break
            }
            dopoAllega = nil
        }) {
            AllegaChat { dopoAllega = $0; allega = false }
        }
        .sheet(isPresented: $scegliDisco) {
            SceltaDisco { disco, tipo in
                Task { _ = await store.manda(a: altro, disco: disco, tipo: tipo) }
            }
        }
        .fullScreenCover(isPresented: $fotocamera) {
            ScattoChat { img in
                fotocamera = false
                if let img { mandaFoto(img) }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $galleria, selection: $scelta, matching: .images)
        .onChange(of: scelta) { _, nuovo in
            guard let nuovo else { return }
            scelta = nil
            Task {
                if let dati = try? await nuovo.loadTransferable(type: Data.self), let img = UIImage(data: dati) { mandaFoto(img) }
            }
        }
        .fullScreenCover(item: $fotoAperta) { m in
            VistaFotoChat(m: m, mia: m.da == store.io) {
                Task { segnalato = await store.segnala(altro, messaggio: m.id) }
            }
        }
        .confirmationDialog(store.nome(altro), isPresented: $menu, titleVisibility: .visible) {
            Button("Segnala") { Task { segnalato = await store.segnala(altro) } }
            if bloccato {
                Button("Sblocca") { Task { await store.sblocca(altro) } }
            } else {
                Button("Blocca", role: .destructive) { Suoni.svuota(); Task { await store.blocca(altro) } }
            }
        }
        .alert("Segnalazione inviata", isPresented: $segnalato) {} message: {
            Text("La controlliamo entro 24 ore; se serve l\u{2019}utente viene bloccato per tutti.")
        }
    }

    @ViewBuilder private var avviso: some View {
        VStack(alignment: .leading, spacing: 8) {
            if bloccato {
                Text("Hai bloccato questo utente: non può scriverti.").font(.system(size: 13))
                Button("Sblocca") { Suoni.tocco(); Task { await store.sblocca(altro) } }.buttonStyle(PillolaChat(piena: false))
            } else {
                Text("Non è tra i tuoi contatti. Accetti la chat?").font(.system(size: 13))
                HStack(spacing: 8) {
                    Button("Accetta") { Suoni.fatto(); Task { await store.aggiungi(altro) } }.buttonStyle(PillolaChat(piena: true))
                    Button("Blocca") { Suoni.svuota(); Task { await store.blocca(altro) } }.buttonStyle(PillolaChat(piena: false, rossa: true))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(hex: 0xFFD60A).opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: 0xFFD60A).opacity(0.45), lineWidth: 1))
    }

    @ViewBuilder private func riga(_ m: MsgChat) -> some View {
        let mia = m.da == store.io
        if m.foto != nil {
            HStack {
                if mia { Spacer(minLength: 50) }
                FotoBolla(m: m, mia: mia) { Suoni.tocco(); fotoAperta = m }
                if !mia { Spacer(minLength: 50) }
            }
        } else if let d = m.disco {
            HStack {
                if mia { Spacer(minLength: 50) }
                CartaDisco(m: m, d: d, mia: mia) { valore in
                    Suoni.tocco()
                    Task {
                        await store.rispondi(m, valore)
                        let titolo = d.titolo.components(separatedBy: " - ").last ?? d.titolo
                        let frase: String
                        switch valore {
                        case "Giusto": frase = "Prezzo giusto per \(titolo)"
                        case "Alza": frase = "Io lo alzerei (\(titolo))"
                        default: frase = "Io lo abbasserei (\(titolo))"
                        }
                        _ = await store.manda(a: altro, testo: frase)
                    }
                }
                if !mia { Spacer(minLength: 50) }
            }
        } else {
            HStack {
                if mia { Spacer(minLength: 50) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.testo ?? "").font(.system(size: 14))
                        .foregroundStyle(mia ? Color(red: 0.92, green: 1, blue: 0.92) : Theme.text)
                        .textSelection(.enabled)
                    Text(ChatData.ora(m.creato)).font(Theme.mono(8.5)).tracking(1).foregroundStyle(mia ? Theme.glow : Theme.muted)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(mia ? Theme.military : Theme.panelHigh,
                            in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: mia ? 16 : 5,
                                                       bottomTrailingRadius: mia ? 5 : 16, topTrailingRadius: 16))
                if !mia { Spacer(minLength: 50) }
            }
        }
    }

    private func mandaFoto(_ img: UIImage) {
        guard !invioFoto else { return }
        invioFoto = true
        Suoni.schedaApre()
        Task {
            if !(await store.mandaFoto(a: altro, immagine: img)) { Suoni.nego() }
            invioFoto = false
        }
    }

    private func invia() {
        let t = testo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !invio else { return }
        invio = true
        Suoni.tocco()
        Task {
            if await store.manda(a: altro, testo: t) { testo = "" } else { Suoni.nego() }
            invio = false
        }
    }
}

/// La scheda di un disco dentro la chat. V74: i dati di Discogs (copertina, prezzo, stato dell'annuncio) non stanno
/// nel messaggio: si rileggono da Discogs quando la scheda si vede (al massimo ogni 10 minuti, mai più vecchi di
/// 6 ore come chiedono le regole delle API), con la fonte «Data provided by Discogs».
struct CartaDisco: View {
    let m: MsgChat
    let d: DiscoChat
    let mia: Bool
    let risposta: (String) -> Void
    @Environment(Seller.self) private var seller
    @Environment(\.openURL) private var apriLink
    @State private var dati: DatiDiscogs?

    struct DatiDiscogs {
        var copertina: String?
        var prezzo: Double?
        var valuta: String?
        var inVendita = true
        var quando = Date()
    }
    /// Dati già letti (per annuncio o disco), validi 10 minuti.
    private static var letti: [String: DatiDiscogs] = [:]

    private var annuncio: Bool { m.tipo == "annuncio" || m.tipo == "proposta" }
    private var paginaDisco: URL? {
        if let l = d.listing { return URL(string: "https://www.discogs.com/sell/item/\(l)") }
        if let r = d.release { return URL(string: "https://www.discogs.com/release/\(r)") }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(m.tipo == "parere" ? "PARERE SUL PREZZO" + (d.stato == "bozza" ? " · BOZZA" : "") : "ANNUNCIO SU DISCOGS")
                .font(Theme.mono(9, .bold)).tracking(1.5).foregroundStyle(Theme.glow)
            HStack(spacing: 10) {
                AsyncImage(url: (dati?.copertina ?? d.copertina).flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                    .frame(width: 48, height: 48).clipShape(Circle())
                    .overlay(Circle().stroke(Theme.glow.opacity(0.5), lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.titolo).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("\(d.cond) · \(d.posto)").font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(soldiIT(dati?.prezzo ?? d.prezzo, dati?.valuta ?? d.valuta)).font(.system(size: 16, weight: .heavy)).foregroundStyle(Theme.money)
                    .lineLimit(1).fixedSize()
            }
            if annuncio, d.listing != nil {
                if dati?.inVendita == false {
                    Text("NON PIÙ IN VENDITA").font(Theme.mono(9, .bold)).tracking(1.2).foregroundStyle(Theme.warn)
                }
                Button {
                    Suoni.tocco()
                    if let u = paginaDisco { apriLink(u) }
                } label: {
                    Text("Apri su Discogs").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity).frame(height: 32)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            if m.tipo == "parere" && !mia {
                HStack(spacing: 6) {
                    ForEach(["Alza", "Giusto", "Abbassa"], id: \.self) { s in
                        Button { if m.risposta == nil { risposta(s) } } label: {
                            Text(s).font(.system(size: 13, weight: .bold))
                                .foregroundStyle(m.risposta == s ? Color.black : Theme.glow)
                                .frame(maxWidth: .infinity).frame(height: 32)
                                .background(m.risposta == s ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.glow.opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(m.risposta != nil && m.risposta != s)
                    }
                }
            } else if mia, let r = m.risposta {
                Text("RISPOSTA · \(r.uppercased())").font(Theme.mono(9, .bold)).tracking(1.2).foregroundStyle(Theme.glow)
            }
            if let u = paginaDisco {
                Button { Suoni.tocco(); apriLink(u) } label: {
                    Text("Data provided by Discogs").font(Theme.mono(8.5)).tracking(1).underline().foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            }
            Text(ChatData.ora(m.creato)).font(Theme.mono(8.5)).tracking(1).foregroundStyle(Theme.muted)
        }
        .padding(10)
        .frame(maxWidth: 290)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(mia ? Theme.glow.opacity(0.45) : Color.white.opacity(0.14), lineWidth: 1))
        .task(id: m.id) { await aggiorna() }
    }

    /// Rilegge da Discogs: l'annuncio (prezzo, copertina, se è ancora in vendita) o il disco (copertina).
    private func aggiorna() async {
        let chiave: String
        if let l = d.listing { chiave = "l\(l)" } else if let r = d.release { chiave = "r\(r)" } else { return }
        if let g = Self.letti[chiave], Date().timeIntervalSince(g.quando) < 600 { dati = g; return }
        var nuovi = DatiDiscogs()
        if let l = d.listing, let a = try? await seller.client.listing(l) {
            nuovi.copertina = a.release.thumbnail
            nuovi.prezzo = a.price?.value
            nuovi.valuta = a.price?.currency
            nuovi.inVendita = a.status == "For Sale"
        } else if let r = d.release, let rel = try? await seller.client.release(r) {
            nuovi.copertina = rel.images?.first(where: { $0.type == "primary" })?.uri150 ?? rel.images?.first?.uri150
        } else {
            return
        }
        Self.letti[chiave] = nuovi
        dati = nuovi
    }
}

/// Il disco da mandare. Annuncio: solo i dischi in vendita su Discogs (si apre l'annuncio vero). Parere: anche le bozze.
struct SceltaDisco: View {
    let manda: (DiscoChat, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(Seller.self) private var seller
    @Query(sort: \Disc.createdAt, order: .reverse) private var tutti: [Disc]
    @State private var scelto: Disc?

    private var inVendita: [Disc] {
        tutti.filter { $0.status == .inVendita && $0.listingID != nil && !$0.releaseTitle.isEmpty }
    }
    private var bozze: [Disc] {
        tutti.filter { $0.status == .bozza && !$0.releaseTitle.isEmpty }
    }
    private var sceltoInVendita: Bool { scelto.map { $0.status == .inVendita && $0.listingID != nil } ?? false }
    private var nota: String {
        guard let scelto else { return "Annuncio: solo i dischi in vendita su Discogs. Parere: anche le bozze." }
        return scelto.status == .bozza ? "È una bozza: si può chiedere solo un parere sul prezzo."
                                       : "Annuncio apre l\u{2019}annuncio vero su Discogs. Parere chiede cosa ne pensa del prezzo."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DISCO").font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow)
                Spacer()
                Button("Chiudi") { Suoni.testa(); dismiss() }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if inVendita.isEmpty && bozze.isEmpty {
                        Text("Nessun disco in vendita o in bozza fatto con l\u{2019}app.")
                            .font(.system(size: 14)).foregroundStyle(Theme.muted).padding(.top, 20)
                    }
                    if !inVendita.isEmpty { sezione("IN VENDITA · \(inVendita.count)") }
                    ForEach(inVendita) { rigaDisco($0) }
                    if !bozze.isEmpty { sezione("BOZZE · \(bozze.count)") }
                    ForEach(bozze) { rigaDisco($0) }
                }
            }
            Text(nota).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(minHeight: 16, alignment: .topLeading)
            HStack(spacing: 8) {
                Button("Annuncio") { invia("annuncio") }.buttonStyle(PillolaChat(piena: false, alta: true))
                    .disabled(!sceltoInVendita).opacity(sceltoInVendita ? 1 : 0.35)
                Button("Parere") { invia("parere") }.buttonStyle(PillolaChat(piena: false, alta: true))
                    .disabled(scelto == nil).opacity(scelto == nil ? 0.35 : 1)
            }
        }
        .padding(18)
        .background(Color(red: 0.043, green: 0.059, blue: 0.047))
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }

    private func sezione(_ t: String) -> some View {
        Text(t).font(Theme.mono(10, .bold)).tracking(1.8).foregroundStyle(Theme.glow).padding(.top, 4).padding(.leading, 2)
    }

    private func rigaDisco(_ d: Disc) -> some View {
        Button { Suoni.tocco(); scelto = d } label: {
            HStack(spacing: 12) {
                AsyncImage(url: d.coverURL) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                    .frame(width: 40, height: 40).clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.releaseTitle).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("\(d.gradeText) · \(d.box)").font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let p = d.price { Text(soldiIT(p, seller.currency)).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.money) }
            }
            .padding(10)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(scelto?.id == d.id ? Theme.accent : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private func invia(_ tipo: String) {
        guard let d = scelto else { return }
        if tipo == "annuncio" && !sceltoInVendita { return }
        Suoni.schedaApre()
        // solo i dati nostri (titolo, grado, posizione, prezzo) e i numeri di Discogs: copertina e prezzo
        // aggiornati si rileggono da Discogs quando la scheda si vede
        manda(DiscoChat(titolo: d.releaseTitle, cond: d.gradeText, posto: d.box, prezzo: d.price ?? 0,
                        valuta: seller.currency, copertina: nil,
                        listing: tipo == "annuncio" ? d.listingID : nil, release: d.releaseID,
                        stato: d.status == .bozza ? "bozza" : "vendita"), tipo)
        dismiss()
    }
}

/// V74: il tasto + della chat.
struct AllegaChat: View {
    let scegli: (ConversazioneView.Allega) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ALLEGA").font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow)
                Spacer()
                Button("Chiudi") { Suoni.testa(); dismiss() }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            voce("Foto", "camera") { scegli(.foto) }
            voce("Galleria", "photo.on.rectangle") { scegli(.galleria) }
            voce("Disco", "record.circle") { scegli(.disco) }
            Text("Le foto le vede solo chi è in questa chat e si cancellano da sole dopo \(FotoChat.giorni) giorni.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(Color(red: 0.043, green: 0.059, blue: 0.047))
        .preferredColorScheme(.dark)
        .presentationDetents([.height(340)])
    }

    private func voce(_ t: String, _ icona: String, _ fai: @escaping () -> Void) -> some View {
        Button { Suoni.tocco(); fai() } label: {
            HStack(spacing: 12) {
                Image(systemName: icona).font(.system(size: 18)).foregroundStyle(Theme.glow).frame(width: 24)
                Text(t).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 50)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.glow.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// V74: il nome in Chat, chiesto la prima volta che si apre la Chat (è il «Nome» di Settings).
struct NomeChat: View {
    let discogs: String
    let salvato: () -> Void
    @AppStorage("userName") private var nomeUtente = ""
    @AppStorage("chatNomeConfermato") private var confermato = false
    @Environment(\.dismiss) private var dismiss
    @State private var nome = ""

    private var pulito: String { nome.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("NOME").font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow)
                Spacer()
                Button("Chiudi") { Suoni.testa(); confermato = true; dismiss() }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            Text("Gli altri utenti ti trovano e ti vedono così. Si cambia anche da Settings.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            TextField("Il tuo nome", text: $nome)
                .font(.system(size: 16))
                .padding(.horizontal, 14).frame(height: 46)
                .background(Theme.panelHigh, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.glow.opacity(0.4), lineWidth: 1))
                .submitLabel(.done)
                .onSubmit(salva)
                .onChange(of: nome) { _, v in if v.count > 24 { nome = String(v.prefix(24)) } }
            Text("\(pulito.isEmpty ? "…" : pulito) · \(discogs)")
                .font(Theme.mono(13)).tracking(0.5).foregroundStyle(Theme.glow)
            Button("Salva", action: salva).buttonStyle(PillolaChat(piena: true, alta: true))
                .disabled(pulito.count < 2).opacity(pulito.count < 2 ? 0.35 : 1)
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(Color(red: 0.043, green: 0.059, blue: 0.047))
        .preferredColorScheme(.dark)
        .presentationDetents([.height(330)])
        .onAppear { nome = nomeUtente }
    }

    private func salva() {
        guard pulito.count >= 2 else { return }
        Suoni.fatto()
        nomeUtente = pulito
        confermato = true
        salvato()
        dismiss()
    }
}

/// V74: una foto nella chat (si apre a schermo intero con un tocco).
struct FotoBolla: View {
    let m: MsgChat
    let mia: Bool
    let apri: () -> Void
    @State private var img: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if FotoChat.scaduta(m) {
                    Text("Foto scaduta").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .frame(width: 200, height: 80)
                } else if let img {
                    Image(uiImage: img).resizable().scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onTapGesture(perform: apri)
                } else {
                    ProgressView().tint(Theme.glow).frame(width: 200, height: 200)
                }
            }
            Text(ChatData.ora(m.creato)).font(Theme.mono(8.5)).tracking(1).foregroundStyle(mia ? Theme.glow : Theme.muted)
                .padding(.horizontal, 6).padding(.bottom, 2)
        }
        .padding(4)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(mia ? Theme.glow.opacity(0.35) : Color.white.opacity(0.14), lineWidth: 1))
        .task(id: m.id) {
            if let p = m.foto, !FotoChat.scaduta(m) { img = await FotoChat.immagine(p) }
        }
    }
}

/// V74: la foto a schermo intero. Chiudi; sulle foto degli altri anche Segnala.
struct VistaFotoChat: View {
    let m: MsgChat
    let mia: Bool
    let segnala: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var img: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Chiudi") { Suoni.testa(); dismiss() }
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
                Spacer()
                if !mia {
                    Button { Suoni.fatto(); segnala(); dismiss() } label: {
                        Text("Segnala").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.warn)
                            .padding(.horizontal, 14).frame(height: 34)
                            .overlay(Capsule().stroke(Theme.warn.opacity(0.55), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Spacer(minLength: 0)
            if let img {
                Image(uiImage: img).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 10)
            } else {
                ProgressView().tint(Theme.glow)
            }
            Spacer(minLength: 0)
            Text("SI CANCELLA TRA \(FotoChat.giorniRimasti(m)) GIORNI")
                .font(Theme.mono(9)).tracking(1.5).foregroundStyle(Theme.muted)
                .padding(.bottom, 22)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { if let p = m.foto { img = await FotoChat.immagine(p) } }
    }
}

/// V74: la fotocamera per mandare una foto in chat (quella di sistema).
struct ScattoChat: UIViewControllerRepresentable {
    let fatto: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(fatto: fatto) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let fatto: (UIImage?) -> Void
        init(fatto: @escaping (UIImage?) -> Void) { self.fatto = fatto }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            fatto(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { fatto(nil) }
    }
}

// MARK: - Pezzi

struct RigaChat: View {
    let nome: String
    let sotto: String
    let ora: String
    let tag: String?
    let nuovi: Int

    var body: some View {
        HStack(spacing: 12) {
            Avatar(nome: nome)
            VStack(alignment: .leading, spacing: 3) {
                Text(nome).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(sotto).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 5) {
                Text(ora).font(.system(size: 11)).foregroundStyle(Theme.muted)
                if let tag {
                    Text(tag).font(Theme.mono(8.5, .bold)).tracking(1.2)
                        .foregroundStyle(tag == "RICHIESTA" ? Color(hex: 0xFFD60A) : Theme.glow)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke((tag == "RICHIESTA" ? Color(hex: 0xFFD60A) : Theme.glow).opacity(0.5), lineWidth: 1))
                }
                if nuovi > 0 {
                    Text("\(nuovi)").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.black)
                        .frame(minWidth: 20, minHeight: 20).padding(.horizontal, 2)
                        .background(Theme.accent, in: Capsule())
                }
            }
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(nuovi > 0 ? Theme.glow.opacity(0.45) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

struct Avatar: View {
    let nome: String
    var body: some View {
        Text(String(nome.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased())
            .font(Theme.mono(13, .bold)).foregroundStyle(Theme.glow)
            .frame(width: 42, height: 42)
            .background(Theme.military, in: Circle())
            .overlay(Circle().stroke(Theme.glow.opacity(0.45), lineWidth: 1))
    }
}

struct PillolaChat: ButtonStyle {
    var piena: Bool
    var rossa = false
    var alta = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: alta ? 15 : 13, weight: .bold))
            .foregroundStyle(piena ? Color.black : (rossa ? Theme.warn : Theme.accent))
            .padding(.horizontal, 12)
            .frame(maxWidth: alta ? .infinity : nil).frame(height: alta ? 44 : 32)
            .background(piena ? Theme.accent : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(rossa ? Theme.warn.opacity(0.6) : Theme.accent, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Accesso con Apple (serve al server della chat), come in Settings.
struct AccessoApple: View {
    let fatto: () -> Void
    @State private var nonce = ""
    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            nonce = UUID().uuidString
            request.requestedScopes = [.fullName]
            request.nonce = Backend.sha256(nonce)
        } onCompletion: { result in
            guard case .success(let auth) = result,
                  let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let data = cred.identityToken, let token = String(data: data, encoding: .utf8) else { return }
            Task {
                try? await Backend.shared.signInWithApple(idToken: token, nonce: nonce)
                if await Backend.shared.accessToken() != nil { fatto() }
            }
        }
        .signInWithAppleButtonStyle(.white)
        .frame(height: 44)
    }
}

enum ChatData {
    static func ora(_ d: Date) -> String { d.formatted(.dateTime.hour().minute()) }
    /// Data e ora per i filtri del server (es. «aggiornato dopo…»).
    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
    /// Oggi l'ora, altrimenti il giorno.
    static func breve(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? ora(d) : d.formatted(.dateTime.day().month(.abbreviated))
    }
}
