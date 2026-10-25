import SwiftUI
import UIKit

/// V60 — MESSAGGI: la conversazione dell'ordine, la stessa che c'è su Discogs.
/// Righe di Discogs (cambi di stato, spedizione) in grigio, l'acquirente a sinistra, io a destra in verde.
/// Quattro risposte pronte da un tocco. Non usa la fotocamera: si chiude con la scritta «Chiudi».
struct MessaggiSheet: View {
    let order: Order
    /// Chiamata quando la chat è stata aperta (i messaggi sono letti) e quando si chiude.
    let onLetti: () -> Void

    @Environment(Seller.self) private var seller
    @Environment(\.dismiss) private var dismiss
    @State private var messaggi: [OrderMessage] = []
    @State private var carico = true
    @State private var testo = ""
    @State private var invio = false
    @State private var errore: String?

    static let rapide = ["Grazie! Lo preparo oggi.", "Spedito, ecco il tracking.", "Mi confermi l\u{2019}indirizzo?", "Sì, parte entro venerdì."]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MESSAGGI · \(order.buyer.username.uppercased())")
                    .font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.glow).lineLimit(1)
                Spacer()
                Button("Chiudi") { Suoni.tocco(); dismiss() }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
            }

            ScrollViewReader { lettore in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if carico && messaggi.isEmpty {
                            ProgressView().tint(Theme.accent).padding(.top, 30)
                        } else if messaggi.isEmpty {
                            Text("Ancora nessun messaggio.").font(.system(size: 14)).foregroundStyle(Theme.muted).padding(.top, 30)
                        }
                        ForEach(Array(messaggi.enumerated()), id: \.offset) { i, m in
                            riga(m).id(i)
                        }
                    }
                    .padding(2)
                }
                .onChange(of: messaggi.count) { _, n in
                    if n > 0 { withAnimation(.easeOut(duration: 0.25)) { lettore.scrollTo(n - 1, anchor: .bottom) } }
                }
            }

            if let errore {
                Text(errore).font(.system(size: 13)).foregroundStyle(Theme.warn)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.rapide, id: \.self) { r in
                        Button { Suoni.tocco(); testo = r } label: {
                            Text(r).font(.system(size: 13)).foregroundStyle(Theme.glow)
                                .padding(.horizontal, 12).frame(height: 32)
                                .overlay(Capsule().stroke(Theme.glow.opacity(0.45), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Scrivi all'acquirente", text: $testo)
                    .font(.system(size: 16))
                    .padding(.horizontal, 12).frame(height: 42)
                    .background(Theme.panelHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .submitLabel(.send)
                    .onSubmit(invia)
                Button(action: invia) {
                    Group {
                        if invio { ProgressView().tint(.black) } else { Text("Invia").font(.system(size: 14, weight: .bold)) }
                    }
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 16).frame(height: 42)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(invio || testo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 20)
        .background(Color(red: 0.043, green: 0.059, blue: 0.047))
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .task { await carica() }
        .onDisappear { ChatOrdini.segnaLetta(order.id); onLetti() }
    }

    @ViewBuilder private func riga(_ m: OrderMessage) -> some View {
        let tipo = m.type ?? "message"
        let autore = (m.from?.username ?? "").lowercased()
        let quando = ChatOrdini.breve(m.timestamp)
        if tipo != "message" {
            // riga di Discogs: cambio di stato, spedizione, rimborso
            Text("DISCOGS · " + (m.message ?? m.subject ?? tipo).uppercased())
                .font(Theme.mono(9, .bold)).tracking(1.2).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center).lineLimit(3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        } else if autore == seller.username.lowercased() && !autore.isEmpty {
            bolla(m.message ?? "", sotto: quando + " · INVIATO SU DISCOGS", mia: true)
        } else {
            bolla(m.message ?? "", sotto: quando, mia: false)
        }
    }

    private func bolla(_ testo: String, sotto: String, mia: Bool) -> some View {
        HStack {
            if mia { Spacer(minLength: 50) }
            VStack(alignment: .leading, spacing: 4) {
                Text(testo).font(.system(size: 14)).foregroundStyle(mia ? Color(red: 0.92, green: 1, blue: 0.92) : Theme.text)
                    .textSelection(.enabled)
                Text(sotto).font(Theme.mono(8.5)).tracking(1).foregroundStyle(mia ? Theme.glow : Theme.muted)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(mia ? Theme.military : Theme.panelHigh,
                        in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: mia ? 16 : 5,
                                                   bottomTrailingRadius: mia ? 5 : 16, topTrailingRadius: 16))
            .overlay {
                if mia {
                    UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 5, topTrailingRadius: 16)
                        .stroke(Theme.glow.opacity(0.35), lineWidth: 1)
                }
            }
            if !mia { Spacer(minLength: 50) }
        }
    }

    private func carica() async {
        carico = true
        defer { carico = false }
        do {
            messaggi = try await seller.client.orderMessages(order.id)
            ChatOrdini.segnaLetta(order.id)
            onLetti()
        } catch {
            if error.isCancellation { return }
            errore = "Messaggi non letti: " + error.localizedDescription
        }
    }

    private func invia() {
        let t = testo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !invio else { return }
        invio = true
        errore = nil
        Suoni.tocco()
        let id = order.id
        let client = seller.client
        let io = seller.username
        Task { @MainActor in
            do {
                try await client.postOrderMessage(id, message: t)
                testo = ""
                // il messaggio compare subito; poi si rilegge la conversazione vera
                messaggi.append(OrderMessage(timestamp: ChatOrdini.adesso(), message: t, subject: nil, type: "message",
                                             from: MessageAuthor(username: io)))
                invio = false
                if let tutti = try? await client.orderMessages(id) { messaggi = tutti }
                ChatOrdini.segnaLetta(id)
            } catch {
                invio = false
                Suoni.nego()
                errore = "Non inviato: " + error.localizedDescription
            }
        }
    }
}

/// Quando è stata letta l'ultima volta la chat di ogni ordine (per il pallino rosso) e le date dei messaggi.
enum ChatOrdini {
    private static let chiave = "chatOrdiniLetta"

    static func letta(_ id: String) -> Date? {
        guard let d = UserDefaults.standard.dictionary(forKey: chiave) as? [String: Double], let s = d[id] else { return nil }
        return Date(timeIntervalSince1970: s)
    }

    static func segnaLetta(_ id: String) {
        var d = (UserDefaults.standard.dictionary(forKey: chiave) as? [String: Double]) ?? [:]
        d[id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(d, forKey: chiave)
    }

    /// I messaggi dell'acquirente arrivati dopo l'ultima lettura.
    static func nonLetti(_ messaggi: [OrderMessage], ordine: Order) -> Int {
        let soglia = letta(ordine.id) ?? .distantPast
        let lui = ordine.buyer.username.lowercased()
        return messaggi.filter { m in
            (m.type ?? "message") == "message"
                && (m.from?.username ?? "").lowercased() == lui
                && (data(m.timestamp) ?? .distantPast) > soglia
        }.count
    }

    static func data(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)
    }

    static func adesso() -> String { ISO8601DateFormatter().string(from: Date()) }

    /// "25 OTT 11:02"
    static func breve(_ iso: String?) -> String {
        guard let d = data(iso) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: d).uppercased().replacingOccurrences(of: ".", with: "")
    }
}
