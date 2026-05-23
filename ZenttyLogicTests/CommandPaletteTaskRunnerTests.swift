import XCTest
@testable import Zentty

final class CommandPaletteTaskRunnerTests: XCTestCase {
    func test_buildTaskRunnerItems_keepsDisabledTasksVisibleAndSearchable() {
        let enabled = makeAction(
            id: "package|/repo/package.json|dev",
            title: "dev",
            sourceKind: .packageScript,
            sourcePath: "/repo/package.json",
            command: "pnpm run dev",
            disabledReason: nil
        )
        let disabled = makeAction(
            id: "taskfile|/repo/Taskfile.yml|deploy",
            title: "deploy",
            sourceKind: .taskfile,
            sourcePath: "/repo/Taskfile.yml",
            command: "task deploy",
            disabledReason: .unsupported("Task requires variables: TARGET")
        )

        let items = CommandPaletteItemBuilder.buildTaskRunnerItems(actions: [enabled, disabled])
        let resolved = CommandPaletteResultsResolver.resolve(
            searchText: "deploy target",
            items: items,
            recentItems: []
        )

        XCTAssertEqual(items.map(\.id), [.taskRunner(enabled.id), .taskRunner(disabled.id)])
        XCTAssertEqual(items.map(\.title), ["Run task: dev", "Run task: deploy"])
        XCTAssertTrue(items[0].isEnabled)
        XCTAssertFalse(items[1].isEnabled)
        XCTAssertEqual(items[1].category, "Task disabled")
        XCTAssertEqual(resolved.items.first?.item.id, .taskRunner(disabled.id))
    }

    private func makeAction(
        id: String,
        title: String,
        sourceKind: TaskRunnerSourceKind,
        sourcePath: String,
        command: String,
        disabledReason: TaskRunnerDisabledReason?
    ) -> TaskRunnerAction {
        TaskRunnerAction(
            id: id,
            title: title,
            description: nil,
            sourceKind: sourceKind,
            sourcePath: sourcePath,
            sourceRoot: "/repo",
            workingDirectory: "/repo",
            executionCommand: command,
            commandPreview: command,
            environment: [:],
            disabledReason: disabledReason
        )
    }
}
