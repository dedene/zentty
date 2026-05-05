import XCTest
@testable import Zentty

final class TmuxCompatStoreTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TmuxCompatStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        try super.tearDownWithError()
    }

    private func storeURL() -> URL {
        temporaryDirectoryURL.appendingPathComponent("tmux-compat-store.json")
    }

    func test_load_returns_empty_when_file_missing() {
        let loaded = TmuxCompatStoreIO.load(from: storeURL())
        XCTAssertEqual(loaded, .empty)
    }

    func test_save_then_load_round_trips() throws {
        var store = TmuxCompatStore.empty
        store.anchors["wl_one"] = WorklaneAnchor(
            leaderPaneID: "pn_leader",
            columnPaneIDs: ["pn_a1", "pn_a2"]
        )
        store.buffers["clip"] = "hello world"
        store.activePaneIDs["wl_one"] = "pn_a2"

        try TmuxCompatStoreIO.save(store, to: storeURL())

        let loaded = TmuxCompatStoreIO.load(from: storeURL())
        XCTAssertEqual(loaded, store)
    }

    func test_load_tolerates_store_without_active_pane_ids() throws {
        try """
        {
          "version" : 1,
          "anchors" : {
            "wl_one" : {
              "leaderPaneID" : "pn_leader",
              "columnPaneIDs" : ["pn_a1"]
            }
          },
          "buffers" : {
            "clip" : "hello"
          }
        }
        """.write(to: storeURL(), atomically: true, encoding: .utf8)

        let loaded = TmuxCompatStoreIO.load(from: storeURL())
        XCTAssertEqual(loaded.activePaneIDs, [:])
        XCTAssertEqual(loaded.anchors["wl_one"]?.leaderPaneID, "pn_leader")
        XCTAssertEqual(loaded.buffers["clip"], "hello")
    }

    func test_mutate_persists_changes() {
        TmuxCompatStoreIO.mutate(at: storeURL()) { store in
            store.anchors["wl_x"] = WorklaneAnchor(leaderPaneID: "pn_l", columnPaneIDs: [])
        }

        TmuxCompatStoreIO.mutate(at: storeURL()) { store in
            store.anchors["wl_x"]?.columnPaneIDs.append("pn_b1")
        }

        let loaded = TmuxCompatStoreIO.load(from: storeURL())
        XCTAssertEqual(loaded.anchors["wl_x"]?.columnPaneIDs, ["pn_b1"])
    }

    func test_anchor_round_trips_pre_team_leader_column_width() throws {
        var store = TmuxCompatStore.empty
        store.anchors["wl_one"] = WorklaneAnchor(
            leaderPaneID: "pn_leader",
            columnPaneIDs: ["pn_a1"],
            preTeamLeaderColumnWidth: 312.5
        )

        try TmuxCompatStoreIO.save(store, to: storeURL())

        let loaded = TmuxCompatStoreIO.load(from: storeURL())
        XCTAssertEqual(loaded.anchors["wl_one"]?.preTeamLeaderColumnWidth, 312.5)
    }

    func test_load_tolerates_legacy_anchor_without_pre_team_width() throws {
        try """
        {
          "version" : 1,
          "anchors" : {
            "wl_one" : {
              "leaderPaneID" : "pn_leader",
              "columnPaneIDs" : ["pn_a1"]
            }
          }
        }
        """.write(to: storeURL(), atomically: true, encoding: .utf8)

        let loaded = TmuxCompatStoreIO.load(from: storeURL())
        XCTAssertEqual(loaded.anchors["wl_one"]?.leaderPaneID, "pn_leader")
        XCTAssertNil(loaded.anchors["wl_one"]?.preTeamLeaderColumnWidth)
    }

    func test_load_returns_empty_on_corrupt_json() throws {
        try "not json at all".write(to: storeURL(), atomically: true, encoding: .utf8)

        let loaded = TmuxCompatStoreIO.load(from: storeURL())
        XCTAssertEqual(loaded, .empty)
    }

    func test_save_creates_parent_directory() throws {
        let nestedURL = temporaryDirectoryURL
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("deep", isDirectory: true)
            .appendingPathComponent("store.json")

        try TmuxCompatStoreIO.save(TmuxCompatStore.empty, to: nestedURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedURL.path))
    }

    func test_save_writes_schema_version() throws {
        try TmuxCompatStoreIO.save(TmuxCompatStore.empty, to: storeURL())
        let raw = try String(contentsOf: storeURL(), encoding: .utf8)
        XCTAssertTrue(
            raw.contains("\"version\""),
            "Saved file should record its schema version: \(raw)"
        )
    }
}
