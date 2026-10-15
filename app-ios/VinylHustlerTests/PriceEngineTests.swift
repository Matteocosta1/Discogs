import XCTest
@testable import VinylHustler

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

    func testVoce() {
        XCTAssertEqual(Voice.spoken("Miles Davis - Kind Of Blue (Columbia, US, 1959)"), "Kind Of Blue di Miles Davis")
        XCTAssertEqual(Voice.spoken("Prince (2) - Purple Rain"), "Purple Rain di Prince")
    }
}
