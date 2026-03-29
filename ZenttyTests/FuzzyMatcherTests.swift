@testable import Zentty
import XCTest

final class FuzzyMatcherTests: XCTestCase {
    func testEmptyQueryReturnsZero() {
        XCTAssertEqual(FuzzyMatcher.score(query: "", in: "toggle sidebar"), 0)
    }

    func testExactMatchReturnsOne() {
        XCTAssertEqual(FuzzyMatcher.score(query: "toggle sidebar", in: "toggle sidebar"), 1.0)
    }

    func testPrefixMatchReturnsHighScore() {
        XCTAssertEqual(FuzzyMatcher.score(query: "toggle", in: "toggle sidebar"), 0.95)
    }

    func testSubstringMatchReturnsPositiveScore() {
        let score = FuzzyMatcher.score(query: "split", in: "split the focused pane horizontally to create a new adjacent column.")
        XCTAssertGreaterThan(score, 0)
    }

    func testGappedCharactersMatchReturnsPositiveScore() {
        let score = FuzzyMatcher.score(query: "sph", in: "split horizontally")
        XCTAssertGreaterThan(score, 0)
    }

    func testNoMatchReturnsZero() {
        XCTAssertEqual(FuzzyMatcher.score(query: "xyz", in: "split horizontally"), 0)
    }

    func testLongerQueryThanTargetReturnsZero() {
        XCTAssertEqual(FuzzyMatcher.score(query: "a very long query", in: "short"), 0)
    }

    func testWordBoundaryBonus() {
        let boundaryScore = FuzzyMatcher.score(query: "sh", in: "split horizontally")
        let noBoundaryScore = FuzzyMatcher.score(query: "sh", in: "ashen")
        XCTAssertGreaterThan(boundaryScore, noBoundaryScore)
    }

    func testScoreOrdering() {
        let exact = FuzzyMatcher.score(query: "split", in: "split")
        let prefix = FuzzyMatcher.score(query: "split", in: "split horizontally")
        let fuzzy = FuzzyMatcher.score(query: "sph", in: "split horizontally")
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, fuzzy)
    }
}
