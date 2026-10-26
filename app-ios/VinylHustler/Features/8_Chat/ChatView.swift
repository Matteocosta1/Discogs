import AuthenticationServices
import SwiftData
import SwiftUI
import UIKit

/// V68 — CHAT (sesta icona, dopo Ordini), come nel mock-up approvato:
/// in alto «CHAT · N» e INVITA; cerca per nome Discogs (Aggiungi / Scrivi); elenco delle chat con
/// CONTATTO / RICHIESTA e i non letti. Nella chat: testo e schede disco (Proponi / Parere),
/// risposte con un tocco (Alza · Giusto · Abbassa, Mi interessa), Segnala e Blocca nel tasto ⋯.
struct ChatView: View {
    @Environment(Seller.self) private var seller
    private var store: ChatStore { ChatStore.shared }
    @State private var cerca = ""
    @State private var trovati: [UtenteChat] = []
    @State private var aperta: UUID?
    @Environment(\.sezioneVisibile) private var visibile

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(store.conversazioni.isEmpty ? "CHAT" : "CHAT · \(store.conversazioni.count)")
                        .font(Theme.mono(10, .bold)).tracking(2).foregroundStyle(Theme.glow)
                    Spacer()
                    ShareLink(item: "Ciao! Uso Vinyl Hustler per vendere dischi su Discogs. Scaricala e cercami nella Chat: sono \(seller.username).") {
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
                        Text("Il nome \(seller.username) è già usato da un altro account: gli altri non ti trovano.")
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
            if v { store.riparti(nome: seller.username) }      // aprendo la Chat si rilegge subito
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
            AccessoApple { store.riparti(nome: seller.username) }
            Spacer()
        }
        .padding(.top, 10)
    }

    private func anteprima(_ m: MsgChat) -> String {
        let mio = m.da == store.io ? "Tu: " : ""
        if let d = m.disco { return mio + (m.tipo == "parere" ? "Parere · " : "Proposta · ") + d.titolo }
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
                Button { Suoni.tocco(); scegliDisco = true } label: {
                    Image(systemName: "record.circle").font(.system(size: 20)).foregroundStyle(Theme.glow)
                        .frame(width: 42, height: 42)
                        .overlay(Circle().stroke(Theme.glow.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Manda un disco")
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
        .sheet(isPresented: $scegliDisco) {
            SceltaDisco { disco, tipo in
                Task { _ = await store.manda(a: altro, disco: disco, tipo: tipo) }
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
        if let d = m.disco {
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
                        case "Abbassa": frase = "Io lo abbasserei (\(titolo))"
                        default: frase = "Mi interessa \(titolo), a quanto me lo fai?"
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

/// La scheda di un disco dentro la chat. Chi la riceve risponde con un tocco.
struct CartaDisco: View {
    let m: MsgChat
    let d: DiscoChat
    let mia: Bool
    let risposta: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(m.tipo == "parere" ? "PARERE SUL PREZZO" : "PROPOSTA")
                .font(Theme.mono(9, .bold)).tracking(1.5).foregroundStyle(Theme.glow)
            HStack(spacing: 10) {
                AsyncImage(url: d.copertina.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Theme.panelHigh }
                    .frame(width: 48, height: 48).clipShape(Circle())
                    .overlay(Circle().stroke(Theme.glow.opacity(0.5), lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.titolo).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("\(d.cond) · \(d.posto)").font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(soldiIT(d.prezzo, d.valuta)).font(.system(size: 16, weight: .heavy)).foregroundStyle(Theme.money)
                    .lineLimit(1).fixedSize()
            }
            if !mia {
                let scelte = m.tipo == "parere" ? ["Alza", "Giusto", "Abbassa"] : ["Mi interessa"]
                HStack(spacing: 6) {
                    ForEach(scelte, id: \.self) { s in
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
            } else if let r = m.risposta {
                Text("RISPOSTA · \(r.uppercased())").font(Theme.mono(9, .bold)).tracking(1.2).foregroundStyle(Theme.glow)
            }
            Text(ChatData.ora(m.creato)).font(Theme.mono(8.5)).tracking(1).foregroundStyle(Theme.muted)
        }
        .padding(10)
        .frame(maxWidth: 290)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(mia ? Theme.glow.opacity(0.45) : Color.white.opacity(0.14), lineWidth: 1))
    }
}

/// Il disco da mandare (quelli messi in vendita o in bozza con l'app), poi Proponi o Parere.
struct SceltaDisco: View {
    let manda: (DiscoChat, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(Seller.self) private var seller
    @Query(sort: \Disc.createdAt, order: .reverse) private var tutti: [Disc]
    @State private var scelto: Disc?

    private var dischi: [Disc] {
        tutti.filter { ($0.status == .inVendita || $0.status == .bozza) && !$0.releaseTitle.isEmpty }
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
                LazyVStack(spacing: 8) {
                    if dischi.isEmpty {
                        Text("Nessun disco in vendita o in bozza fatto con l\u{2019}app.")
                            .font(.system(size: 14)).foregroundStyle(Theme.muted).padding(.top, 20)
                    }
                    ForEach(dischi) { d in
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
                }
            }
            HStack(spacing: 8) {
                Button("Proponi") { invia("proposta") }.buttonStyle(PillolaChat(piena: false, alta: true))
                Button("Parere") { invia("parere") }.buttonStyle(PillolaChat(piena: false, alta: true))
            }
            .disabled(scelto == nil)
            .opacity(scelto == nil ? 0.35 : 1)
        }
        .padding(18)
        .background(Color(red: 0.043, green: 0.059, blue: 0.047))
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }

    private func invia(_ tipo: String) {
        guard let d = scelto else { return }
        Suoni.schedaApre()
        manda(DiscoChat(titolo: d.releaseTitle, cond: d.gradeText, posto: d.box, prezzo: d.price ?? 0,
                        valuta: seller.currency, copertina: d.coverURL?.absoluteString), tipo)
        dismiss()
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
    /// Oggi l'ora, altrimenti il giorno.
    static func breve(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? ora(d) : d.formatted(.dateTime.day().month(.abbreviated))
    }
}
