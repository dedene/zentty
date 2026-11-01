import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryStateStoreTests: XCTestCase {
    private var directoryURL: URL!
    private var fileURL: URL { directoryURL.appendingPathComponent("state.json", isDirectory: false) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        directoryURL = url
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func test_missing_file_is_disabled_default() {
        let store = AgentHistoryStateStore(fileURL: fileURL)

        XCTAssertEqual(store.current, AgentHistoryState())
        XCTAssertFalse(store.current.enabled)
        XCTAssertNil(store.current.consentedAt)
        XCTAssertEqual(store.current.version, AgentHistoryState.currentVersion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func test_round_trip_consent_and_sources() throws {
        let consentedAt = Date(timeIntervalSince1970: 1_793_000_000)
        let store = AgentHistoryStateStore(fileURL: fileURL)
        try store.update { state in
            state.enabled = true
            state.consentedAt = consentedAt
            state.setSource(.codex, enabled: false)
            state.setSource(.claude, enabled: true)
        }

        let reloaded = AgentHistoryStateStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.current, store.current)
        XCTAssertTrue(reloaded.current.enabled)
        XCTAssertEqual(reloaded.current.consentedAt, consentedAt)
        XCTAssertFalse(reloaded.current.isSourceEnabled(.codex))
        XCTAssertTrue(reloaded.current.isSourceEnabled(.claude))

        // ISO 8601 dates, camelCase keys, raw-value source keys.
        let object = try jsonObject(at: fileURL)
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["enabled"] as? Bool, true)
        XCTAssertEqual(object["consentedAt"] as? String, "2026-10-26T07:33:20Z")
        let sources = try XCTUnwrap(object["sources"] as? [String: Bool])
        XCTAssertEqual(sources, ["codex": false, "claude": true])
    }

    func test_absent_source_defaults_enabled() throws {
        var state = AgentHistoryState()
        for agent in AgentHistoryAgent.allCases {
            XCTAssertTrue(state.isSourceEnabled(agent))
        }

        state.setSource(.grok, enabled: false)
        XCTAssertFalse(state.isSourceEnabled(.grok))
        XCTAssertTrue(state.isSourceEnabled(.opencode))

        try write(#"{"version":1,"enabled":true,"sources":{"grok":false}}"#)
        let store = AgentHistoryStateStore(fileURL: fileURL)
        XCTAssertFalse(store.current.isSourceEnabled(.grok))
        XCTAssertTrue(store.current.isSourceEnabled(.claude))
        XCTAssertTrue(store.current.isSourceEnabled(.codex))
        XCTAssertTrue(store.current.isSourceEnabled(.opencode))
    }

    func test_enabled_agents_derived_from_sources() {
        var state = AgentHistoryState()
        XCTAssertEqual(state.enabledAgents, Set(AgentHistoryAgent.allCases))

        state.setSource(.codex, enabled: false)
        state.setSource(.opencode, enabled: false)
        XCTAssertEqual(state.enabledAgents, [.claude, .grok])

        state.setSource(.codex, enabled: true)
        XCTAssertEqual(state.enabledAgents, [.claude, .codex, .grok])
    }

    func test_unknown_source_keys_and_fields_are_tolerated_and_kept() throws {
        try write("""
        {
          "version": 1,
          "enabled": true,
          "consentedAt": "2026-10-31T10:15:00Z",
          "sources": {"claude": false, "gemini": true},
          "futureField": {"nested": [1, 2, 3]}
        }
        """)

        let store = AgentHistoryStateStore(fileURL: fileURL)
        XCTAssertTrue(store.current.enabled)
        XCTAssertFalse(store.current.isSourceEnabled(.claude))
        XCTAssertEqual(store.current.sources["gemini"], true)
        XCTAssertEqual(store.current.enabledAgents, [.codex, .grok, .opencode])

        try store.update { $0.setSource(.codex, enabled: false) }

        let object = try jsonObject(at: fileURL)
        let sources = try XCTUnwrap(object["sources"] as? [String: Bool])
        XCTAssertEqual(sources, ["claude": false, "gemini": true, "codex": false])
        let future = try XCTUnwrap(object["futureField"] as? [String: Any])
        XCTAssertEqual(future["nested"] as? [Int], [1, 2, 3])

        // Known keys are owned by the state, not by the preserved extras.
        try store.update { $0.enabled = false }
        XCTAssertEqual(try jsonObject(at: fileURL)["enabled"] as? Bool, false)
        XCTAssertNotNil(try jsonObject(at: fileURL)["futureField"])
    }

    func test_missing_fields_decode_to_defaults() throws {
        try write("{}")
        let store = AgentHistoryStateStore(fileURL: fileURL)
        XCTAssertEqual(store.current, AgentHistoryState())
    }

    func test_corrupt_file_loads_default_and_next_update_rewrites_it() throws {
        try write("{ this is not json")
        let store = AgentHistoryStateStore(fileURL: fileURL)
        XCTAssertEqual(store.current, AgentHistoryState())

        try store.update { $0.enabled = true }

        let object = try jsonObject(at: fileURL)
        XCTAssertEqual(object["enabled"] as? Bool, true)
        XCTAssertTrue(AgentHistoryStateStore(fileURL: fileURL).current.enabled)
    }

    func test_file_is_0600() throws {
        let store = AgentHistoryStateStore(fileURL: fileURL)
        try store.update { $0.enabled = true }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        // A rewrite keeps the mode and leaves no temp files behind.
        try store.update { $0.enabled = false }
        let rewritten = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((rewritten[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
        XCTAssertEqual(names, ["state.json"])
    }

    func test_observers_receive_updates_on_main() throws {
        let store = AgentHistoryStateStore(fileURL: fileURL)
        let received = expectation(description: "observer called on main")
        let removedNotCalled = expectation(description: "removed observer not called")
        removedNotCalled.isInverted = true

        let observerID = store.addObserver { state in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(state.enabled)
            received.fulfill()
        }
        let removedID = store.addObserver { _ in
            removedNotCalled.fulfill()
        }
        store.removeObserver(removedID)

        DispatchQueue.global(qos: .utility).async {
            try? store.update { $0.enabled = true }
        }

        wait(for: [received, removedNotCalled], timeout: 2)
        store.removeObserver(observerID)
    }

    func test_reset_after_delete_returns_default() throws {
        let store = AgentHistoryStateStore(fileURL: fileURL)
        try store.update { state in
            state.enabled = true
            state.consentedAt = Date(timeIntervalSince1970: 1_793_000_000)
            state.setSource(.claude, enabled: false)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // The earlier update's notification may still be queued; wait for the reset one.
        let notified = expectation(description: "observer sees the reset")
        store.addObserver { state in
            if state == AgentHistoryState() {
                notified.fulfill()
            }
        }

        try FileManager.default.removeItem(at: directoryURL)
        store.resetAfterDelete()

        XCTAssertEqual(store.current, AgentHistoryState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(AgentHistoryStateStore(fileURL: fileURL).current, AgentHistoryState())
        wait(for: [notified], timeout: 2)
    }

    // MARK: - Write failures

    /// Off and an agent off take effect in memory even when the file can't be written; the
    /// error still reaches the caller. Anything that grants access is dropped instead.
    func test_failed_write_keeps_a_revoking_change_in_memory_only() throws {
        let consentedAt = Date(timeIntervalSince1970: 1_793_000_000)
        let store = AgentHistoryStateStore(fileURL: fileURL)
        try store.update { $0.enabled = true; $0.consentedAt = consentedAt }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directoryURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path) }

        XCTAssertThrowsError(try store.update { $0.enabled = false; $0.setSource(.codex, enabled: false) }) { error in
            XCTAssertEqual((error as? AgentHistoryStateStore.UnsavedChange)?.keptInMemory, true)
        }
        XCTAssertFalse(store.current.enabled)
        XCTAssertFalse(store.current.isSourceEnabled(.codex))
        XCTAssertTrue(AgentHistoryStateStore(fileURL: fileURL).current.enabled, "the file is unchanged")

        XCTAssertThrowsError(try store.update { $0.enabled = true }) { error in
            XCTAssertEqual((error as? AgentHistoryStateStore.UnsavedChange)?.keptInMemory, false)
        }
        XCTAssertThrowsError(try store.update { $0.setSource(.codex, enabled: true) }) { error in
            XCTAssertEqual((error as? AgentHistoryStateStore.UnsavedChange)?.keptInMemory, false)
        }
        XCTAssertFalse(store.current.enabled, "turning on wasn't saved, so it didn't happen")
        XCTAssertFalse(store.current.isSourceEnabled(.codex))
    }

    func test_only_revokes_access() {
        let consented = AgentHistoryState(enabled: true, consentedAt: Date(timeIntervalSince1970: 1), sources: [:])
        var off = consented
        off.enabled = false
        var codexOff = consented
        codexOff.setSource(.codex, enabled: false)
        var reconsented = off
        reconsented.consentedAt = Date(timeIntervalSince1970: 2)

        XCTAssertTrue(off.onlyRevokesAccess(from: consented))
        XCTAssertTrue(codexOff.onlyRevokesAccess(from: consented))
        XCTAssertTrue(AgentHistoryState().onlyRevokesAccess(from: consented), "consent removed")
        XCTAssertTrue(consented.onlyRevokesAccess(from: consented))
        XCTAssertFalse(consented.onlyRevokesAccess(from: off))
        XCTAssertFalse(consented.onlyRevokesAccess(from: codexOff))
        XCTAssertFalse(reconsented.onlyRevokesAccess(from: off))
        XCTAssertFalse(off.onlyRevokesAccess(from: AgentHistoryState()), "consent added")
    }

    // MARK: - Helpers

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
