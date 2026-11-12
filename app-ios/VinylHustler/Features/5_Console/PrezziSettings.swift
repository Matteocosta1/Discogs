import Foundation
import SwiftUI
import UIKit

/// V76 · Settings › Prezzi (come nel mockup approvato).
/// Richiesta: una tabella (Bassa, Media, Alta, Altissima) con i want «da – a» e i ricarichi Comune / Raro,
/// tutti modificabili; Mai sotto il suggerito, Griglia, Prezzo minimo, Ripristina; la (i) spiega tutto.
struct PrezziSettings: View {
    @Environment(Seller.self) private var seller
    @State private var info = false

    var body: some View {
        GruppoJarvis("Prezzi", info: { info = true }) {
            tabella
            RigaJarvis {
                Toggle("Mai sotto il suggerito", isOn: Binding(get: { seller.rules.maiSottoSuggerito },
                                                               set: { seller.rules.maiSottoSuggerito = $0; Suoni.tocco() }))
                    .tint(Theme.accent)
            }
            passo({ "Griglia: \($0.formatted()) €" }, \.step, 0.5...10)
            passo({ "Prezzo minimo: \($0.formatted()) €" }, \.minimum, 0.5...20)
            RigaJarvis(ultima: true) {
                Spacer()
                Button("Ripristina i valori di partenza") {
                    seller.rules = seller.rules.ripristinata()
                    Suoni.tocco()
                }
                .buttonStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                Spacer()
            }
        } piede: {
            Text("Parte dalla copia più economica in vendita su Discogs e aggiunge il ricarico della Richiesta (quante persone cercano il disco). Se nessuno lo vende parte dal suggerito, con il ricarico più alto. Tocca la (i) per tutti i dettagli.")
        }
        .sheet(isPresented: $info) { InfoPrezzi(rules: seller.rules) }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                // chiude la tastiera di qualunque campo (anche il Nome in Account)
                Button("Fine") {
                    _ = UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .tint(Theme.accent)
            }
        }
    }

    // MARK: - Richiesta (V76: in tabella, una riga per livello, i want «da – a» uno accanto all'altro)

    private var tabella: some View {
        RigaJarvis {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    testa("Richiesta").frame(maxWidth: .infinity, alignment: .leading)
                    testa("Want").frame(width: 98)
                    testa("Comune").frame(width: 62)
                    testa("Raro").frame(width: 62)
                }
                ForEach(0..<4, id: \.self) { k in riga(k) }
                Text("Comune: ci sono copie in vendita, ricarico sulla copia più economica. Raro: nessuno lo vende, ricarico sul suggerito.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
        }
    }

    private func testa(_ t: String) -> some View {
        Text(t.uppercased()).font(Theme.mono(9.5, .semibold)).tracking(0.5).foregroundStyle(Theme.muted)
            .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
    }

    private func riga(_ k: Int) -> some View {
        let nome = PriceRules.livelli[k]
        let liv = nome.lowercased()
        return HStack(spacing: 6) {
            Text(nome).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            want(k, liv).frame(width: 98)
            CampoNumero(valore: percento(\.ricarico, k), formato: { PriceEngine.pct(Decimal($0)) },
                        font: Theme.mono(13, .bold), etichetta: "Ricarico comune, richiesta \(liv)")
                .frame(width: 62)
            CampoNumero(valore: percento(\.ricaricoUnico, k), formato: { PriceEngine.pct(Decimal($0)) },
                        font: Theme.mono(13, .bold), etichetta: "Ricarico raro, richiesta \(liv)")
                .frame(width: 62)
        }
        .padding(.vertical, 2)
    }

    /// I want della riga, tutti da scrivere: «[0] – [50]», «[51] – [200]», «[201] – [1000]», «[1001] – [5000]».
    /// Le righe vicine restano allineate (il «da» di una riga è il «fino a» della precedente più uno).
    @ViewBuilder private func want(_ k: Int, _ liv: String) -> some View {
        HStack(spacing: 3) {
            if k == 0 {
                CampoNumero(valore: estremo(primo: true), formato: { String($0) }, font: Theme.mono(12, .semibold),
                            larghezza: 42, etichetta: "Want da, richiesta \(liv)")
            } else {
                campoWant(k - 1, piuUno: true, "Want da, richiesta \(liv)")
            }
            segno("–")
            if k == 3 {
                CampoNumero(valore: estremo(primo: false), formato: { String($0) }, font: Theme.mono(12, .semibold),
                            larghezza: 42, etichetta: "Want fino a, richiesta \(liv)")
            } else {
                campoWant(k, piuUno: false, "Want fino a, richiesta \(liv)")
            }
        }
    }

    /// Il primo numero della tabella (0) e l'ultimo (5000).
    private func estremo(primo: Bool) -> Binding<Int> {
        Binding(get: { primo ? seller.rules.wantDa : seller.rules.wantFino },
                set: { v in
                    if primo { seller.rules.wantDa = min(seller.rules.soglie[0] - 1, max(0, v)) }
                    else { seller.rules.wantFino = min(10_000_000, max(seller.rules.soglie[2] + 1, v)) }
                })
    }

    private func campoWant(_ j: Int, piuUno: Bool, _ etichetta: String) -> some View {
        CampoNumero(valore: soglia(j, piuUno: piuUno), formato: { String($0) }, font: Theme.mono(12, .semibold),
                    larghezza: 42, etichetta: etichetta)
    }

    private func segno(_ t: String) -> some View {
        Text(t).font(Theme.mono(12, .semibold)).foregroundStyle(Theme.muted)
    }

    /// Il confine j (i want «fino a» di Bassa, Media, Alta); con piùUno si legge e si scrive il «da» della casella dopo.
    private func soglia(_ j: Int, piuUno: Bool) -> Binding<Int> {
        Binding(get: { seller.rules.soglie[j] + (piuUno ? 1 : 0) },
                set: { v in
                    let s = seller.rules.soglie
                    let minimo = j > 0 ? s[j - 1] + 1 : seller.rules.wantDa + 1
                    let massimo = j < 2 ? s[j + 1] - 1 : seller.rules.wantFino - 1
                    seller.rules.soglie[j] = min(massimo, max(minimo, v - (piuUno ? 1 : 0)))
                })
    }

    private func percento(_ kp: WritableKeyPath<PriceRules, [Decimal]>, _ k: Int) -> Binding<Int> {
        Binding(get: { NSDecimalNumber(decimal: seller.rules[keyPath: kp][k]).intValue },
                set: { seller.rules[keyPath: kp][k] = Decimal(min(1000, max(-90, $0))) })
    }

    /// Griglia e minimo con − e +.
    private func passo(_ testo: @escaping (Decimal) -> String, _ kp: WritableKeyPath<PriceRules, Decimal>,
                       _ range: ClosedRange<Double>) -> some View {
        RigaJarvis {
            Stepper(value: Binding(get: { NSDecimalNumber(decimal: seller.rules[keyPath: kp]).doubleValue },
                                   set: { v in
                                       let d = Decimal(string: String(format: "%.2f", v)) ?? 0
                                       guard d != seller.rules[keyPath: kp] else { return }
                                       seller.rules[keyPath: kp] = d
                                       Suoni.tocco()
                                   }),
                    in: range, step: 0.5) {
                Text(testo(seller.rules[keyPath: kp]))
            }
        }
    }
}

/// Un numero da scrivere in una casella: mentre si scrive si vede il numero nudo, poi torna formattato
/// («+25%», «200»). Si conferma con Invio, «Fine» o toccando altrove.
private struct CampoNumero: View {
    @Binding var valore: Int
    let formato: (Int) -> String
    var font: Font
    var larghezza: CGFloat?
    var etichetta: String
    @State private var testo = ""
    @FocusState private var fuoco: Bool

    var body: some View {
        TextField("", text: $testo)
            .keyboardType(.numbersAndPunctuation)
            .submitLabel(.done)
            .multilineTextAlignment(.center)
            .font(font).monospacedDigit()
            .foregroundStyle(Theme.glow)
            .lineLimit(1)
            .padding(.vertical, 5)
            .padding(.horizontal, 2)
            .frame(width: larghezza)
            .frame(maxWidth: larghezza == nil ? .infinity : nil)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(fuoco ? Theme.glow : Color.white.opacity(0.14), lineWidth: 1))
            .focused($fuoco)
            .onAppear { testo = formato(valore) }
            .onChange(of: valore) { _, v in if !fuoco { testo = formato(v) } }
            .onChange(of: fuoco) { _, f in
                if f { testo = String(valore) } else { conferma() }
            }
            .onSubmit { fuoco = false }
            .accessibilityLabel(etichetta)
    }

    private func conferma() {
        let t = testo.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if let v = Double(t), v.isFinite {
            let n = Int(v.rounded())
            if n != valore {
                valore = n
                Suoni.tocco()
            }
        }
        testo = formato(valore)
    }
}

/// La (i) di Prezzi: la regola spiegata in parole semplici, con i numeri impostati in questo momento.
struct InfoPrezzi: View {
    let rules: PriceRules
    @Environment(\.dismiss) private var dismiss

    private var blocchi: [(String, [String])] {
        let l = PriceRules.livelli
        let liv = rules.livello(640)
        let es = PriceEngine.compute(suggested: 25, market: MarketData(want: 640, have: 100, numForSale: 4, lowestPrice: 32, lowestCurrency: "EUR"),
                                     grade: .m, currency: "EUR", rules: rules).price
        let esU = PriceEngine.compute(suggested: 25, market: MarketData(want: 640, have: 100, numForSale: 0, lowestPrice: nil, lowestCurrency: "EUR"),
                                      grade: .m, currency: "EUR", rules: rules).price
        let r = rules.ricarico.map { PriceEngine.pct($0) }
        let u = rules.ricaricoUnico.map { PriceEngine.pct($0) }
        return [
            ("Cos’è", ["Il prezzo che l’app propone per ogni disco, calcolato con i numeri di Discogs. Sulla scheda del disco lo puoi sempre cambiare a mano."]),
            ("Da dove parte", ["• Se qualcuno vende il disco su Discogs: dalla copia più economica in vendita.",
                               "• Se nessuno lo vende: dal prezzo suggerito da Discogs per il tuo grado (quanto si vende di solito)."]),
            ("Richiesta", ["I want sono le persone che hanno messo il disco nella loro lista dei desideri su Discogs: più sono, più il disco è cercato.",
                           "• \(l[0]): \(rules.fascia(0)) want", "• \(l[1]): \(rules.fascia(1)) want", "• \(l[2]): \(rules.fascia(2)) want",
                           "• \(l[3]): \(rules.fascia(3)) want",
                           "Sotto il primo numero conta come \(l[0]), oltre l’ultimo come \(l[3]). I want di ogni livello li cambi tu, toccando il numero."]),
            ("Ricarico", ["Ogni livello di Richiesta ha la sua percentuale, che si aggiunge al prezzo di partenza:",
                          "• Comune (copie in vendita, sulla più economica): \(l[0]) \(r[0]), \(l[1]) \(r[1]), \(l[2]) \(r[2]), \(l[3]) \(r[3])",
                          "• Raro (nessuno in vendita, sul suggerito): \(l[0]) \(u[0]), \(l[1]) \(u[1]), \(l[2]) \(u[2]), \(l[3]) \(u[3])",
                          "Quando nessuno lo vende il ricarico è più alto: sei tra i pochi che ce l’hanno. Tocca la percentuale di una casella per scrivere la tua."]),
            ("Esempio", ["1. Il disco ha 640 want: Richiesta \(l[liv]).",
                         "2. La copia più economica in vendita costa 32 €.",
                         "3. Ricarico \(l[liv]) \(r[liv]): prezzo \(PriceEngine.fmt(es)) €.",
                         "Se nessuno lo vendesse: suggerito 25 €, ricarico \(u[liv]), prezzo \(PriceEngine.fmt(esU)) €."]),
            ("Sicurezze", ["• Mai sotto il suggerito: se il conto scende sotto il suggerito di Discogs, il prezzo diventa il suggerito.",
                           "• Griglia: il prezzo si arrotonda per difetto a questo gradino (es. 2,50 €: 47,30 € diventa 45,00 €).",
                           "• Prezzo minimo: nessun disco va online a meno di così."]),
            ("Da sapere", ["La copia più economica su Discogs può essere di qualunque condizione, anche rovinata: per questo c’è «Mai sotto il suggerito».",
                           "Sotto il prezzo di ogni disco trovi il conto scritto in una riga."]),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(blocchi.enumerated()), id: \.offset) { _, blocco in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(blocco.0.uppercased())
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                            ForEach(Array(blocco.1.enumerated()), id: \.offset) { _, riga in
                                Text(riga)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, riga.hasPrefix("•") || riga.first?.isNumber == true ? 6 : 0)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    }
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle("Prezzi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Fatto") { dismiss() }.tint(Theme.accent) }
            }
        }
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }
}
