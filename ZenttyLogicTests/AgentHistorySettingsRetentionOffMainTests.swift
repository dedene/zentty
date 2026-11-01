@testable import Zentty
import AppKit
import XCTest

/// Settings › Agent History reads and raises Claude Code's retention (a settings.json read, a
/// backup and an atomic write) off the main thread, and applies the result on main.
@MainActor
final class AgentHistorySettingsRetentionOffMainTests: AppKitTestCase {
    private var temporaryDirectoryURL: URL!
    private var defaultsSuiteNames: [String] = []
    private var errors: [String] = []

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaultsSuiteNames.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        defaultsSuiteNames.removeAll()
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
    }

    func test_retention_status_is_read_off_main_then_rows_appear() {
        let reads = ThreadLog()
        let controller = makeController(
            retentionStatusProvider: { directory in
                reads.record()
                return Self.userRetention(directory: directory, days: 30)
            },
            retentionWriter: { _ in .alreadySufficient(currentDays: 365) }
        )

        controller.prepareForPresentation()
        waitUntil("retention rows") { !controller.retentionRows.isEmpty }

        XCTAssertEqual(controller.retentionRows.map(\.text), [AgentHistorySettingsRows.retentionText(days: 30)])
        XCTAssertGreaterThan(reads.count, 0)
        XCTAssertEqual(reads.mainThreadCount, 0, "settings.json is read off the main thread")
    }

    func test_keep_one_year_writes_off_main_then_shows_raised() throws {
        let reads = ThreadLog()
        let writes = ThreadLog()
        let raised = RaisedFlag()
        let controller = makeController(
            retentionStatusProvider: { directory in
                reads.record()
                return Self.userRetention(directory: directory, days: raised.isSet ? 365 : 30)
            },
            retentionWriter: { _ in
                writes.record()
                raised.set()
                return .written(backupURL: nil)
            }
        )
        controller.prepareForPresentation()
        waitUntil("retention rows") { controller.keepOneYearButtonForTesting(directory: "/opt/claude") != nil }
        let button = try XCTUnwrap(controller.keepOneYearButtonForTesting(directory: "/opt/claude"))

        controller.handleKeepOneYear(button)
        waitUntil("raised") { controller.retentionRows.map(\.text) == [AgentHistoryConsentModel.raisedRetentionText] }

        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.mainThreadCount, 0, "the backup and atomic write run off the main thread")
        XCTAssertEqual(reads.mainThreadCount, 0)
        XCTAssertNil(controller.keepOneYearButtonForTesting(directory: "/opt/claude"))
        XCTAssertTrue(errors.isEmpty)
    }

    // MARK: - Helpers

    private func makeController(
        retentionStatusProvider: @escaping @Sendable (URL) -> ClaudeRetentionStatus,
        retentionWriter: @escaping @Sendable (URL) throws -> ClaudeRetentionWriteOutcome
    ) -> AgentHistorySettingsSectionViewController {
        let backend = FakeAgentHistoryControl()
        var status = AgentHistoryStatus.off
        status.isStateLoaded = true
        status.isEnabled = true
        status.hasConsented = true
        status.enabledAgents = Set(AgentHistoryAgent.allCases)
        status.state = .watching
        status.sources = [AgentHistorySourceHealth(agent: .claude, root: "/opt/claude", isDefaultRoot: true)]
        backend.status = status
        let controller = AgentHistorySettingsSectionViewController(
            configStore: AppConfigStore(
                fileURL: temporaryDirectoryURL.appendingPathComponent("config.toml"),
                sidebarWidthDefaults: makeDefaults("sidebarWidth"),
                sidebarVisibilityDefaults: makeDefaults("sidebarVisibility"),
                paneLayoutDefaults: makeDefaults("paneLayout")
            ),
            backend: backend,
            confirmationPresenter: { _, _, completion in completion(false) },
            folderPicker: { _, completion in completion([]) },
            errorPresenter: { [weak self] _, title, message in
                self?.errors.append("\(title)|\(message)")
            },
            retentionStatusProvider: retentionStatusProvider,
            retentionWriter: retentionWriter,
            locale: Locale(identifier: "en_US")
        )
        controller.loadViewIfNeeded()
        return controller
    }

    private nonisolated static func userRetention(directory: URL, days: Int) -> ClaudeRetentionStatus {
        ClaudeRetentionStatus(
            configDirectory: directory,
            settingsFileURL: directory.appendingPathComponent("settings.json"),
            effectiveDays: days,
            source: .userSettings,
            readError: nil
        )
    }

    private func makeDefaults(_ suffix: String) -> UserDefaults {
        let name = "be.zenjoy.zentty.tests.agentHistoryRetention.\(suffix).\(UUID().uuidString)"
        defaultsSuiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 2, _ condition: @escaping @MainActor () -> Bool) {
        let done = expectation(description: description)
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() || Date() > deadline {
                done.fulfill()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                MainActor.assumeIsolated { poll() }
            }
        }
        poll()
        wait(for: [done], timeout: timeout + 1)
    }
}

/// Counts calls and how many of them ran on the main thread; safe from any thread.
private final class ThreadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var mainCalls = 0

    func record() {
        let isMain = Thread.isMainThread
        lock.withLock {
            calls += 1
            if isMain { mainCalls += 1 }
        }
    }

    var count: Int { lock.withLock { calls } }
    var mainThreadCount: Int { lock.withLock { mainCalls } }
}

private final class RaisedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
