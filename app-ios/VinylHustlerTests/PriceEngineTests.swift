import XCTest
@testable import VinylHustler

/// V76: la regola di Settings › Prezzi (più economica + ricarico della Richiesta; nessuno in vendita: suggerito
/// + ricarico più alto; mai sotto il suggerito; griglia 0,50 per difetto). Gli stessi casi della pagina «Prova prezzi».
final class PriceEngineTests: XCTestCase {
    private func price(_ suggested: Double, _ market: MarketData?) -> Decimal {
        PriceEngine.compute(suggested: suggested, market: market, grade: .m, currency: "EUR", rules: PriceRules()).price
    }

    private func m(_ want: Int, _ have: Int, _ forSale: Int, _ lowest: Double?) -> MarketData {
        MarketData(want: want, have: have, numForSale: forSale, lowestPrice: lowest, lowestCurrency: "EUR")
    }

    func testNessunDato() { XCTAssertEqual(price(10, nil), 10) }
    func testAltissima() { XCTAssertEqual(price(20, m(1500, 300, 2, 40)), 80) }
    func testBassa() { XCTAssertEqual(price(20, m(30, 300, 2, 40)), 44) }
    func testSottoIlSuggerito() { XCTAssertEqual(price(15, m(120, 900, 40, 9)), 15) }
    func testNessunoInVendita() { XCTAssertEqual(price(25, m(600, 80, 0, nil)), 75) }

    func testVoce() {
        XCTAssertEqual(Voice.spoken("Miles Davis - Kind Of Blue (Columbia, US, 1959)"), "Kind Of Blue di Miles Davis")
        XCTAssertEqual(Voice.spoken("Prince (2) - Purple Rain"), "Purple Rain di Prince")
    }
}
