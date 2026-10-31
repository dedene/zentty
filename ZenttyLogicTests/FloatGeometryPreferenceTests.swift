import XCTest
@testable import Zentty

final class FloatGeometryPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        FloatGeometryPreference.reset()
        defaults = FloatGeometryPreference.userDefaults()
    }

    override func tearDown() {
        FloatGeometryPreference.reset()
        defaults = nil
        super.tearDown()
    }

    func testRestoredEmptyWhenNothingPersisted() {
        let store = FloatGeometryPreference.restored(from: defaults)
        XCTAssertEqual(store.entryCount, 0)
    }

    func testPersistAndRestoreRoundTrip() {
        var store = FloatGeometryStore()
        store.remember(FloatName(value: "lazygit"), size: CGSize(width: 800, height: 600))
        store.remember(FloatName(value: "claude"), size: CGSize(width: 1024, height: 768))

        FloatGeometryPreference.persist(store, in: defaults)

        let restored = FloatGeometryPreference.restored(from: defaults)
        XCTAssertEqual(restored.recall(FloatName(value: "lazygit")), CGSize(width: 800, height: 600))
        XCTAssertEqual(restored.recall(FloatName(value: "claude")), CGSize(width: 1024, height: 768))
    }

    func testCorruptDataRestoresEmptyStore() {
        defaults.set("not json".data(using: .utf8), forKey: FloatGeometryPreference.storageKey)
        let store = FloatGeometryPreference.restored(from: defaults)
        XCTAssertEqual(store.entryCount, 0)
    }

    func testUnknownSchemaReturnsSafeFallback() {
        let json = #"{"entries":{"lazygit":{"w":800,"h":600}}}"#
        defaults.set(json.data(using: .utf8), forKey: FloatGeometryPreference.storageKey)
        let store = FloatGeometryPreference.restored(from: defaults)
        XCTAssertEqual(store.entryCount, 0)
    }

    func testPayloadWithExtraPlacementKeysStillRestoresSize() throws {
        // Older payloads carried placement keys; unknown keys must not break decoding.
        struct OlderEntry: Encodable {
            let width: Double
            let height: Double
            let lastShownAt: Date
            let placementKind: String
            let corner: String
        }
        struct OlderPayload: Encodable { let entries: [String: OlderEntry] }
        let payload = OlderPayload(entries: [
            "claude": OlderEntry(
                width: 1024,
                height: 768,
                lastShownAt: Date(timeIntervalSince1970: 1_000),
                placementKind: "docked",
                corner: "topLeft"
            )
        ])
        defaults.set(try JSONEncoder().encode(payload), forKey: FloatGeometryPreference.storageKey)

        let restored = FloatGeometryPreference.restored(from: defaults)

        XCTAssertEqual(restored.recall(FloatName(value: "claude")), CGSize(width: 1024, height: 768))
    }
}
