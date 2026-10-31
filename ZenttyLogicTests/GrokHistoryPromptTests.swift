import Foundation
import XCTest
@testable import Zentty

/// How Grok user records become typed prompts: the `<user_query>` wrapper interactive Grok
/// stores, image prompts, interrupt preambles and the compaction sandwich.
final class GrokHistoryPromptTests: XCTestCase {
    private let sessionID = "01a07283-b64e-77b3-b235-8cc132de66ed"

    private var root: URL!
    private var cwd: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        root = base.appendingPathComponent("grok-home", isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        cwd = project.path
    }

    private func ms(_ iso: String) -> Int64 {
        AgentHistoryTimestamp.milliseconds(iso8601: iso)!
    }

    private func turn(_ number: Int, _ ts: String) throws -> String {
        try AgentHistoryFixtures.grokEvent("turn_started", ts: ts, turnNumber: number)
    }

    // MARK: - typedText

    func test_typed_text_unwraps_user_query() {
        let typed = GrokChatReader.typedText
        XCTAssertEqual(typed("<user_query>\nlooks good, lets build this!\n</user_query>"), "looks good, lets build this!")
        XCTAssertEqual(
            typed("<image_files>\n1. /tmp/a.png\n</image_files>\n\n<user_query>\nwhat is this?\n</user_query>\n\n<system-reminder>\nnote\n</system-reminder>"),
            "what is this?"
        )
        XCTAssertEqual(
            typed("The user interrupted the previous turn:\n<user_query>\nstop\n</user_query>\nMake sure to complete any unfinished tasks from previous turns."),
            "stop"
        )
        // The body runs to the last closing tag, so a literal tag the user typed survives.
        XCTAssertEqual(typed("<user_query>\nwhy does </user_query> break?\n</user_query>"), "why does </user_query> break?")
        XCTAssertEqual(typed("<user_query>\nstill typing"), "still typing")
        XCTAssertNil(typed("<user_query>\n  \n</user_query>"))
        // Without a wrapper: headless prompts are typed, pure envelopes are not.
        XCTAssertEqual(typed("Break the query below.\n<query-json>{}</query-json>"), "Break the query below.\n<query-json>{}</query-json>")
        XCTAssertEqual(typed("plain prompt"), "plain prompt")
        XCTAssertNil(typed("<user_info>\nOS Version: macos\n</user_info>\n\n<rules>\nx\n</rules>"))
    }

    // MARK: - Interactive records

    func test_interactive_prompts_indexed_from_user_query() throws {
        let t0 = "2026-09-05T17:01:00.000Z"
        let t1 = "2026-09-05T17:02:00.000Z"
        let t2 = "2026-09-05T17:03:00.000Z"
        let imagePrompt = try AgentHistoryFixtures.grokChat("user", parts: [
            ["type": "text", "text": """
            <image_files>
            The following images were provided by the user and saved to the workspace for future use:
            1. /tmp/assets/image-1.png

            These images can be copied for use in other locations.
            </image_files>

            <user_query>
            what is in this picture?
            </user_query>



            <system-reminder>
            <image_compression_notice>
            Image 1 was re-encoded.
            </image_compression_notice>
            </system-reminder>
            """],
            ["type": "image", "url": "data:image/png;base64,AAAA"],
        ], promptIndex: 1)
        let interrupt = try AgentHistoryFixtures.grokChat(
            "user",
            text: "The user interrupted the previous turn:\n<user_query>\nstop, use tabs\n</user_query>\n"
                + "Make sure to complete any unfinished tasks from previous turns.",
            promptIndex: 2,
            plain: true,
            extra: ["prior_turn_interrupt": "mid_turn_abort"]
        )
        try AgentHistoryFixtures.writeGrokSession(
            root: root, id: sessionID, cwd: cwd,
            chat: [
                try AgentHistoryFixtures.grokChat("system", text: "You are Grok."),
                try AgentHistoryFixtures.grokChat(
                    "user", text: "<user_info>\nOS Version: macos\n</user_info>\n\n<rules>\n<user_rule>be brief</user_rule>\n</rules>",
                    plain: true
                ),
                try AgentHistoryFixtures.grokChat("user", text: "<system-reminder>todo</system-reminder>", syntheticReason: "system_reminder"),
                try AgentHistoryFixtures.grokChat("user", text: "looks good, lets build this!", promptIndex: 0),
                try AgentHistoryFixtures.grokChat("assistant", text: "Building."),
                imagePrompt,
                try AgentHistoryFixtures.grokChat("assistant", text: "A cube."),
                interrupt,
                try AgentHistoryFixtures.grokChat("assistant", text: "Switched to tabs."),
            ],
            events: [try turn(0, t0), try turn(1, t1), try turn(2, t2)]
        )

        let source = AgentHistoryFixtures.grokSource(root: root)
        let batch = try AgentHistoryFixtures.grokIngest(source, id: sessionID)

        XCTAssertEqual(batch.messages.map(\.text), [
            "looks good, lets build this!", "Building.",
            "what is in this picture?", "A cube.",
            "stop, use tabs", "Switched to tabs.",
        ])
        XCTAssertEqual(batch.messages.map(\.role), [.user, .agent, .user, .agent, .user, .agent])
        XCTAssertEqual(batch.messages.map(\.atMs), [ms(t0), ms(t0) + 1, ms(t1), ms(t1) + 1, ms(t2), ms(t2) + 1])
        let session = try XCTUnwrap(batch.sessions.first)
        XCTAssertEqual(session.title, "looks good, lets build this!")
        XCTAssertEqual(session.titleKind, .firstPrompt)
        XCTAssertEqual(session.lastUserAtMs, ms(t2))
    }

    /// Real compacted history: the retained `<user_query>` (no `prompt_index`) sits between two
    /// `compaction_meta` records, then a reminder, then the next numbered prompt.
    func test_compaction_sandwich_keeps_retained_prompt() throws {
        let t0 = "2026-08-27T18:54:44.555Z"
        let t3 = "2026-08-28T07:03:11.055Z"
        try AgentHistoryFixtures.writeGrokSession(
            root: root, id: sessionID, cwd: cwd,
            chat: [
                try AgentHistoryFixtures.grokChat("system", text: "You are Grok."),
                try AgentHistoryFixtures.grokChat(
                    "user", text: "<user_info>\nOS Version: macos\n</user_info>\n\n<git_status>\nclean\n</git_status>",
                    syntheticReason: "compaction_meta"
                ),
                try AgentHistoryFixtures.grokChat("user", text: "fix the crash when canceling a transition"),
                try AgentHistoryFixtures.grokChat(
                    "user",
                    text: "This session is being continued from a previous conversation that ran out of context.\n\nSummary:\n1. Fix the crash.",
                    syntheticReason: "compaction_meta"
                ),
                try AgentHistoryFixtures.grokChat("user", text: "<system-reminder>todo</system-reminder>", syntheticReason: "system_reminder"),
                try AgentHistoryFixtures.grokChat("user", text: "now open the PR", promptIndex: 3),
                try AgentHistoryFixtures.grokChat("assistant", text: "PR opened."),
            ],
            events: [
                try turn(0, t0),
                try turn(1, "2026-08-27T19:34:38.795Z"),
                try turn(2, "2026-08-27T19:34:53.776Z"),
                try turn(3, t3),
            ]
        )

        let source = AgentHistoryFixtures.grokSource(root: root)
        let batch = try AgentHistoryFixtures.grokIngest(source, id: sessionID)

        XCTAssertEqual(batch.messages.map(\.text), ["fix the crash when canceling a transition", "now open the PR", "PR opened."])
        XCTAssertEqual(batch.messages.map(\.role), [.user, .user, .agent])
        XCTAssertEqual(batch.messages.map(\.atMs), [ms(t0), ms(t3), ms(t3) + 1])
        let session = try XCTUnwrap(batch.sessions.first)
        XCTAssertEqual(session.title, "fix the crash when canceling a transition")
        XCTAssertEqual(session.titleKind, .firstPrompt)
    }

    func test_blank_user_query_is_not_a_message() throws {
        try AgentHistoryFixtures.writeGrokSession(root: root, id: sessionID, cwd: cwd, chat: [
            try AgentHistoryFixtures.grokChat("user", text: "  ", promptIndex: 0),
            try AgentHistoryFixtures.grokChat("assistant", text: "Anything else?"),
        ])

        let source = AgentHistoryFixtures.grokSource(root: root)
        let batch = try AgentHistoryFixtures.grokIngest(source, id: sessionID)

        XCTAssertEqual(batch.messages.map(\.text), ["Anything else?"])
        XCTAssertNil(batch.sessions.first?.title)
    }
}
