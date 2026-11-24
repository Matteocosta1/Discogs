import SwiftUI

/// Il titolo di una sezione con la (i) accanto: le spiegazioni stanno lì dentro,
/// così sotto le sezioni non c'è testo che occupa spazio.
struct InfoHeader: View {
    let title: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // V76: verde come i titoli di Settings (continuità)
            Text(title.uppercased())
                .font(Theme.mono(11, .bold)).tracking(2)
                .foregroundStyle(Theme.glow)
                .shadow(color: Theme.glow.opacity(0.4), radius: 3)
            Button(action: action) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Informazioni su \(title)")
            Spacer()
        }
        .textCase(nil)
    }
}

/// Le spiegazioni della Sessione.
enum InfoTopic: String, Identifiable {
    case posizione, condizione, commenti, fotocamera
    var id: String { rawValue }

    var title: String {
        switch self {
        case .posizione: "Posizione"
        case .condizione: "Condizione"
        case .commenti: "Commenti"
        case .fotocamera: "Fotocamera"
        }
    }

    /// Blocchi: titolo e righe. Una riga che inizia con "•" è un punto elenco, con "1." un passo.
    var blocks: [(String, [String])] {
        switch self {
        case .posizione:
            return [
                ("Cos'è", [
                    "È il posto fisico dove metti i dischi che stai fotografando: una scatola, uno scaffale, l'archivio.",
                    "Su Discogs corrisponde al campo «Location» dell'annuncio. È privato: lo vedi solo tu, i compratori no.",
                ]),
                ("Come si usa", [
                    "1. Scegli il contenitore: Archivio, Scatola o Scaffale.",
                    "2. Scrivi il numero o il nome accanto: 12, A3, Rosso…",
                    "3. Fotografa. Ogni disco si porta dietro questa posizione, finché non la cambi.",
                ]),
                ("Esempio", [
                    "Stai riempiendo la scatola numero 12: tocca Scatola e scrivi 12.",
                    "Fotografi 30 dischi: tutti e 30 avranno «Scatola 12».",
                    "Passi alla scatola dopo? Scrivi 13 prima di continuare: da lì in poi i dischi avranno «Scatola 13».",
                ]),
                ("Dove la ritrovi", [
                    "• Sull'annuncio Discogs, nel campo privato «Location».",
                    "• In Inventario, sotto ogni disco (la puoi correggere lì).",
                    "• Negli Ordini: quando un disco si vende, ti dice «Preleva da Scatola 12». Vai a colpo sicuro.",
                ]),
                ("I contenitori", [
                    "• Archivio, Scatola e Scaffale ci sono sempre.",
                    "• Con + ne aggiungi altri, per esempio Casa o Mobile.",
                    "• Per eliminarne uno creato da te, tienilo premuto e scegli Elimina. I dischi già fotografati tengono la loro posizione.",
                ]),
            ]
        case .condizione:
            return [
                ("Cos'è", [
                    "È lo stato del disco, con gli stessi gradi che chiede Discogs quando metti in vendita:",
                    "• Vinile = «Media Condition», lo stato del disco.",
                    "• Copertina = «Sleeve Condition», lo stato della copertina.",
                ]),
                ("I gradi, dal migliore al peggiore", [
                    "• M (Mint): nuovo, mai suonato.",
                    "• NM (Near Mint): quasi perfetto, come nuovo.",
                    "• VG+ (Very Good Plus): lievi segni d'uso, suona bene.",
                    "• VG (Very Good): segni evidenti, qualche fruscio.",
                    "• G+ e G (Good): molto usato, rumori e difetti.",
                ]),
                ("Funziona a blocchi", [
                    "La condizione che scegli qui vale per TUTTI i dischi che fotografi dopo, finché non la cambi.",
                    "Per questo conviene prima dividere i dischi per condizione, e poi fotografarli un blocco alla volta.",
                ]),
                ("Esempio", [
                    "1. Metti da parte 20 dischi quasi perfetti. Scegli Vinile NM e Copertina VG+. Fotografali tutti.",
                    "2. Poi prendi 15 dischi più rovinati. Cambia in Vinile VG e Copertina G+. Fotografa questi.",
                    "Risultato: i primi 20 sono NM / VG+, gli altri 15 sono VG / G+. Ognuno con la sua condizione giusta.",
                ]),
                ("Attenzione", [
                    "Se cambi la condizione a metà di un blocco, i dischi già fotografati restano con quella di prima: cambia solo per i prossimi.",
                ]),
            ]
        case .commenti:
            return [
                ("Cos'è", [
                    "È il testo che i compratori leggono nell'annuncio, sotto la condizione. Su Discogs si chiama «Comments».",
                    "Quello che scrivi qui vale per TUTTI i dischi che fotografi dopo, finché non lo cambi: così non lo ripeti disco per disco.",
                ]),
                ("Esempi", [
                    "• «Copertina con leggeri segni da scaffale.»",
                    "• «Prima stampa, con inserto originale.»",
                    "• «Disco lavato a ultrasuoni.»",
                ]),
                ("Come finisce nell'annuncio", [
                    "L'app scrive da sola la descrizione: condizione, le tue note e il testo fisso di Settings. Questo commento entra lì dentro.",
                    "Puoi sempre cambiarlo disco per disco: tocca il disco in Bozze o in Inventario e apri la scheda annuncio.",
                ]),
                ("Attenzione", [
                    "Vale per i dischi che fotografi dopo. Quelli già fotografati tengono il loro.",
                    "Lascialo vuoto se non serve.",
                ]),
            ]
        case .fotocamera:
            // V82: lo stesso testo della (i) accanto a VINYL HUSTLER nella fotocamera (come nel mock-up);
            // «Prima di aprirla» si vede solo dalla pagina Foto
            return [
                ("Prima di aprirla", [
                    "Controlla Posizione, Condizione e Commenti qui sopra: valgono per tutto quello che fotografi.",
                    "Poi tocca il tasto con la fotocamera.",
                ]),
                ("Tre fotocamere", [
                    "Sopra lo scatto scegli VINILE, CD o CASSETTA. L'app cerca su Discogs solo quel supporto e in Versioni ti propone solo stampe dello stesso supporto.",
                    "L'ultima scelta resta per la volta dopo.",
                ]),
                ("Foto = 1 disco", [
                    "Tocca lo scatto. Basta una foto sola. Va bene:",
                    "• la copertina (o la custodia) davanti;",
                    "• il retro, dove c'è il codice a barre: il modo più veloce e sicuro;",
                    "• l'etichetta del vinile, il CD o la cassetta.",
                    "Se non lo riconosce, tocca «Altra foto» e fotografa un altro lato.",
                ]),
                ("Video = più dischi", [
                    "Tieni premuto lo scatto: parte il video. Passa i dischi davanti al telefono, uno dopo l'altro, fermandoli un attimo: ognuno si aggancia e viene riconosciuto.",
                    "Lascia il dito per fermare. Il video dura al massimo 1 minuto.",
                ]),
                ("Dopo lo scatto", [
                    "• «Vendi»: calcola il prezzo e lo mette subito online.",
                    "• «Bozza»: lo salva come bozza su Discogs, lo ritrovi in Bozze.",
                    "• «Versioni»: le altre stampe dello stesso supporto. Puoi cambiarla quante volte vuoi, anche per tornare alla prima.",
                ]),
                ("Consigli", [
                    "• Luce buona, niente riflessi sulla plastica.",
                    "• Avvicinati: le scritte devono essere leggibili.",
                    "• Un disco alla volta nell'inquadratura, se fai foto.",
                ]),
            ]
        }
    }
}

struct InfoSheet: View {
    let topic: InfoTopic
    /// V82: aperta dalla (i) dentro la fotocamera: senza «Prima di aprirla» (la fotocamera è già aperta).
    var dallaFotocamera = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(topic.blocks.filter { !(dallaFotocamera && $0.0 == "Prima di aprirla") }.enumerated()), id: \.offset) { _, block in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(block.0.uppercased())
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                            ForEach(Array(block.1.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 16))
                                    .foregroundStyle(Theme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, line.hasPrefix("•") || line.first?.isNumber == true ? 6 : 0)
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
            .navigationTitle(topic.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Fatto") { dismiss() }.tint(Theme.accent) }
            }
        }
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }
}
