import XCTest
@testable import Zentty

/// The consent card's "Keep 1 Year" against real files in a temp home with more than one Claude
/// Code config folder: it must change the folder whose conversations get indexed, never another.
@MainActor
final class AgentHistoryConsentClaudeRootsTests: XCTestCase {
    private var home: URL!
    private var control: FakeAgentHistoryControl!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-consent-roots-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        control = FakeAgentHistoryControl()
    }

    override func tearDownWithError() throws {
        if let home {
            try? FileManager.default.removeItem(at: home)
        }
        home = nil
        control = nil
        try super.tearDownWithError()
    }

    // MARK: - Tests

    /// ~/.claude has a short retention but no conversations; they live in ~/.claude-work.
    func test_keep_one_year_raises_the_folder_with_the_conversations() throws {
        try makeClaudeFolder(".claude", sessions: 0, settings: #"{"cleanupPeriodDays": 30}"#)
        try makeClaudeFolder(".claude-work", sessions: 2, settings: #"{"theme": "dark"}"#)
        let defaultSettings = try Data(contentsOf: settingsURL(".claude"))
        let model = startedConsent()

        let consent = try XCTUnwrap(model.consent)
        XCTAssertTrue(consent.showsRetentionNudge)
        let nudge = try XCTUnwrap(consent.retentionNudgeText)
        XCTAssertTrue(nudge.contains(".claude-work"), "names the folder it changes: \(nudge)")

        model.keepClaudeConversationsOneYear()

        XCTAssertNil(model.consent?.retentionError)
        XCTAssertEqual(model.consent?.didRaiseRetention, true)
        XCTAssertEqual(try cleanupDays(".claude-work"), 365)
        XCTAssertEqual(try Data(contentsOf: settingsURL(".claude")), defaultSettings, "~/.claude is left alone")
        XCTAssertEqual(model.consent?.showsRetentionNudge, false)
        XCTAssertEqual(
            model.consent?.raisedRetentionText,
            "Claude Code keeps conversations in \(displayPath(".claude-work")) for 365 days."
        )
    }

    /// Only ~/.claude-work exists: the nudge and the write go there, not to a missing ~/.claude.
    func test_keep_one_year_without_a_default_folder_raises_the_variant() throws {
        try makeClaudeFolder(".claude-work", sessions: 1, settings: nil)
        let model = startedConsent()

        XCTAssertEqual(model.consent?.showsRetentionNudge, true)
        model.keepClaudeConversationsOneYear()

        XCTAssertNil(model.consent?.retentionError)
        XCTAssertEqual(try cleanupDays(".claude-work"), 365)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
    }

    /// The indexed folder already keeps a year; an empty ~/.claude with 30 days is no reason to nudge.
    func test_no_nudge_when_the_folder_with_the_conversations_already_keeps_a_year() throws {
        try makeClaudeFolder(".claude", sessions: 0, settings: #"{"cleanupPeriodDays": 30}"#)
        try makeClaudeFolder(".claude-work", sessions: 1, settings: #"{"cleanupPeriodDays": 400}"#)
        let model = startedConsent()

        XCTAssertEqual(model.body, .consent)
        XCTAssertEqual(model.consent?.showsRetentionNudge, false)
        XCTAssertNil(model.consent?.retentionNudgeText)
    }

    /// Two folders with conversations and short retention: one nudge at a time, each naming its
    /// folder, and each click changes only the folder it named.
    func test_two_short_folders_are_raised_one_at_a_time() throws {
        try makeClaudeFolder(".claude", sessions: 1, settings: nil)
        try makeClaudeFolder(".claude-work", sessions: 1, settings: #"{"cleanupPeriodDays": 14}"#)
        let model = startedConsent()

        XCTAssertEqual(
            model.consent?.retentionNudgeText,
            "Claude Code deletes conversations in \(displayPath(".claude")) after 30 days, so they'll drop out of Agent History too."
        )
        model.keepClaudeConversationsOneYear()
        XCTAssertEqual(try cleanupDays(".claude"), 365)
        XCTAssertEqual(try cleanupDays(".claude-work"), 14)

        XCTAssertEqual(
            model.consent?.retentionNudgeText,
            "Claude Code deletes conversations in \(displayPath(".claude-work")) after 14 days, so they'll drop out of Agent History too."
        )
        model.keepClaudeConversationsOneYear()
        XCTAssertEqual(try cleanupDays(".claude-work"), 365)
        XCTAssertEqual(model.consent?.showsRetentionNudge, false)
        XCTAssertEqual(model.consent?.didRaiseRetention, true)
    }

    // MARK: - Helpers

    private func startedConsent() -> AgentHistoryViewModel {
        control.detectedSources = AgentHistoryDiscoveryProbe.detect(
            locator: AgentHistoryRootLocator(environment: [:], homeDirectory: home)
        )
        let retention = AgentHistoryPaletteServicesAdapter.claudeRetentionServices(
            runner: .inline,
            managedSettingsURL: home.appendingPathComponent("managed-settings.json")
        )
        let services = AgentHistoryPaletteServices(
            control: control,
            search: FakeAgentHistorySearch(),
            launch: FakeAgentHistoryLaunch(),
            excludedFolders: { [] },
            setExcludedFolders: { _ in },
            claudeRetention: retention.read,
            raiseClaudeRetention: retention.raise,
            pasteboard: AgentHistoryTestPasteboard.make(),
            revealInFinder: { _ in },
            fileExists: { _ in true },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let model = AgentHistoryViewModel(
            context: AgentHistoryOpenContext(
                entryPoint: .shortcutOrMenu, currentProject: nil, initialScope: .all, hostWindowID: WindowID("window")
            ),
            services: services,
            theme: AgentHistoryTheme(zenttyTheme: ZenttyTheme.fallback(for: nil)),
            scheduler: ManualAgentHistoryScheduler(),
            formatting: AgentHistoryFormatting(locale: Locale(identifier: "en_US"))
        )
        addTeardownBlock { @MainActor in model.stop() }
        model.start()
        XCTAssertEqual(model.body, .consent)
        return model
    }

    private func makeClaudeFolder(_ name: String, sessions: Int, settings: String?) throws {
        let folder = home.appendingPathComponent(name, isDirectory: true)
        let project = folder.appendingPathComponent("projects/-Users-test-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for _ in 0..<sessions {
            let line = #"{"type":"user","message":{"role":"user","content":"hi"}}"# + "\n"
            try Data(line.utf8).write(to: project.appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl"))
        }
        if let settings {
            try Data(settings.utf8).write(to: settingsURL(name))
        }
    }

    private func settingsURL(_ folder: String) -> URL {
        home.appendingPathComponent(folder).appendingPathComponent("settings.json")
    }

    private func cleanupDays(_ folder: String) throws -> Int? {
        let data = try Data(contentsOf: settingsURL(folder))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object["cleanupPeriodDays"] as? Int
    }

    /// The detected root's path as the card shows it.
    private func displayPath(_ folder: String) -> String {
        let root = control.detectedSources
            .compactMap(\.rootPath)
            .first { ($0 as NSString).lastPathComponent == folder }
        return ((root ?? "") as NSString).abbreviatingWithTildeInPath
    }
}
