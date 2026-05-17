@testable import Zentty
import Foundation
import XCTest

final class TaskRunnerDiscoveryTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zentty-task-runners-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        try super.tearDownWithError()
    }

    func testDiscoversPackageScriptsFromFocusedWorkingDirectoryAncestry() throws {
        let repo = try makeDirectory("repo")
        try write(
            """
            {
              "packageManager": "pnpm@10.0.0",
              "scripts": {
                "dev": "vite --host 0.0.0.0",
                "test": "vitest"
              }
            }
            """,
            to: repo.appendingPathComponent("package.json")
        )
        let focused = try makeDirectory("repo/apps/web/src")
        let service = TaskRunnerDiscoveryService()

        let actions = try service.discover(focusedWorkingDirectory: focused.path)

        XCTAssertEqual(actions.map(\.title), ["dev", "test"])
        XCTAssertEqual(actions.map(\.sourceKind), [.packageScript, .packageScript])
        XCTAssertEqual(actions.map(\.executionCommand), ["pnpm run dev", "pnpm run test"])
        XCTAssertEqual(actions.map(\.workingDirectory), [repo.path, repo.path])
        XCTAssertTrue(actions.allSatisfy(\.isEnabled))
        XCTAssertEqual(actions[0].subtitle, "package.json • pnpm run dev")
    }

    func testKeepsPackageScriptsEnabledWhenRunnerIsOnlyAvailableInShellPath() throws {
        let repo = try makeDirectory("repo")
        try write(
            """
            {
              "packageManager": "bun@1.2.0",
              "scripts": { "dev": "bun --hot src/index.ts" }
            }
            """,
            to: repo.appendingPathComponent("package.json")
        )
        let service = TaskRunnerDiscoveryService()

        let actions = try service.discover(focusedWorkingDirectory: repo.path)

        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].executionCommand, "bun run dev")
        XCTAssertNil(actions[0].disabledReason)
        XCTAssertTrue(actions[0].isEnabled)
    }

    func testDiscoversTaskfileTasksAndLocalStaticIncludes() throws {
        let repo = try makeDirectory("repo")
        try write(
            """
            version: '3'
            includes:
              api: ./tasks/api.yml
              web:
                taskfile: ./tasks/web.yml
            tasks:
              build:
                desc: Build everything
                cmds:
                  - go build ./...
              prompt:
                requires:
                  vars:
                    - NAME
                cmds:
                  - echo "{{.NAME}}"
            """,
            to: repo.appendingPathComponent("Taskfile.yml")
        )
        try makeDirectory("repo/tasks")
        try write(
            """
            version: '3'
            tasks:
              test:
                desc: Run API tests
                cmds:
                  - go test ./...
            """,
            to: repo.appendingPathComponent("tasks/api.yml")
        )
        try write(
            """
            version: '3'
            tasks:
              check:
                desc: Run web checks
                cmds:
                  - pnpm check
            """,
            to: repo.appendingPathComponent("tasks/web.yml")
        )
        let service = TaskRunnerDiscoveryService()

        let actions = try service.discover(focusedWorkingDirectory: repo.path)

        XCTAssertEqual(actions.map(\.title), ["build", "prompt", "api:test", "web:check"])
        XCTAssertEqual(actions.map(\.executionCommand), ["task build", "task prompt", "task api:test", "task web:check"])
        XCTAssertEqual(actions[0].description, "Build everything")
        XCTAssertEqual(actions[1].disabledReason, .unsupported("Task requires variables: NAME"))
        XCTAssertEqual(actions[2].description, "Run API tests")
        XCTAssertEqual(actions[3].description, "Run web checks")
    }

    func testDiscoversVSCodeTasksWithOsxOverridesAndDisablesUnsupportedVariables() throws {
        let repo = try makeDirectory("repo")
        let vscode = try makeDirectory("repo/.vscode")
        try write(
            """
            {
              // JSONC is accepted.
              "version": "2.0.0",
              "tasks": [
                {
                  "label": "lint",
                  "type": "shell",
                  "command": "npm",
                  "args": ["run", "lint:strict mode"],
                  "options": { "env": { "NODE_ENV": "test" } },
                  "osx": { "command": "pnpm", "args": ["lint:strict mode"] }
                },
                {
                  "label": "lint",
                  "type": "shell",
                  "command": "pnpm",
                  "args": ["lint:fix"]
                },
                {
                  "label": "open-file",
                  "type": "shell",
                  "command": "cat ${file}"
                },
              ]
            }
            """,
            to: vscode.appendingPathComponent("tasks.json")
        )
        let service = TaskRunnerDiscoveryService()

        let actions = try service.discover(focusedWorkingDirectory: repo.path)

        XCTAssertEqual(actions.map(\.title), ["lint", "lint", "open-file"])
        XCTAssertEqual(actions[0].executionCommand, "pnpm 'lint:strict mode'")
        XCTAssertEqual(actions[0].environment, ["NODE_ENV": "test"])
        XCTAssertEqual(actions[1].executionCommand, "pnpm lint:fix")
        XCTAssertNotEqual(actions[0].id, actions[1].id)
        XCTAssertEqual(actions[2].disabledReason, .unsupported("Unsupported VS Code variable: ${file}"))
    }

    func testDiscoversJustMakeAndMiseTasks() throws {
        let repo = try makeDirectory("repo")
        try write(
            """
            # Public recipe
            test:
              swift test

            deploy target:
              ./deploy {{target}}
            """,
            to: repo.appendingPathComponent("justfile")
        )
        try write(
            """
            .PHONY: build clean
            build: ## Build app
            \tswift build
            internal.o: internal.c
            """,
            to: repo.appendingPathComponent("Makefile")
        )
        try write(
            """
            [tasks.lint]
            description = "Lint sources"
            run = "swiftlint"

            [tasks]
            fmt = "swiftformat ."
            """,
            to: repo.appendingPathComponent("mise.toml")
        )
        try makeDirectory("repo/mise-tasks")
        try write("#!/usr/bin/env bash\necho dev\n", to: repo.appendingPathComponent("mise-tasks/dev"))
        try makeDirectory("repo/.mise/tasks")
        try write("#!/usr/bin/env bash\necho ship\n", to: repo.appendingPathComponent(".mise/tasks/ship"))
        let service = TaskRunnerDiscoveryService()

        let actions = try service.discover(focusedWorkingDirectory: repo.path)

        XCTAssertEqual(
            actions.map { "\($0.sourceKind.rawValue):\($0.title):\($0.executionCommand):\($0.disabledReason?.displayText ?? "")" },
            [
                "justfile:test:just test:",
                "justfile:deploy:just deploy:Task requires parameters: target",
                "makefile:build:make build:",
                "makefile:clean:make clean:",
                "mise:lint:mise run lint:",
                "mise:fmt:mise run fmt:",
                "mise:dev:mise run dev:",
                "mise:ship:mise run ship:",
            ]
        )
    }

    func testMalformedChildTaskSourceDoesNotHideParentSources() throws {
        let repo = try makeDirectory("repo")
        let app = try makeDirectory("repo/app")
        try write("{ \"scripts\": { \"test\": \"root-test\" } }", to: repo.appendingPathComponent("package.json"))
        try write("{ invalid json", to: app.appendingPathComponent("package.json"))
        let service = TaskRunnerDiscoveryService()

        let actions = try service.discover(focusedWorkingDirectory: app.path)

        XCTAssertEqual(actions.map(\.title), ["test"])
        XCTAssertEqual(actions[0].sourcePath, repo.appendingPathComponent("package.json").path)
    }

    func testRanksNearestTaskSourcesBeforeParentSourcesAndKeepsDuplicateTitles() throws {
        let repo = try makeDirectory("repo")
        let app = try makeDirectory("repo/app")
        try write("{ \"scripts\": { \"test\": \"root-test\" } }", to: repo.appendingPathComponent("package.json"))
        try write("{ \"scripts\": { \"test\": \"app-test\" } }", to: app.appendingPathComponent("package.json"))
        let service = TaskRunnerDiscoveryService()

        let actions = try service.discover(focusedWorkingDirectory: app.path)

        XCTAssertEqual(actions.map(\.title), ["test", "test"])
        XCTAssertEqual(actions.map(\.sourcePath), [
            app.appendingPathComponent("package.json").path,
            repo.appendingPathComponent("package.json").path,
        ])
        XCTAssertNotEqual(actions[0].id, actions[1].id)
    }

    @discardableResult
    private func makeDirectory(_ relativePath: String) throws -> URL {
        let url = temporaryRoot.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
