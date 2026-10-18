import UIKit
import XCTest
@testable import VinylHustler

/// Prove automatiche: ricerca a mano, memoria (impronta delle foto), voce, descrizione annunci, formati.
/// Se una fallisce, una modifica ha rotto qualcosa che funzionava.
@MainActor
final class AppTests: XCTestCase {

    // MARK: - Ricerca a mano ("Cerca")

    func testReleaseIDDaNumeroOLink() {
        XCTAssertEqual(DiscActions.releaseID("1234567"), 1234567)
        XCTAssertEqual(DiscActions.releaseID("r1234567"), 1234567)
        XCTAssertEqual(DiscActions.releaseID("[r1234567]"), 1234567)
        XCTAssertEqual(DiscActions.releaseID("https://www.discogs.com/release/1234567-Miles-Davis-Kind-Of-Blue"), 1234567)
    }

    func testReleaseIDNonPrendeBarcodeOTesto() {
        XCTAssertNil(DiscActions.releaseID("5099902987620"))        // barcode: 13 cifre
        XCTAssertNil(DiscActions.releaseID("Miles Davis"))
        XCTAssertNil(DiscActions.releaseID("CS 8163"))
        XCTAssertNil(DiscActions.releaseID("0"))
    }

    func testRicercheDaProvare() {
        XCTAssertEqual(Seller.manualTries("5099902987620"), [["barcode": "5099902987620"], ["catno": "5099902987620"], ["q": "5099902987620"]])
        XCTAssertEqual(Seller.manualTries("CS8163"), [["catno": "CS8163"], ["q": "CS8163"]])
        XCTAssertEqual(Seller.manualTries("Miles Davis Kind of Blue"), [["q": "Miles Davis Kind of Blue"]])
    }

    // MARK: - Memoria condivisa: impronta della foto

    private func image(_ draw: (CGContext) -> Void) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400)).image { draw($0.cgContext) }
    }

    private func pattern(shift: CGFloat = 0) -> UIImage {
        image { c in
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
            UIColor.black.setFill()
            for k in 0..<6 { c.fill(CGRect(x: CGFloat(k) * 70 + shift, y: CGFloat(k) * 50, width: 40, height: 160)) }
            UIColor.gray.setFill(); c.fillEllipse(in: CGRect(x: 120, y: 120, width: 160, height: 160))
        }
    }

    func testImprontaStabile() {
        let a = Memoria.impronta(pattern())
        XCTAssertNotNil(a)
        XCTAssertEqual(a, Memoria.impronta(pattern()))               // stessa foto, stessa impronta
        XCTAssertEqual(a?.count, 16)
    }

    func testImprontaQuasiUgualeSeLaFotoCambiaPoco() {
        guard let a = Memoria.impronta(pattern()), let b = Memoria.impronta(pattern(shift: 2)),
              let x = UInt64(a, radix: 16), let y = UInt64(b, radix: 16) else { return XCTFail("impronta mancante") }
        XCTAssertLessThanOrEqual((x ^ y).nonzeroBitCount, 6)        // come il server: al massimo 6 bit diversi
    }

    func testCopertinaTintaUnitaNonSiUsa() {
        XCTAssertNil(Memoria.impronta(image { c in UIColor.black.setFill(); c.fill(CGRect(x: 0, y: 0, width: 400, height: 400)) }))
    }

    // MARK: - Voce

    func testTitoloDetto() {
        XCTAssertEqual(Voice.spoken("Miles Davis - Kind Of Blue (Columbia, US, 1959)"), "Kind Of Blue di Miles Davis")
        XCTAssertEqual(Voice.spoken("Prince (2) - Purple Rain"), "Purple Rain di Prince")
        XCTAssertEqual(Voice.spoken("Senza trattino"), "Senza trattino")
    }

    // MARK: - Descrizione degli annunci

    func testDescrizioneInglese() {
        let text = ListingText.build(media: Grade.nm.discogs, sleeve: Grade.vgPlus.discogs,
                                     tags: ["Inserto incluso", "Apribile"], note: "Small scratch side B",
                                     language: .en, includeCondition: true, fixed: "Ships in 2 days.")
        XCTAssertEqual(text, """
        Vinyl: Near Mint (NM or M-) · Sleeve: Very Good Plus (VG+)
        Gatefold · Insert included
        Small scratch side B
        Ships in 2 days.
        """)
    }

    func testDescrizioneItalianoInglese() {
        let text = ListingText.build(media: Grade.vg.discogs, sleeve: Grade.vg.discogs, tags: ["Copertina scollata"],
                                     note: "", language: .itEn, includeCondition: false, fixed: "")
        XCTAssertEqual(text, "Copertina scollata (Seam split)")
    }

    func testGradoDaTestoDiscogs() {
        XCTAssertEqual(Grade.from(discogs: "Near Mint (NM or M-)"), .nm)
        XCTAssertEqual(Grade.from(discogs: "Very Good Plus (VG+)"), .vgPlus)
        XCTAssertNil(Grade.from(discogs: "Generic"))
    }

    // MARK: - Formati del Magazzino

    func testEuroAllItaliana() {
        XCTAssertEqual(WarehouseView.italian(2345.5), "2.345,50")
        XCTAssertEqual(WarehouseView.italian(12), "12,00")
        XCTAssertEqual(WarehouseView.italian(1234567.891), "1.234.567,89")
    }

    func testSigleCondizioni() {
        XCTAssertEqual(ListingRow.short("Near Mint (NM or M-)"), "NM")
        XCTAssertEqual(ListingRow.short("Very Good Plus (VG+)"), "VG+")
        XCTAssertEqual(ListingRow.short("Generic"), "Generic")
        XCTAssertEqual(ListingRow.short(nil), "")
    }

    // MARK: - Discogs più veloce: cosa si riusa

    func testRisposteDaRiusare() {
        XCTAssertTrue(ResponseCache.cacheable("/releases/123"))
        XCTAssertTrue(ResponseCache.cacheable("/database/search"))
        XCTAssertFalse(ResponseCache.cacheable("/marketplace/listings/55"))   // gli annunci cambiano: sempre freschi
        XCTAssertFalse(ResponseCache.cacheable("/marketplace/orders"))
    }
}
