import XCTest
@testable import Zentty

final class FloatGeometryStoreTests: XCTestCase {
    func testFloatNameEqualityIsCaseSensitive() {
        XCTAssertEqual(FloatName(value: "lazygit"), FloatName(value: "lazygit"))
        XCTAssertNotEqual(FloatName(value: "lazygit"), FloatName(value: "LazyGit"))
    }

    func testRecallReturnsNilForUnknownName() {
        let store = FloatGeometryStore()
        XCTAssertNil(store.recall(FloatName(value: "lazygit")))
    }

    func testRememberAndRecallRoundTrip() {
        var store = FloatGeometryStore()
        store.remember(FloatName(value: "lazygit"), size: CGSize(width: 800, height: 600))
        XCTAssertEqual(store.recall(FloatName(value: "lazygit")), CGSize(width: 800, height: 600))
    }

    func testRememberOverwritesPreviousSize() {
        var store = FloatGeometryStore()
        store.remember(FloatName(value: "claude"), size: CGSize(width: 400, height: 300))
        store.remember(FloatName(value: "claude"), size: CGSize(width: 1000, height: 800))
        XCTAssertEqual(store.recall(FloatName(value: "claude")), CGSize(width: 1000, height: 800))
    }

    func testDefaultSizeIs60PercentOfCanvas() {
        let store = FloatGeometryStore()
        let canvas = CGSize(width: 1000, height: 800)
        XCTAssertEqual(store.defaultSize(forCanvas: canvas), CGSize(width: 600, height: 480))
    }

    func testLRUPruneAt50Entries() {
        var store = FloatGeometryStore()
        for i in 0..<51 {
            store.remember(
                FloatName(value: "f\(i)"),
                size: CGSize(width: i, height: i),
                now: Date(timeIntervalSince1970: TimeInterval(i))
            )
        }
        XCTAssertEqual(store.entryCount, 50)
        XCTAssertNil(store.recall(FloatName(value: "f0"))) // oldest should be evicted
        XCTAssertNotNil(store.recall(FloatName(value: "f50")))
    }
}
