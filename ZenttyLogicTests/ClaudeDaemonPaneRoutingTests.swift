import Foundation
import XCTest
@testable import Zentty

/// Reproduces dedene/zentty#121: "Claude Code background sessions report
/// status to the wrong pane, or not at all".
///
/// Claude Code runs background/agent-mode sessions under a single shared
/// per-user daemon (`claude daemon run`), started lazily by whichever pane
/// first needs it. The daemon inherits that pane's environment — including
/// `ZENTTY_PANE_ID` / `ZENTTY_WORKLANE_ID` — and every subsequent Claude
/// session launched through the same daemon has its hook events run in a
/// process carrying that SAME inherited pane identity, regardless of which
/// pane actually started the session.
///
/// `AgentLaunchBootstrap.claudePlan` seeds the session→pane mapping in
/// `ClaudeHookSessionStore` at launch time, using the pane Zentty itself
/// resolved the launch against — not the environment the eventual hook
/// process happens to run under. `SessionStart` then resolves its target via
/// `claudeResolvedTarget`, which checks that seed before falling back to the
/// hook process's own environment. This test drives both halves through the
/// real code path with a hook environment that deliberately mismatches the
/// launch pane, the way a daemon-inherited environment would.
final class ClaudeDaemonPaneRoutingTests: XCTestCase {

    private var sessionStore: ClaudeHookSessionStore!
    private var subagentStore: AgentSubagentRegistryStore!
    private var runtimeDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zentty-claude-daemon-pane-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessionStore = ClaudeHookSessionStore(
            stateURL: directory.appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
        )
        subagentStore = AgentSubagentRegistryStore(
            stateURL: directory.appendingPathComponent("agent-subagent-sessions.json", isDirectory: false),
            transcriptModificationDate: { _ in nil }
        )
        runtimeDirectoryURL = directory.appendingPathComponent("runtime", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func test_fresh_session_launched_in_pane_b_is_not_misattributed_to_daemon_starter_pane_a() throws {
        let worklaneID = WorklaneID("worklane-1")
        let paneB = PaneID("pane-b")
        let target = AgentIPCTarget(windowID: nil, worklaneID: worklaneID, paneID: paneB)

        // Launch a fresh Claude session in pane B. `AgentLaunchBootstrap`
        // resolves `target` from Zentty's own topology, independent of
        // whatever environment the eventual hook subprocess inherits.
        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: [],
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": "/usr/bin/true",
                "ZENTTY_CLI_BIN": "/usr/local/bin/zentty",
                "ZENTTY_PANE_ID": paneB.rawValue,
                "ZENTTY_WORKLANE_ID": worklaneID.rawValue,
            ],
            expectsResponse: true,
            tool: .claude
        )
        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: target,
            runtimeDirectoryURL: runtimeDirectoryURL
        )

        guard let sessionIDIndex = plan.arguments.firstIndex(of: "--session-id"),
              sessionIDIndex + 1 < plan.arguments.count else {
            return XCTFail("claudePlan did not insert --session-id for a fresh launch: \(plan.arguments)")
        }
        let sessionID = plan.arguments[sessionIDIndex + 1]

        // The seed must already exist before any hook fires.
        let seeded = try sessionStore.lookup(sessionID: sessionID)
        XCTAssertEqual(seeded?.paneID, paneB, "launch-time seed must record the pane the session actually launched in")
        XCTAssertEqual(seeded?.worklaneID, worklaneID)

        // Now simulate the SessionStart hook firing inside the shared Claude
        // daemon, whose process environment was captured from pane A — a
        // DIFFERENT pane than the one this session actually launched in.
        let daemonInheritedEnvironment = [
            "ZENTTY_PANE_ID": "pane-a",
            "ZENTTY_WORKLANE_ID": worklaneID.rawValue,
        ]
        let payloads = try AgentEventBridge.claudeMakePayloads(
            from: AgentEventBridge.claudeParseInput(Data(
                #"{"hook_event_name":"SessionStart","session_id":"\#(sessionID)","source":"startup"}"#.utf8
            )),
            environment: daemonInheritedEnvironment,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )

        // The record must still point at pane B — the daemon's own
        // environment must never overwrite the launch-time seed.
        let afterSessionStart = try sessionStore.lookup(sessionID: sessionID)
        XCTAssertEqual(afterSessionStart?.paneID, paneB, "SessionStart must not let the daemon-inherited environment overwrite the seeded pane")

        // Any status payload SessionStart happens to emit (e.g. the pid
        // attach event) must also target pane B, not the daemon-starter's
        // pane A.
        for payload in payloads {
            XCTAssertEqual(payload.paneID, paneB, "SessionStart payload must be attributed to the launch pane, not the daemon-inherited one")
        }

        // A later hook event (e.g. Notification) for the same session must
        // resolve to pane B too, purely from the session_id in its payload —
        // this already worked pre-fix via `claudeResolvedTarget`; asserting
        // it here guards against a regression in the seed itself.
        let notificationPayloads = try AgentEventBridge.claudeMakePayloads(
            from: AgentEventBridge.claudeParseInput(Data(
                #"{"hook_event_name":"Notification","session_id":"\#(sessionID)","message":"Claude needs your permission to run ls"}"#.utf8
            )),
            environment: daemonInheritedEnvironment,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertFalse(notificationPayloads.isEmpty)
        for payload in notificationPayloads {
            XCTAssertEqual(payload.paneID, paneB)
        }
    }
}
