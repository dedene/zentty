import Foundation
import XCTest
@testable import Zentty

/// Manifest-agent coverage: `AgentBootstrapTool.manifest` resolution, the Kilo
/// (opencode-plugin family) launch plan, canonical family plans, status
/// recognition, consent classification, resume commands, and runtime wrapper
/// materialization.
final class AgentManifestAgentTests: XCTestCase {
    override func setUp() {
        super.setUp()
        let registry = Self.kiloRegistry
        AgentManifestRegistry.provider = { registry }
        AgentManifestRegistry.provider = { registry }
        addTeardownBlock {
            AgentManifestRegistry.provider = { .shared }
            AgentManifestRegistry.provider = { .shared }
        }
    }

    private static let kiloManifest = AgentManifest(
        schemaVersion: 1,
        id: "kilo",
        displayName: "Kilo Code",
        binaries: ["kilo"],
        family: .opencodePlugin,
        opencodePlugin: AgentManifest.OpenCodePluginOptions(
            envPrefix: "KILO",
            configDirName: "kilo",
            siblingBinary: ".kilo"
        ),
        passthrough: AgentManifest.Passthrough(
            subcommands: ["auth", "session", "debug"],
            flags: ["-h", "--help", "-v", "--version"]
        ),
        resume: AgentManifest.Resume(
            command: "kilo --session {sessionId}",
            sessionIdPattern: "^ses_[A-Za-z0-9]+$"
        )
    )

    private static let kiloRegistry = AgentManifestRegistry(manifests: [kiloManifest])

    /// `AppConfig.default` enables theme sync; these tests opt out explicitly so
    /// the plan does not depend on the machine's real `~/.config/zentty`.
    private static var syncOffConfig: AppConfig {
        var config = AppConfig.default
        config.appearance.syncOpenCodeThemeWithTerminal = false
        return config
    }

    // MARK: - AgentBootstrapTool

    func test_init_id_resolves_builtin_and_manifest() {
        XCTAssertEqual(AgentBootstrapTool(id: "claude"), .claude)
        XCTAssertEqual(AgentBootstrapTool(id: "small-harness"), .smallHarness)
        XCTAssertEqual(AgentBootstrapTool(id: "kilo"), .manifest("kilo"))
        XCTAssertNil(AgentBootstrapTool(id: "not-a-tool"))
    }

    func test_codable_round_trip_uses_plain_string_id() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for tool in [AgentBootstrapTool.claude, .opencode, .manifest("kilo")] {
            let data = try encoder.encode(tool)
            XCTAssertEqual(String(data: data, encoding: .utf8), "\"\(tool.id)\"")
            XCTAssertEqual(try decoder.decode(AgentBootstrapTool.self, from: data), tool)
        }
    }

    func test_codable_decode_unknown_id_throws() {
        let data = Data("\"definitely-not-an-agent\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AgentBootstrapTool.self, from: data))
    }

    func test_wrapped_agent_for_command_matches_manifest_binary() {
        XCTAssertEqual(
            AgentBootstrapTool.wrappedAgent(forCommand: "kilo --session ses_x"),
            .manifest("kilo")
        )
        XCTAssertEqual(
            AgentBootstrapTool.wrappedAgent(forCommand: "env FOO=1 kilo"),
            .manifest("kilo")
        )
        XCTAssertEqual(
            AgentBootstrapTool.wrappedAgent(forCommand: "/usr/local/bin/kilo run"),
            .manifest("kilo")
        )
        XCTAssertNil(AgentBootstrapTool.wrappedAgent(forCommand: "vim notes.txt"))
    }

    func test_manifest_real_binary_names() {
        XCTAssertEqual(AgentBootstrapTool.manifest("kilo").realBinaryNames, ["kilo"])
    }

    // MARK: - Kilo launch plan (opencode-plugin family)

    func test_kilo_plan_builds_overlay_and_prelaunch_event() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-kilo-runtime")
        let bundle = try makePluginBundle(named: "agent-launch-kilo-bundle")

        let sourceConfigDirectory = try makeTemporaryDirectory(named: "agent-launch-kilo-source")
        try "user-config".write(
            to: sourceConfigDirectory.appendingPathComponent("kilo.jsonc", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["run", "hello"],
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": "/usr/local/bin/kilo",
                "ZENTTY_KILO_BASE_CONFIG_DIR": sourceConfigDirectory.path,
            ],
            expectsResponse: true,
            tool: .manifest("kilo")
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: makeTarget(),
            runtimeDirectoryURL: runtimeDirectory,
            bundle: bundle,
            appConfigProvider: { Self.syncOffConfig }
        )

        XCTAssertEqual(plan.executablePath, "/usr/local/bin/kilo")
        XCTAssertEqual(plan.setEnvironment["ZENTTY_AGENT_TOOL"], "kilo")
        XCTAssertEqual(plan.setEnvironment["ZENTTY_AGENT_CANONICAL_NAME"], "Kilo Code")
        XCTAssertEqual(
            plan.setEnvironment["ZENTTY_KILO_BASE_CONFIG_DIR"],
            sourceConfigDirectory.path
        )

        let overlayConfigDirectory = URL(
            fileURLWithPath: try XCTUnwrap(plan.setEnvironment["KILO_CONFIG_DIR"]),
            isDirectory: true
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: overlayConfigDirectory
                    .appendingPathComponent("plugins", isDirectory: true)
                    .appendingPathComponent("zentty-opencode-zentty.js", isDirectory: false)
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: overlayConfigDirectory
                    .appendingPathComponent("kilo.jsonc", isDirectory: false)
                    .path
            )
        )
        XCTAssertNil(plan.setEnvironment["OPENCODE_CONFIG_DIR"])
        XCTAssertNil(plan.setEnvironment["XDG_CONFIG_HOME"])
        XCTAssertNil(plan.setEnvironment["ZENTTY_AGENT_RESTORE_ENV"])

        let action = try XCTUnwrap(plan.preLaunchActions.first)
        XCTAssertEqual(action.subcommand, "agent-event")
        let sessionStart = try XCTUnwrap(action.standardInput)
        XCTAssertTrue(sessionStart.contains("\"name\":\"Kilo Code\""))
        XCTAssertTrue(sessionStart.contains(AgentIPCProtocol.selfPIDPlaceholder))
    }

    func test_kilo_plan_resolves_dot_kilo_sibling_binary() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-kilo-sibling-runtime")
        let bundle = try makePluginBundle(named: "agent-launch-kilo-sibling-bundle")

        let binDirectory = try makeTemporaryDirectory(named: "agent-launch-kilo-sibling-bin")
        let shimURL = binDirectory.appendingPathComponent("kilo", isDirectory: false)
        try "#!/usr/bin/env node\n".write(to: shimURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimURL.path)
        let siblingURL = binDirectory.appendingPathComponent(".kilo", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: siblingURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: siblingURL.path)

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: [],
            standardInput: nil,
            environment: ["ZENTTY_REAL_BINARY": shimURL.path],
            expectsResponse: true,
            tool: .manifest("kilo")
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: makeTarget(),
            runtimeDirectoryURL: runtimeDirectory,
            bundle: bundle,
            appConfigProvider: { Self.syncOffConfig }
        )

        XCTAssertEqual(plan.executablePath, siblingURL.path)
    }

    func test_kilo_plan_resolves_dot_kilo_sibling_through_symlink() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-kilo-link-runtime")
        let bundle = try makePluginBundle(named: "agent-launch-kilo-link-bundle")

        let shimRoot = try makeTemporaryDirectory(named: "agent-launch-kilo-link-shim")
        let realRoot = try makeTemporaryDirectory(named: "agent-launch-kilo-link-real")
        let realShimURL = realRoot.appendingPathComponent("kilo", isDirectory: false)
        try "#!/usr/bin/env node\n".write(to: realShimURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realShimURL.path)
        let siblingURL = realRoot.appendingPathComponent(".kilo", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: siblingURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: siblingURL.path)
        let linkURL = shimRoot.appendingPathComponent("kilo", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realShimURL)

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: [],
            standardInput: nil,
            environment: ["ZENTTY_REAL_BINARY": linkURL.path],
            expectsResponse: true,
            tool: .manifest("kilo")
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: makeTarget(),
            runtimeDirectoryURL: runtimeDirectory,
            bundle: bundle,
            appConfigProvider: { Self.syncOffConfig }
        )

        XCTAssertEqual(plan.executablePath, siblingURL.path)
    }

    func test_kilo_plan_theme_sync_sets_xdg_and_tui_config() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-kilo-sync-runtime")
        let bundle = try makePluginBundle(named: "agent-launch-kilo-sync-bundle")

        var appConfig = AppConfig.default
        appConfig.appearance.syncOpenCodeThemeWithTerminal = true

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: [],
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": "/usr/local/bin/kilo",
                "HOME": try makeTemporaryDirectory(named: "agent-launch-kilo-sync-home").path,
            ],
            expectsResponse: true,
            tool: .manifest("kilo")
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: makeTarget(),
            runtimeDirectoryURL: runtimeDirectory,
            bundle: bundle,
            appConfigProvider: { appConfig }
        )

        let xdgConfigHome = try XCTUnwrap(plan.setEnvironment["XDG_CONFIG_HOME"])
        let xdgStateHome = try XCTUnwrap(plan.setEnvironment["XDG_STATE_HOME"])
        let kiloConfigDirectory = try XCTUnwrap(plan.setEnvironment["KILO_CONFIG_DIR"])
        let kiloTUIConfig = try XCTUnwrap(plan.setEnvironment["KILO_TUI_CONFIG"])

        XCTAssertEqual(
            kiloConfigDirectory,
            URL(fileURLWithPath: xdgConfigHome, isDirectory: true)
                .appendingPathComponent("kilo", isDirectory: true)
                .path
        )
        XCTAssertEqual(
            kiloTUIConfig,
            URL(fileURLWithPath: kiloConfigDirectory, isDirectory: true)
                .appendingPathComponent("tui.json", isDirectory: false)
                .path
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: kiloConfigDirectory, isDirectory: true)
                    .appendingPathComponent("plugins", isDirectory: true)
                    .appendingPathComponent("zentty-opencode-zentty.js", isDirectory: false)
                    .path
            )
        )
        // The state overlay leaf uses the manifest's configDirName, not "opencode".
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: xdgStateHome, isDirectory: true)
                    .appendingPathComponent("kilo", isDirectory: true)
                    .path
            )
        )
    }

    // MARK: - Canonical family

    func test_canonical_plan_expands_cli_bin_and_sends_session_start() throws {
        let manifest = AgentManifest(
            schemaVersion: 1,
            id: "demo",
            displayName: "Demo Agent",
            binaries: ["demo"],
            family: .canonical,
            canonical: AgentManifest.CanonicalOptions(
                env: ["DEMO_BRIDGE": "{cliBin}"],
                prependArguments: ["--bridge", "{cliBin}"]
            )
        )
        let registry = AgentManifestRegistry(manifests: [manifest])
        AgentManifestRegistry.provider = { registry }

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["chat"],
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": "/usr/local/bin/demo",
                "ZENTTY_CLI_BIN": "/app/bin/zentty",
            ],
            expectsResponse: true,
            tool: .manifest("demo")
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: makeTarget(),
            runtimeDirectoryURL: try makeTemporaryDirectory(named: "agent-launch-canonical-runtime")
        )

        XCTAssertEqual(plan.arguments, ["--bridge", "/app/bin/zentty", "chat"])
        XCTAssertEqual(plan.setEnvironment["DEMO_BRIDGE"], "/app/bin/zentty")
        XCTAssertEqual(plan.setEnvironment["ZENTTY_AGENT_TOOL"], "demo")
        XCTAssertEqual(plan.setEnvironment["ZENTTY_AGENT_CANONICAL_NAME"], "Demo Agent")
        let action = try XCTUnwrap(plan.preLaunchActions.first)
        XCTAssertEqual(action.subcommand, "agent-event")
        XCTAssertTrue(action.standardInput?.contains("\"name\":\"Demo Agent\"") == true)
    }

    func test_canonical_plan_without_cli_bin_falls_back_to_direct_exec() throws {
        let manifest = AgentManifest(
            schemaVersion: 1,
            id: "demo",
            displayName: "Demo Agent",
            binaries: ["demo"],
            family: .canonical,
            canonical: AgentManifest.CanonicalOptions(
                env: ["DEMO_BRIDGE": "{cliBin}"],
                prependArguments: ["--bridge", "{cliBin}"]
            )
        )
        let registry = AgentManifestRegistry(manifests: [manifest])
        AgentManifestRegistry.provider = { registry }

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["chat"],
            standardInput: nil,
            environment: ["ZENTTY_REAL_BINARY": "/usr/local/bin/demo"],
            expectsResponse: true,
            tool: .manifest("demo")
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: makeTarget(),
            runtimeDirectoryURL: try makeTemporaryDirectory(named: "agent-launch-canonical-direct-runtime")
        )

        XCTAssertEqual(plan.executablePath, "/usr/local/bin/demo")
        XCTAssertEqual(plan.arguments, ["chat"])
        XCTAssertTrue(plan.setEnvironment.isEmpty)
        XCTAssertTrue(plan.preLaunchActions.isEmpty)
    }

    func test_unknown_manifest_id_throws_invalid_message() {
        AgentManifestRegistry.provider = { AgentManifestRegistry(manifests: []) }

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: [],
            standardInput: nil,
            environment: ["ZENTTY_REAL_BINARY": "/usr/local/bin/ghost"],
            expectsResponse: true,
            tool: .manifest("ghost")
        )

        XCTAssertThrowsError(
            try AgentLaunchBootstrap.makePlan(
                request: request,
                target: makeTarget(),
                runtimeDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            )
        ) { error in
            guard case AgentIPCError.invalidMessage = error else {
                XCTFail("expected invalidMessage, got \(error)")
                return
            }
        }
    }

    // MARK: - AgentTool recognition + consent

    func test_resolve_known_tool_recognizes_manifest_agent() {
        XCTAssertEqual(AgentTool.resolveKnown(named: "kilo"), .custom("Kilo Code"))
        XCTAssertEqual(AgentTool.resolve(named: "kilo - ~/proj"), .custom("Kilo Code"))
    }

    func test_manifest_tool_is_ephemeral_and_listed() {
        let tool = AgentBootstrapTool.manifest("kilo")
        XCTAssertEqual(tool.integrationClass, .ephemeral)
        XCTAssertEqual(tool.agentTool, .custom("Kilo Code"))
        XCTAssertNil(tool.integrationConfigURL)
        XCTAssertTrue(AgentIntegrationConsent.allTools.contains(.manifest("kilo")))
        XCTAssertTrue(AgentIntegrationConsent.ephemeralTools.contains(.manifest("kilo")))
    }

    // MARK: - Resume

    func test_manifest_resume_command_builds_with_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-kilo",
            kind: .agentResume,
            toolName: "Kilo Code",
            sessionID: "ses_abc",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "kilo --session ses_abc"
        )
    }

    func test_manifest_resume_command_rejects_invalid_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-kilo",
            kind: .agentResume,
            toolName: "Kilo Code",
            sessionID: "bogus; rm -rf /",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertNil(AgentResumeCommandBuilder.command(for: draft))
    }

    func test_manifest_resume_command_working_directory_variant() {
        let registry = AgentManifestRegistry(manifests: [
            AgentManifest(
                schemaVersion: 1,
                id: "demo",
                displayName: "Demo Agent",
                binaries: ["demo"],
                family: .canonical,
                resume: AgentManifest.Resume(
                    command: "demo --continue --dir {workingDirectory}",
                    sessionIdPattern: nil
                )
            ),
        ])
        AgentManifestRegistry.provider = { registry }

        let draft = PaneRestoreDraft(
            paneID: "pane-demo",
            kind: .agentResume,
            toolName: "Demo Agent",
            sessionID: "",
            workingDirectory: "/tmp/my project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "demo --continue --dir '/tmp/my project'"
        )
    }

    func test_manifest_resume_requires_session_id_when_template_uses_it() throws {
        let registry = Self.kiloRegistry
        AgentManifestRegistry.provider = { registry }

        let draft = PaneRestoreDraft(
            paneID: "pane-kilo",
            kind: .agentResume,
            toolName: "Kilo Code",
            sessionID: "",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertNil(AgentResumeCommandBuilder.command(for: draft))
    }

    // MARK: - Wrapper materialization

    func test_materializer_writes_executable_wrappers_and_prunes_stale_ids() throws {
        addTeardownBlock {
            AgentManifestWrapperMaterializer.resetMaterializedDirectories()
        }
        let rootURL = try makeTemporaryDirectory(named: "agent-manifest-wrappers")
        let staleDirectory = rootURL.appendingPathComponent("stale-agent", isDirectory: true)
        try FileManager.default.createDirectory(at: staleDirectory, withIntermediateDirectories: true)
        let unrelatedFile = rootURL.appendingPathComponent("keep.txt", isDirectory: false)
        try "keep".write(to: unrelatedFile, atomically: true, encoding: .utf8)

        let supportDirectory = try makeTemporaryDirectory(named: "agent-manifest-support")
        let sharedWrapperPath = supportDirectory
            .appendingPathComponent("zentty-agent-wrapper", isDirectory: false)
            .path

        let manifest = AgentManifest(
            schemaVersion: 1,
            id: "kilo",
            displayName: "Kilo Code",
            binaries: ["kilo", "kilo-cli"],
            family: .canonical
        )

        let directories = try AgentManifestWrapperMaterializer.materialize(
            manifests: [manifest],
            rootURL: rootURL,
            sharedWrapperPath: sharedWrapperPath
        )

        XCTAssertEqual(directories, [rootURL.appendingPathComponent("kilo", isDirectory: true).path])
        XCTAssertEqual(
            AgentManifestWrapperMaterializer.materializedDirectories,
            directories
        )

        for binary in ["kilo", "kilo-cli"] {
            let wrapperURL = rootURL
                .appendingPathComponent("kilo", isDirectory: true)
                .appendingPathComponent(binary, isDirectory: false)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: wrapperURL.path))
            let contents = try String(contentsOf: wrapperURL, encoding: .utf8)
            XCTAssertTrue(contents.contains("export ZENTTY_AGENT_TOOL=\"kilo\""))
            XCTAssertTrue(contents.contains("export ZENTTY_AGENT_REAL_BINARIES=\"kilo:kilo-cli\""))
            XCTAssertTrue(contents.contains("zentty-agent-wrapper"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFile.path))
    }

    // MARK: - Helpers

    private func makeTarget() -> AgentIPCTarget {
        AgentIPCTarget(
            windowID: WindowID("window-main"),
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("pane-main")
        )
    }

    /// A throwaway bundle whose Resources dir contains the opencode plugin that
    /// the opencode-plugin family plan copies into the overlay.
    private func makePluginBundle(named name: String) throws -> Bundle {
        let rootURL = try makeTemporaryDirectory(named: name)
            .appendingPathComponent("\(name).app", isDirectory: true)
        let contentsURL = rootURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>be.zenjoy.zentty.tests.\(name)</string>
            <key>CFBundleExecutable</key>
            <string>\(name)</string>
            <key>CFBundleName</key>
            <string>\(name)</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
        </dict>
        </plist>
        """
        try infoPlist.write(to: infoPlistURL, atomically: true, encoding: .utf8)

        let pluginDirectory = resourcesURL
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try "export const ZenttyOpenCodePlugin = async () => ({})\n".write(
            to: pluginDirectory.appendingPathComponent("zentty-opencode-zentty.js", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        return try XCTUnwrap(Bundle(url: rootURL))
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
}
