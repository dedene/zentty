import XCTest

/// `mise run` / `mise x` put the project's tool dirs ahead of every PATH entry
/// that follows mise's first shims dir, so without a boundary an agent started
/// from a mise task skips the Zentty wrapper (#142).
final class ShellIntegrationMiseBoundaryTests: XCTestCase {
    private static let shells: [SSHIntegrationShell] = [.zsh, .bash, .fish, .nu]

    func test_ensure_wrapper_path_marks_mise_shims_boundary_right_after_wrappers() throws {
        let fixture = try makeFixture()
        for shell in Self.shells where shell.executablePath != nil {
            let paths = try runEnsureWrapperPath(
                shell: shell,
                path: [fixture.realBin.path, fixture.miseBin.path, "/usr/bin", "/bin"],
                fixture: fixture
            )

            let expected = [fixture.wrapperDir.path, fixture.marker.path, fixture.realBin.path, fixture.miseBin.path, "/usr/bin", "/bin"]
            XCTAssertEqual(paths.first, expected, "\(shell)")
            XCTAssertEqual(paths.last, expected, "\(shell) must stay stable across prompts")
        }
    }

    func test_ensure_wrapper_path_drops_mise_marker_once_mise_leaves_path() throws {
        let fixture = try makeFixture()
        for shell in Self.shells where shell.executablePath != nil {
            let paths = try runEnsureWrapperPath(
                shell: shell,
                path: [fixture.marker.path, fixture.realBin.path, "/usr/bin", "/bin"],
                fixture: fixture
            )

            XCTAssertEqual(paths.last, [fixture.wrapperDir.path, fixture.realBin.path, "/usr/bin", "/bin"], "\(shell)")
        }
    }

    func test_ensure_wrapper_path_skips_marker_when_user_shims_dir_is_on_path() throws {
        let fixture = try makeFixture()
        let userShims = fixture.root.appendingPathComponent("user-shims", isDirectory: true).path
        for shell in Self.shells where shell.executablePath != nil {
            let paths = try runEnsureWrapperPath(
                shell: shell,
                path: [fixture.realBin.path, fixture.miseBin.path, userShims, "/usr/bin"],
                fixture: fixture,
                extraEnvironment: ["MISE_SHIMS_DIR": userShims]
            )

            XCTAssertEqual(paths.last, [fixture.wrapperDir.path, fixture.realBin.path, fixture.miseBin.path, userShims, "/usr/bin"], "\(shell)")
        }
    }

    func test_ensure_wrapper_path_leaves_existing_system_shims_dir_alone() throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(at: fixture.marker, withIntermediateDirectories: true)
        for shell in Self.shells where shell.executablePath != nil {
            let paths = try runEnsureWrapperPath(
                shell: shell,
                path: [fixture.realBin.path, fixture.miseBin.path, "/usr/bin", fixture.marker.path],
                fixture: fixture
            )

            XCTAssertEqual(paths.last, [fixture.wrapperDir.path, fixture.realBin.path, fixture.miseBin.path, "/usr/bin", fixture.marker.path], "\(shell)")
        }
    }

    func test_mise_run_task_resolves_wrapper_ahead_of_mise_managed_paths() throws {
        guard let miseBin = Self.realMiseDirectory() else {
            throw XCTSkip("mise not installed on this host")
        }
        let fixture = try makeFixture()
        // `_.path` entries share the slot of tool install dirs in a task's PATH,
        // which reproduces a project-local tool without installing one.
        let project = fixture.root.appendingPathComponent("project", isDirectory: true)
        let projectTools = project.appendingPathComponent("tools", isDirectory: true)
        let tasks = project.appendingPathComponent(".mise/tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: projectTools, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: projectTools.appendingPathComponent("codex"))
        try writeExecutable("#!/bin/sh\ncommand -v codex\n", to: tasks.appendingPathComponent("which-codex"))
        try "[env]\n_.path = [\"\(projectTools.path)\"]\n"
            .write(to: project.appendingPathComponent("mise.toml"), atomically: true, encoding: .utf8)

        let miseData = fixture.root.appendingPathComponent("mise-data", isDirectory: true).path
        let result = try runShell(
            .zsh,
            script: """
            PATH=\(quoted(fixture.realBin.path)):\(quoted(miseBin)):/usr/bin:/bin
            _zentty_ensure_wrapper_path
            mise -q -C \(quoted(project.path)) run which-codex
            """,
            fixture: fixture,
            extraEnvironment: [
                "MISE_CACHE_DIR": miseData + "/cache",
                "MISE_CONFIG_DIR": miseData + "/config",
                "MISE_DATA_DIR": miseData,
                "MISE_OFFLINE": "1",
                "MISE_STATE_DIR": miseData + "/state",
                "MISE_TRUSTED_CONFIG_PATHS": project.path,
                "MISE_YES": "1",
            ]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            result.stdout.split(separator: "\n").last.map(String.init),
            fixture.wrapperDir.appendingPathComponent("codex").path,
            result.stderr
        )
    }

    // MARK: - Helpers

    private struct Fixture {
        let root: URL
        let home: URL
        let wrapperDir: URL
        let realBin: URL
        let miseBin: URL
        /// `MISE_SYSTEM_DATA_DIR/shims`, absent unless a test creates it.
        let marker: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = try makeSSHTemporaryDirectory(named: "shell-mise-boundary")
        let fixture = Fixture(
            root: root,
            home: root.appendingPathComponent("home", isDirectory: true),
            wrapperDir: root.appendingPathComponent("wrappers/codex", isDirectory: true),
            realBin: root.appendingPathComponent("real-bin", isDirectory: true),
            miseBin: root.appendingPathComponent("mise-bin", isDirectory: true),
            marker: root.appendingPathComponent("system-mise/shims", isDirectory: true)
        )
        for directory in [fixture.home, fixture.wrapperDir, fixture.realBin, fixture.miseBin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writeExecutable("#!/bin/sh\nexit 0\n", to: fixture.wrapperDir.appendingPathComponent("codex"))
        try writeExecutable("#!/bin/sh\nexit 0\n", to: fixture.realBin.appendingPathComponent("codex"))
        try writeExecutable("#!/bin/sh\nexit 0\n", to: fixture.miseBin.appendingPathComponent("mise"))
        return fixture
    }

    /// Sets PATH, runs `_zentty_ensure_wrapper_path` twice, and returns PATH after each call.
    private func runEnsureWrapperPath(
        shell: SSHIntegrationShell,
        path: [String],
        fixture: Fixture,
        extraEnvironment: [String: String] = [:]
    ) throws -> [[String]] {
        let joined = path.joined(separator: ":")
        let script: String
        switch shell {
        case .zsh, .bash, .bash5:
            script = """
            PATH=\(quoted(joined))
            _zentty_ensure_wrapper_path; printf 'path=%s\\n' "$PATH"
            _zentty_ensure_wrapper_path; printf 'path=%s\\n' "$PATH"
            """
        case .fish:
            script = """
            set -gx PATH \(path.map(quoted).joined(separator: " "))
            _zentty_ensure_wrapper_path; printf 'path=%s\\n' (string join : $PATH)
            _zentty_ensure_wrapper_path; printf 'path=%s\\n' (string join : $PATH)
            """
        case .nu:
            script = """
            $env.PATH = [\(path.map { "'\($0)'" }.joined(separator: " "))]
            _zentty_ensure_wrapper_path; print $"path=($env.PATH | str join ':')"
            _zentty_ensure_wrapper_path; print $"path=($env.PATH | str join ':')"
            """
        }
        let result = try runShell(shell, script: script, fixture: fixture, extraEnvironment: extraEnvironment)
        XCTAssertEqual(result.status, 0, "\(shell): \(result.stderr)")
        let paths = result.stdout
            .split(separator: "\n")
            .filter { $0.hasPrefix("path=") }
            .map { $0.dropFirst("path=".count).split(separator: ":").map(String.init) }
        XCTAssertEqual(paths.count, 2, "\(shell): \(result.stdout)\n\(result.stderr)")
        return paths
    }

    private func runShell(
        _ shell: SSHIntegrationShell,
        script: String,
        fixture: Fixture,
        extraEnvironment: [String: String] = [:]
    ) throws -> ShellRunResult {
        guard let executable = shell.executablePath else {
            throw XCTSkip("\(shell) not available on this host")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = shell.arguments(for: "source \(quoted(shell.integrationScriptURL.path))\n\(script)\n")
        process.currentDirectoryURL = fixture.root
        var environment = [
            "HOME": fixture.home.path,
            "LC_ALL": "C",
            "MISE_SYSTEM_DATA_DIR": fixture.marker.deletingLastPathComponent().path,
            "PATH": "/usr/bin:/bin",
            "TTY": "/dev/null",
            "USER": ProcessInfo.processInfo.environment["USER"] ?? "tester",
            "ZENTTY_ALL_WRAPPER_BIN_DIRS": fixture.wrapperDir.path,
            "ZENTTY_FORCE_SHELL_INTEGRATION": "1",
            "ZENTTY_SHELL_INTEGRATION": "0",
        ]
        extraEnvironment.forEach { environment[$0.key] = $0.value }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ShellRunResult(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            status: process.terminationStatus
        )
    }

    private static func realMiseDirectory() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
            .first { FileManager.default.isExecutableFile(atPath: "\($0)/mise") }
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func quoted(_ value: String) -> String {
        SSHStubScripts.singleQuoted(value)
    }
}
