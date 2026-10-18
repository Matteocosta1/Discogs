import SwiftData
import SwiftUI

/// SCHEDA ANNUNCIO — tutto quello che si può cambiare di un annuncio, prima o dopo averlo messo su Discogs:
/// prezzo, condizione del vinile e della copertina, posizione, descrizione, offerte, in vendita o in bozza.
///   .disc     un disco dell'app non ancora su Discogs: "Metti online" / "Salva in bozza" lo pubblicano così.
///   .listing  un annuncio già su Discogs (dal Magazzino, dalle Bozze, da un disco online): "Salva su Discogs".
struct ListingEditor: View {
    enum Target {
        case disc(Disc)
        case listing(Int)
    }

    let target: Target
    var initialStatus = "For Sale"
    var onSaved: ((Listing) -> Void)? = nil

    @Environment(Seller.self) private var seller
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var discs: [Disc]

    @State private var loaded = false
    @State private var title = ""
    @State private var link: URL?
    @State private var currency = "EUR"
    @State private var price = 0.0
    @State private var media = Grade.vgPlus.discogs
    @State private var sleeve = Grade.vgPlus.discogs
    @State private var location = ""
    @State private var tags: Set<String> = []
    @State private var note = ""
    @State private var comments = ""
    @State private var generated = ""          // l'ultima descrizione automatica: se il testo è uguale, si aggiorna da solo
    @State private var allowOffers = true
    @State private var status = "For Sale"
    @State private var editable = true         // false se l'annuncio è già venduto
    @State private var calculation = ""
    @State private var saving = false
    @State private var error: String?

    private var isLocal: Bool { if case .disc = target { return true } else { return false } }

    /// Discogs accetta per la copertina anche "Generic", "Not Graded", "No Cover" (solo sugli annunci già online).
    private var sleeveOptions: [String] {
        let grades = Grade.allCases.map(\.discogs)
        return isLocal ? grades : grades + ["Generic", "Not Graded", "No Cover"]
    }

    var body: some View {
        NavigationStack {
            Group {
                if loaded { form } else { ProgressView("Leggo l'annuncio…").tint(Theme.accent) }
            }
            .themedBackground()
            .navigationTitle("Annuncio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { if loaded && editable { saveBar } }
            .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {}
        }
        .task { await load() }
        .preferredColorScheme(.dark)
    }

    // MARK: - Modulo

    private var form: some View {
        Form {
            Section {
                if let link {
                    Link(destination: link) {
                        HStack(alignment: .top) {
                            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right.square").foregroundStyle(Theme.accent)
                        }
                    }
                } else {
                    Text(title).font(.system(size: 16, weight: .semibold))
                }
                if !editable {
                    Text("Questo annuncio non è più in vendita né in bozza: non si può modificare.")
                        .font(.caption).foregroundStyle(Theme.warn)
                }
            }

            Section {
                HStack(spacing: 14) {
                    stepButton("minus") { price = max(seller.rules.minimum.double, price - seller.rules.step.double) }
                    TextField("Prezzo", value: $price, format: .number.precision(.fractionLength(2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.glow)
                    stepButton("plus") { price += seller.rules.step.double }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Prezzo (\(currency))")
            } footer: {
                if !calculation.isEmpty { Text(calculation) }
            }

            Section("Condizione · Posizione") {
                Picker("Vinile", selection: $media) {
                    ForEach(Grade.allCases.map(\.discogs), id: \.self) { Text($0).tag($0) }
                }
                Picker("Copertina", selection: $sleeve) {
                    ForEach(sleeveOptions, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Posizione") {
                    TextField("es. Scatola 12", text: $location).multilineTextAlignment(.trailing)
                }
            }

            Section {
                tagGrid
                TextField("Nota per questo disco (es. piccolo graffio lato B)", text: $note, axis: .vertical)
                TextEditor(text: $comments)
                    .frame(minHeight: 110)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                Button("Rigenera la descrizione") { comments = generated }
                    .disabled(comments == generated)
            } header: {
                Text("Descrizione")
            } footer: {
                Text("Si scrive da sola con condizione, note e il testo fisso della Console. Puoi correggerla a mano: da lì in poi resta la tua, finché non tocchi Rigenera.")
            }

            Section {
                Toggle("Accetta offerte", isOn: $allowOffers)
                Picker("Stato", selection: $status) {
                    Text("In vendita").tag("For Sale")
                    Text("Bozza").tag("Draft")
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(status == "Draft" ? "In bozza: sta su Discogs ma i compratori non la vedono." : "In vendita: visibile a tutti su Discogs.")
            }
        }
        .tint(Theme.accent)
        .onChange(of: tags) { _, _ in regenerate() }
        .onChange(of: note) { _, _ in regenerate() }
        .onChange(of: media) { _, _ in regenerate() }
        .onChange(of: sleeve) { _, _ in regenerate() }
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            Suoni.seleziona()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 44, height: 44)
                .background(Theme.panelHigh, in: Circle())
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
    }

    private var tagGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(ListingText.tags) { t in
                let on = tags.contains(t.it)
                Button {
                    if on { tags.remove(t.it) } else { tags.insert(t.it) }
                    Suoni.seleziona()
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Text(t.it)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(on ? Color.black : Theme.text)
                        .background(on ? Theme.accent : Theme.panelHigh, in: Capsule())
                }
                .buttonStyle(.plain)
                .animation(.snappy(duration: 0.2), value: on)
            }
        }
        .padding(.vertical, 4)
    }

    private var saveBar: some View {
        Button {
            Suoni.click()
            Task { await save() }
        } label: {
            Text(saving ? "Salvo…" : saveLabel).font(.system(size: 17, weight: .bold)).frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(SignalButtonStyle())
        .disabled(saving || price <= 0)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var saveLabel: String {
        if !isLocal { return "Salva su Discogs" }
        return status == "Draft" ? "Salva in bozza" : "Metti online"
    }

    // MARK: - Dati

    private func regenerate() {
        let fresh = ListingText.build(media: media, sleeve: sleeve, tags: Array(tags), note: note)
        if comments == generated || comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { comments = fresh }
        generated = fresh
    }

    private func load() async {
        guard !loaded else { return }
        currency = seller.currency
        switch target {
        case .disc(let d):
            title = d.releaseTitle
            link = d.releaseID.flatMap { URL(string: "https://www.discogs.com/release/\($0)") }
            price = d.price ?? 0
            media = d.media.discogs
            sleeve = d.sleeve.discogs
            location = d.box
            tags = Set(d.noteTags)
            note = d.noteText
            allowOffers = d.allowOffers
            status = initialStatus
            calculation = d.priceCalculation
            generated = ListingText.build(media: media, sleeve: sleeve, tags: d.noteTags, note: note)
            comments = d.comments.isEmpty ? generated : d.comments
        case .listing(let id):
            do {
                let l = try await seller.client.listing(id)
                title = l.release.description ?? "Release \(l.release.id)"
                link = URL(string: "https://www.discogs.com/sell/item/\(id)")
                currency = l.price?.currency ?? seller.currency
                price = l.price?.value ?? 0
                media = l.condition ?? Grade.vgPlus.discogs
                sleeve = l.sleeveCondition ?? media
                location = l.location ?? ""
                comments = l.comments ?? ""
                allowOffers = l.allowOffers ?? true
                status = l.status == "Draft" ? "Draft" : "For Sale"
                editable = l.status == "For Sale" || l.status == "Draft"
                if let d = discs.first(where: { $0.listingID == id || (l.externalId != nil && $0.externalID == l.externalId) }) {
                    tags = Set(d.noteTags)
                    note = d.noteText
                }
                generated = ListingText.build(media: media, sleeve: sleeve, tags: Array(tags), note: note)
                if comments.isEmpty { comments = generated }
            } catch {
                self.error = "Non riesco a leggere l'annuncio: \(error.localizedDescription)"
            }
        }
        loaded = true
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let text = comments.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .disc(let d):
            d.price = (price * 100).rounded() / 100
            if let g = Grade.from(discogs: media) { d.mediaRaw = g.rawValue }
            if let g = Grade.from(discogs: sleeve) { d.sleeveRaw = g.rawValue }
            d.box = location.trimmingCharacters(in: .whitespaces)
            d.noteTags = ListingText.tags.map(\.it).filter { tags.contains($0) }
            d.noteText = note
            d.comments = text == generated.trimmingCharacters(in: .whitespacesAndNewlines) ? "" : text
            d.allowOffers = allowOffers
            Suoni.carica()
            await seller.publish(d, status: status)
            try? context.save()
            if d.listingID != nil {
                Suoni.online()
                dismiss()
            } else {
                if seller.lastError == nil { Suoni.nego() }   // l'avviso generale suona già da solo
                error = seller.lastError ?? (d.reason.isEmpty ? "Discogs non ha accettato l'annuncio" : d.reason)
                seller.lastError = nil
            }
        case .listing(let id):
            let changes: [String: Any] = [
                "price": (price * 100).rounded() / 100, "condition": media, "sleeve_condition": sleeve,
                "location": location.trimmingCharacters(in: .whitespaces), "comments": text,
                "allow_offers": allowOffers, "status": status,
            ]
            do {
                let after = try await seller.updateListing(id, changes: changes, discs: discs)
                if let d = discs.first(where: { $0.listingID == id }) {
                    d.noteTags = ListingText.tags.map(\.it).filter { tags.contains($0) }
                    d.noteText = note
                }
                try? context.save()
                Suoni.online()
                onSaved?(after)
                dismiss()
            } catch {
                Suoni.nego()
                self.error = error.localizedDescription
            }
        }
    }
}

extension Decimal {
    var double: Double { NSDecimalNumber(decimal: self).doubleValue }
}
