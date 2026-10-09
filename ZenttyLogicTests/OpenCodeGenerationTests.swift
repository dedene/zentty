import Foundation
import XCTest
@testable import Zentty

@MainActor
final class OpenCodeGenerationTests: XCTestCase {
    // MARK: - Version parsing

    func test_parse_recognizes_v1_bare_version() {
        XCTAssertEqual(OpenCodeGeneration.parse(versionOutput: "1.18.35\n"), .v1)
    }

    func test_parse_recognizes_v2_styled_version() {
        XCTAssertEqual(OpenCodeGeneration.parse(versionOutput: "\u{1B}[1mopencode\u{1B}[0m \u{1B}[2mv2.0.26\u{1B}[0m\n"), .v2)
    }

    func test_parse_returns_nil_without_version() {
        XCTAssertNil(OpenCodeGeneration.parse(versionOutput: "Error: postinstall script was not run"))
    }

    // MARK: - Standalone argument injection

    func test_standalone_arguments_prepends_for_root_launches() {
        XCTAssertEqual(OpenCodeGeneration.standaloneArguments([]), ["--standalone"])
        XCTAssertEqual(
            OpenCodeGeneration.standaloneArguments(["--session", "ses_abc"]),
            ["--standalone", "--session", "ses_abc"]
        )
        XCTAssertEqual(OpenCodeGeneration.standaloneArguments(["/tmp/project"]), ["--standalone", "/tmp/project"])
    }

    func test_standalone_arguments_inserts_after_session_subcommands() {
        XCTAssertEqual(OpenCodeGeneration.standaloneArguments(["run", "hello"]), ["run", "--standalone", "hello"])
        XCTAssertEqual(
            OpenCodeGeneration.standaloneArguments(["--log-level", "debug", "run", "hello"]),
            ["--log-level", "debug", "run", "--standalone", "hello"]
        )
        XCTAssertEqual(OpenCodeGeneration.standaloneArguments(["mini"]), ["mini", "--standalone"])
    }

    func test_standalone_arguments_skips_flag_values_that_look_like_subcommands() {
        XCTAssertEqual(
            OpenCodeGeneration.standaloneArguments(["--prompt", "run", "/tmp/project"]),
            ["--standalone", "--prompt", "run", "/tmp/project"]
        )
    }

    func test_standalone_arguments_leaves_utility_and_explicit_server_modes_alone() {
        for arguments in [
            ["auth", "login"],
            ["models"],
            ["serve"],
            ["--server", "http://127.0.0.1:4096"],
            ["--server=http://127.0.0.1:4096", "run", "hi"],
            ["run", "--standalone", "hi"],
            ["--version"],
            ["run", "--help"],
        ] {
            XCTAssertEqual(OpenCodeGeneration.standaloneArguments(arguments), arguments, "\(arguments)")
        }
    }

    // MARK: - Bootstrap

    func test_bootstrap_launches_opencode_v2_standalone_with_v2_plugin() throws {
        let fixture = try makeBootstrapFixture(named: "opencode-v2", versionOutput: "opencode v2.0.26")

        let plan = try makePlan(fixture: fixture, arguments: ["run", "hello"])

        XCTAssertEqual(plan.arguments, ["run", "--standalone", "hello"])
        XCTAssertEqual(try overlayPluginContents(plan), Self.v2PluginMarker)
    }

    func test_bootstrap_keeps_opencode_v1_arguments_and_v1_plugin() throws {
        let fixture = try makeBootstrapFixture(named: "opencode-v1", versionOutput: "1.18.35")

        let plan = try makePlan(fixture: fixture, arguments: ["run", "hello"])

        XCTAssertEqual(plan.arguments, ["run", "hello"])
        XCTAssertEqual(try overlayPluginContents(plan), Self.v1PluginMarker)
    }

    func test_bootstrap_falls_back_to_v1_when_version_probe_fails() throws {
        let fixture = try makeBootstrapFixture(named: "opencode-broken", versionOutput: nil)

        let plan = try makePlan(fixture: fixture, arguments: [])

        XCTAssertEqual(plan.arguments, [])
        XCTAssertEqual(try overlayPluginContents(plan), Self.v1PluginMarker)
    }

    // MARK: - v2 plugin

    func test_repository_opencode_v2_plugin_maps_server_events_to_canonical_events() throws {
        guard let nodePath = try resolvedExecutable(named: "node") else {
            throw XCTSkip("node is not available")
        }

        let pluginURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZenttyResources/opencode/v2-plugins/zentty-opencode-zentty.js", isDirectory: false)
        let scratch = try makeTemporaryDirectory(named: "opencode-v2-plugin-harness")
        let fakeCLIURL = scratch.appendingPathComponent("zentty", isDirectory: false)
        let captureURL = scratch.appendingPathComponent("canonical-events.jsonl", isDirectory: false)
        let harnessURL = scratch.appendingPathComponent("harness.mjs", isDirectory: false)

        try """
        #!/bin/sh
        cat >> "$ZENTTY_CAPTURE_LOG"
        printf '\\n' >> "$ZENTTY_CAPTURE_LOG"
        """.write(to: fakeCLIURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLIURL.path)

        try """
        const plugin = (await import(process.env.ZENTTY_PLUGIN_URL)).default
        const events = [
          { type: "session.created", data: { sessionID: "ses_parent" } },
          { type: "session.created", data: { sessionID: "ses_child", parentID: "ses_parent" } },
          { type: "session.execution.started", data: { sessionID: "ses_parent" } },
          { type: "session.execution.started", data: { sessionID: "ses_child" } },
          { type: "session.execution.succeeded", data: { sessionID: "ses_child" } },
          { type: "permission.asked", data: { id: "per_1", sessionID: "ses_parent", action: "shell", resources: ["printf ok"] } },
          { type: "permission.replied", data: { sessionID: "ses_parent", requestID: "per_1", reply: "once" } },
          { type: "form.created", data: { form: { id: "frm_1", sessionID: "ses_parent", title: "Pick one", fields: [{ key: "c", type: "multiselect", options: [{ label: "A" }, { label: "B" }] }] } } },
          { type: "form.replied", data: { id: "frm_1", sessionID: "ses_parent", answer: {} } },
          { type: "session.compaction.started", data: { sessionID: "ses_parent", reason: "manual" } },
          { type: "session.compaction.ended", data: { sessionID: "ses_parent" } },
          { type: "session.text.delta", data: { sessionID: "ses_parent" } },
          { type: "session.execution.succeeded", data: { sessionID: "ses_parent" } },
        ]
        let finish
        const drained = new Promise((resolve) => { finish = resolve })
        const ctx = {
          location: { directory: "/tmp/project" },
          event: {
            subscribe: async function* () {
              for (const event of events) yield event
              finish()
            },
          },
        }
        const cleanup = await plugin.setup(ctx)
        await drained
        await new Promise((resolve) => setTimeout(resolve, 200))
        cleanup?.()
        """.write(to: harnessURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = [harnessURL.path]
        process.environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "ZENTTY_CLI_BIN": fakeCLIURL.path,
            "ZENTTY_CAPTURE_LOG": captureURL.path,
            "ZENTTY_INSTANCE_SOCKET": scratch.appendingPathComponent("zentty.sock").path,
            "ZENTTY_PANE_ID": "pane-under-test",
            "ZENTTY_PANE_TOKEN": "pane-token-under-test",
            "ZENTTY_PLUGIN_URL": pluginURL.absoluteString,
            "ZENTTY_WORKLANE_ID": "worklane-under-test",
        ]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail("OpenCode v2 plugin harness failed: \(error)")
            return
        }

        let canonicalEvents = try String(contentsOf: captureURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> [String: Any]? in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }

        XCTAssertEqual(canonicalEvents.compactMap { $0["event"] as? String }, [
            "agent.running",
            "agent.needs-input",
            "agent.input-resolved",
            "agent.needs-input",
            "agent.input-resolved",
            "agent.compacting",
            "agent.compacted",
            "agent.idle",
        ])
        XCTAssertTrue(canonicalEvents.allSatisfy {
            ($0["session"] as? [String: Any])?["id"] as? String == "ses_parent"
        })
        let interactions = canonicalEvents.compactMap {
            (($0["state"] as? [String: Any])?["interaction"] as? [String: Any])
        }
        XCTAssertEqual(interactions.first?["kind"] as? String, "approval")
        XCTAssertEqual(interactions.first?["text"] as? String, "shell: printf ok")
        XCTAssertEqual(interactions.last?["kind"] as? String, "decision")
        XCTAssertEqual(interactions.last?["text"] as? String, "Pick one\n[A] [B]")
        XCTAssertEqual(
            (canonicalEvents.first?["context"] as? [String: Any])?["workingDirectory"] as? String,
            "/tmp/project"
        )
    }

    // MARK: - Helpers

    private static let v1PluginMarker = "// v1 plugin\n"
    private static let v2PluginMarker = "// v2 plugin\n"

    private struct BootstrapFixture {
        let executableURL: URL
        let bundle: Bundle
        let runtimeDirectory: URL
    }

    private func makeBootstrapFixture(named name: String, versionOutput: String?) throws -> BootstrapFixture {
        let root = try makeTemporaryDirectory(named: name)
        let resources = root
            .appendingPathComponent("\(name).app/Contents/Resources/opencode", isDirectory: true)
        for (directory, marker) in [("plugins", Self.v1PluginMarker), ("v2-plugins", Self.v2PluginMarker)] {
            let directoryURL = resources.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try marker.write(
                to: directoryURL.appendingPathComponent("zentty-opencode-zentty.js", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        }
        let bundleURL = root.appendingPathComponent("\(name).app", isDirectory: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>be.zenjoy.zentty.tests.\(name)</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """.write(
            to: bundleURL.appendingPathComponent("Contents/Info.plist", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let executableURL = binDirectory.appendingPathComponent("opencode", isDirectory: false)
        let body = versionOutput.map { "printf '%s\\n' '\($0)'" } ?? "echo 'postinstall was not run' >&2; exit 1"
        try "#!/bin/sh\n\(body)\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        return BootstrapFixture(
            executableURL: executableURL,
            bundle: try XCTUnwrap(Bundle(url: bundleURL)),
            runtimeDirectory: try makeTemporaryDirectory(named: "\(name)-runtime")
        )
    }

    private func makePlan(fixture: BootstrapFixture, arguments: [String]) throws -> AgentLaunchPlan {
        let sourceConfig = try makeTemporaryDirectory(named: "opencode-source-config")
        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: arguments,
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": fixture.executableURL.path,
                "ZENTTY_OPENCODE_BASE_CONFIG_DIR": sourceConfig.path,
            ],
            expectsResponse: true,
            tool: .opencode
        )
        return try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: fixture.runtimeDirectory,
            bundle: fixture.bundle,
            appConfigProvider: { AppConfig.default }
        )
    }

    private func overlayPluginContents(_ plan: AgentLaunchPlan) throws -> String {
        let overlay = try XCTUnwrap(plan.setEnvironment["OPENCODE_CONFIG_DIR"])
        return try String(
            contentsOf: URL(fileURLWithPath: overlay, isDirectory: true)
                .appendingPathComponent("plugins/zentty-opencode-zentty.js", isDirectory: false),
            encoding: .utf8
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func resolvedExecutable(named name: String) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "command -v '\(name)'"]
        process.environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }
}
