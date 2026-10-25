import SwiftUI
import UIKit

/// V60 · proposta 7 — l'avvio come JARVIS: finita la scritta d'apertura, le cinque icone in basso entrano una dopo
/// l'altra (ogni 150 ms, con un tick leggero e una vibrazione leggera) e «VINYL HUSTLER · IN LINEA» si decodifica
/// al centro, piccola. È una copia della barra disegnata sopra quella vera: alla fine sfuma e resta quella di Apple.
struct AvvioIcone: View {
    let da: Date
    let selezionata: Int

    static let durata = 2.4                       // secondi: poi RootView toglie questa vista
    private static let nomi = ["Foto", "Bozze", "Magazzino", "Ordini", "Settings"]
    private static let simboli = ["camera.fill", "tray.full", "square.stack.3d.up", "shippingbox", "gearshape"]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { ctx in
            let t = ctx.date.timeIntervalSince(da)
            // tutta la copia sfuma negli ultimi 0,3 s
            let via = t > Self.durata - 0.3 ? max(0, (Self.durata - t) / 0.3) : 1
            ZStack {
                GeometryReader { g in
                    Text(Glifi.rimescola("VINYL HUSTLER · IN LINEA", 1 - min(1, max(0, (t - 0.7) / 0.6))))
                        .font(Theme.mono(10, .bold))
                        .tracking(2.5)
                        .foregroundStyle(Theme.glow)
                        .shadow(color: Theme.glow.opacity(0.6), radius: 4)
                        .opacity(t > 1.9 ? max(0, 1 - (t - 1.9) / 0.4) : 1)
                        .position(x: g.size.width / 2, y: g.size.height * 0.44)
                }
                .ignoresSafeArea()
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        ForEach(0..<5, id: \.self) { k in
                            icona(k, t: t)
                        }
                    }
                    .frame(height: 49)
                    .background(Color.black.ignoresSafeArea(edges: .bottom))
                }
            }
            .opacity(via)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func icona(_ k: Int, t: Double) -> some View {
        let p = morbido((t - 0.15 - Double(k) * 0.15) / 0.35)
        let colore: Color = k == selezionata ? Theme.accent : Theme.muted
        return VStack(spacing: 3) {
            Image(systemName: Self.simboli[k]).font(.system(size: 21, weight: .regular))
            Text(Self.nomi[k]).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(colore)
        .frame(maxWidth: .infinity)
        .scaleEffect(0.4 + 0.6 * p)
        .offset(y: 26 * (1 - p))
        .opacity(p)
    }

    /// I tick e le vibrazioni, uno per icona, al passo dell'animazione.
    @MainActor static func suona() async {
        let leggera = UIImpactFeedbackGenerator(style: .light)
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(150))
            Suoni.icona()
            leggera.impactOccurred()
        }
    }
}
