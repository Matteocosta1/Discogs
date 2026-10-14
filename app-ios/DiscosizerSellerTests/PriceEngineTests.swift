import XCTest
@testable import DiscosizerSeller

/// Gli stessi casi calcolati con lo script Python (vendi.compute_price, regole di default, grado M, EUR):
/// se un test fallisce, l'app e lo script danno prezzi diversi.
final class PriceEngineTests: XCTestCase {
    private func price(_ suggested: Double, _ market: MarketData?) -> Decimal {
        PriceEngine.compute(suggested: suggested, market: market, grade: .m, currency: "EUR", rules: PriceRules()).price
    }

    private func m(_ want: Int, _ have: Int, _ forSale: Int, _ lowest: Double?) -> MarketData {
        MarketData(want: want, have: have, numForSale: forSale, lowestPrice: lowest, lowestCurrency: "EUR")
    }

    func testNessunDato() { XCTAssertEqual(price(10, nil), 10) }
    func testCaldaZeroCopie() { XCTAssertEqual(price(10, m(50, 10, 0, nil)), 25) }
    func testLentaConConcorrenza() { XCTAssertEqual(price(8, m(5, 20, 12, 12)), 10) }
    func testNormaleAlcuneCopie() { XCTAssertEqual(price(9, m(30, 20, 4, 11)), 15) }
    func testNormalePocheCopie() { XCTAssertEqual(price(6.3, m(12, 10, 2, 5)), 12.5) }
    func testCaldaMolteCopie() { XCTAssertEqual(price(20, m(300, 60, 9, 25)), 37.5) }
    func testLentaSottoSuggerito() { XCTAssertEqual(price(15, m(2, 40, 7, 9)), 15) }

    func testCatalogo() {
        XCTAssertEqual(Evidence.normalizeCatno("SHVL 804"), "SHVL804")
        XCTAssertTrue(Evidence.isStrongCatno("SHVL804"))
        XCTAssertFalse(Evidence.isStrongCatno("1984"))
        XCTAssertTrue(Evidence.isTrackLine("A1 Dance Of The Medusa"))
        XCTAssertNotNil(Evidence.catnoCandidates(["Sound Signature SS026"])["SS026"])
    }
}
