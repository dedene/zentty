import AppKit
import XCTest
@testable import Zentty

@MainActor
final class AgentHistoryFolderGoneSheetModelTests: XCTestCase {
    private let home = "/Users/test-history-home"
    private let mainRoot = "/Users/test-history-home/src/app"
    private let worktreeRoot = "/Users/test-history-home/src/worktrees/app-feature"
    private let branch = "feature/x"
    private let nowMs: Int64 = 1_800_000_000_000

    private var gitDir: String { mainRoot + "/.git" }

    // MARK: - Fixtures

    /// A main repository with `main` checked out and a `feature/x` loose branch ref; the linked
    /// worktree folder is gone.
    private func mainRepository(withBranch: Bool = true) -> FakeHistoryFileSystem {
        var fs = FakeHistoryFileSystem()
        fs.makeDirectory(mainRoot + "/Sources")
        fs.write(gitDir + "/HEAD", "ref: refs/heads/main\n")
        fs.write(gitDir + "/refs/heads/main", "1111111111111111111111111111111111111111\n")
        if withBranch {
            fs.write(gitDir + "/refs/heads/feature/x", "2222222222222222222222222222222222222222\n")
        }
        return fs
    }

    private func worktreeSource(repoRoot: String? = nil, mainRepoRoot: String? = nil) -> AgentHistoryResumeSource {
        AgentHistoryResumeSource(
            sessionRowID: 7,
            agent: .claude,
            nativeSessionID: "0b6c1d8e-4b1a-4c55-9a1e-3f4b2c6d7e8f",
            title: "Fix the sidebar",
            workingDirectory: worktreeRoot + "/Sources",
            repoRoot: repoRoot ?? worktreeRoot,
            mainRepoRoot: mainRepoRoot ?? mainRoot,
            branch: branch,
            model: nil,
            effort: nil,
            generation: nil,
            sourceRoot: nil
        )
    }

    private func sheet(
        for source: AgentHistoryResumeSource,
        _ fs: FakeHistoryFileSystem
    ) throws -> AgentHistoryFolderGoneSheetModel {
        guard case let .folderGone(options, defaultChoice) = AgentHistoryFolderResolver.resolve(
            source, fileSystem: fs, homeDirectory: home
        ) else {
            XCTFail("expected the folder to be gone")
            throw CancellationError()
        }
        return try XCTUnwrap(AgentHistoryFolderGoneSheetModel.make(
            source: source,
            intent: .primary,
            options: options,
            defaultChoice: defaultChoice,
            homeDirectory: home
        ))
    }

    // MARK: - Options

    func test_options_repo_root_recreate_copy_when_eligible() throws {
        let model = try sheet(for: worktreeSource(), mainRepository())

        XCTAssertEqual(
            model.displayOptions.map(\.title),
            ["Repository root", "Recreate the worktree", "Copy the resume command"]
        )
        XCTAssertEqual(model.selectedChoice, .repositoryRoot(mainRoot), "the repository root is the default")
        XCTAssertEqual(
            model.displayOptions[0].detail,
            [.code("~/src/app"), .text(", on whatever branch is checked out there.")]
        )
        XCTAssertEqual(
            AgentHistoryFolderGoneSheetModel.plainText(model.displayOptions[1].detail),
            "Runs git worktree add for feature/x at ~/src/worktrees/app-feature, then resumes there."
        )
        XCTAssertEqual(
            model.accessibilityMessage,
            "~/src/worktrees/app-feature/Sources no longer exists, probably removed with the worktree for feature/x. "
                + "Where should \(AgentHistoryAgent.claude.displayName) continue?"
        )
        XCTAssertEqual(model.displayOptions[2].accessibilityLabel, "Copy the resume command. Run it yourself wherever you like.")
    }

    func test_home_replaces_repo_root_when_no_repository() throws {
        var source = worktreeSource()
        source.repoRoot = nil
        source.mainRepoRoot = nil
        let model = try sheet(for: source, FakeHistoryFileSystem())

        XCTAssertEqual(model.displayOptions.map(\.title), ["Home folder", "Copy the resume command"])
        XCTAssertEqual(model.selectedChoice, .homeFolder(home))
        XCTAssertEqual(model.displayOptions[0].detail, [.code("~"), .text(". No repository is known for this session.")])
        XCTAssertEqual(
            model.accessibilityMessage,
            "~/src/worktrees/app-feature/Sources no longer exists. Where should \(AgentHistoryAgent.claude.displayName) continue?",
            "no worktree hint without a linked worktree"
        )
    }

    func test_recreate_hidden_when_not_eligible() throws {
        let model = try sheet(for: worktreeSource(), mainRepository(withBranch: false))

        XCTAssertEqual(model.displayOptions.map(\.title), ["Repository root", "Copy the resume command"])
        XCTAssertFalse(model.options.contains { if case .recreateWorktree = $0 { true } else { false } })
    }

    func test_move_clamps_within_options() throws {
        var model = try sheet(for: worktreeSource(), mainRepository())
        XCTAssertEqual(model.selectedIndex, 0)

        model.move(-1)
        XCTAssertEqual(model.selectedIndex, 0)
        model.move(1)
        XCTAssertEqual(model.selectedIndex, 1)
        model.move(5)
        XCTAssertEqual(model.selectedIndex, 2)
        XCTAssertEqual(model.selectedChoice, .copyResumeCommand)
        model.select(9)
        XCTAssertEqual(model.selectedIndex, 2, "out-of-range clicks are ignored")
        model.select(0)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertNil(AgentHistoryFolderGoneSheetModel.make(
            source: worktreeSource(), intent: .primary, options: [], defaultChoice: .copyResumeCommand
        ))
    }

    // MARK: - Confirming through the palette

    func test_confirm_copy_writes_command_to_injected_pasteboard() {
        let harness = makeHarness()
        harness.launch.outcome = .needsFolderChoice(
            options: [.homeFolder(home), .copyResumeCommand],
            defaultChoice: .homeFolder(home)
        )
        let model: AgentHistoryViewModel = harness.model
        model.handle(.primary)
        XCTAssertNotNil(model.folderSheet)

        model.selectFolderSheetOption(1)
        model.handle(.sheetConfirm)

        XCTAssertNil(model.folderSheet)
        XCTAssertEqual(harness.pasteboard.string(forType: .string), "codex resume native-1", "the folder is gone, so no cd")
        XCTAssertEqual(model.transientMessage, "Copied resume command")
        XCTAssertEqual(harness.launch.launches.count, 1, "copying never relaunches")
        XCTAssertTrue(harness.closeRequests.isEmpty)
    }

    func test_confirm_other_option_relaunches_with_folder_choice() {
        let harness = makeHarness()
        let recreation = AgentHistoryWorktreeRecreation(
            mainRepoRoot: mainRoot, worktreePath: worktreeRoot, branch: branch, hasStaleRegistration: false,
            resumeDirectory: worktreeRoot, staleRegistrationRemovalArguments: nil,
            gitArguments: ["-C", mainRoot, "worktree", "add", "--", worktreeRoot, branch]
        )
        harness.launch.outcome = .needsFolderChoice(
            options: [.repositoryRoot(mainRoot), .recreateWorktree(recreation), .copyResumeCommand],
            defaultChoice: .repositoryRoot(mainRoot)
        )
        let model: AgentHistoryViewModel = harness.model
        model.handle(.secondary)

        model.selectFolderSheetOption(1)
        harness.launch.outcome = .recreatingWorktree
        model.confirmFolderSheet()

        XCTAssertNil(model.folderSheet)
        XCTAssertEqual(harness.launch.launches.map(\.folderChoice), [nil, .recreateWorktree(recreation)])
        XCTAssertEqual(harness.launch.launches.last?.intent, .secondary, "the sheet keeps the original intent")
        XCTAssertEqual(harness.closeRequests, [false])

        harness.launch.outcome = .needsFolderChoice(options: [.copyResumeCommand], defaultChoice: .copyResumeCommand)
        model.handle(.primary)
        model.cancelFolderSheet()
        XCTAssertNil(model.folderSheet)
        XCTAssertEqual(harness.launch.launches.count, 3, "cancel launches nothing")
    }

    // MARK: - Harness

    @MainActor
    private final class Harness {
        let control = FakeAgentHistoryControl()
        let search = FakeAgentHistorySearch()
        let launch = FakeAgentHistoryLaunch()
        let scheduler = ManualAgentHistoryScheduler()
        let pasteboard = AgentHistoryTestPasteboard.make()
        var closeRequests: [Bool] = []
        var model: AgentHistoryViewModel!
    }

    /// A started palette showing one recent Codex session (selected) whose resume command is
    /// `codex resume native-1`.
    private func makeHarness() -> Harness {
        let harness = Harness()
        var status = AgentHistoryStatus.off
        status.isEnabled = true
        status.hasConsented = true
        status.state = .watching
        status.indexedSessions = 1
        status.tokenizer = .trigram
        status.revision = 1
        harness.control.status = status
        let summary = AgentHistorySessionSummary(
            id: 1, sourceID: 1, sourceRoot: "/tmp/agent-history-tests/root", agent: .codex,
            nativeID: "native-1", title: "Session 1", titleKind: .generated,
            cwd: "/tmp/agent-history-tests/gone", transcriptPath: nil,
            createdAtMs: nowMs - 100_000, updatedAtMs: nowMs - 1000, turnCount: 4
        )
        harness.search.recent = [summary]
        harness.search.sessionCount = 1
        harness.launch.availability = { source in
            .available(AgentHistoryResumePlan(
                agent: source.agent,
                sessionID: source.nativeSessionID,
                command: "codex resume \(source.nativeSessionID)",
                environment: [:]
            ))
        }
        let pasteboard = harness.pasteboard
        addTeardownBlock { @MainActor in pasteboard.releaseGlobally() }
        let services = AgentHistoryPaletteServices(
            control: harness.control,
            search: harness.search,
            launch: harness.launch,
            excludedFolders: { [] },
            setExcludedFolders: { _ in },
            claudeRetention: { _, completion in
                completion([ClaudeRetentionStatus(
                    configDirectory: URL(fileURLWithPath: "/tmp/agent-history-tests/.claude"),
                    settingsFileURL: URL(fileURLWithPath: "/tmp/agent-history-tests/.claude/settings.json"),
                    effectiveDays: 365, source: .userSettings, readError: nil
                )])
            },
            raiseClaudeRetention: { $1(.success(.alreadySufficient(currentDays: 365))) },
            pasteboard: pasteboard,
            revealInFinder: { _ in },
            fileExists: { _ in false },
            now: { [nowMs] in Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000) }
        )
        let model = AgentHistoryViewModel(
            context: AgentHistoryOpenContext(
                entryPoint: .shortcutOrMenu,
                currentProject: nil,
                initialScope: .all,
                hostWindowID: WindowID("window")
            ),
            services: services,
            theme: AgentHistoryTheme(zenttyTheme: ZenttyTheme.fallback(for: nil)),
            scheduler: harness.scheduler,
            formatting: AgentHistoryFormatting(locale: Locale(identifier: "en_US"))
        )
        model.onRequestClose = { [weak harness] restoreFocus in harness?.closeRequests.append(restoreFocus) }
        addTeardownBlock { @MainActor in model.stop() }
        model.start()
        harness.model = model
        return harness
    }
}
