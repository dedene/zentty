import XCTest

@testable import Zentty

/// Policy tests for `CompanionInputRouter`: which wire messages become pasted
/// text vs. real key events, how quick actions resolve, and what the audit trail
/// records. The byte encoding itself lives in libghostty (driven via
/// `TerminalSpecialKey` key events), so these assert the routing decision — the
/// exact seam where the arrow-key and Return regressions were introduced.
@MainActor
final class CompanionInputRouterTests: XCTestCase {
    private static let phoneId = "device-abc"

    private final class RecordingSink: CompanionInputSink {
        var texts: [(text: String, paneId: String)] = []
        var keys: [(key: TerminalSpecialKey, paneId: String)] = []
        var textResult = true
        var keyResult = true

        func companionSendText(_ text: String, toPaneId paneId: String) -> Bool {
            texts.append((text, paneId))
            return textResult
        }

        func companionSendKey(_ key: TerminalSpecialKey, toPaneId paneId: String) -> Bool {
            keys.append((key, paneId))
            return keyResult
        }
    }

    private final class RecordingAudit: CompanionInputAuditing {
        var records: [CompanionInputAuditRecord] = []
        func record(_ record: CompanionInputAuditRecord) { records.append(record) }
    }

    private var sink: RecordingSink!
    private var audit: RecordingAudit!
    private var router: CompanionInputRouter!

    override func setUp() {
        super.setUp()
        sink = RecordingSink()
        audit = RecordingAudit()
        router = CompanionInputRouter(sink: sink, audit: audit)
    }

    override func tearDown() {
        sink = nil
        audit = nil
        router = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func sendText(_ text: String, pane: String = "p1") -> CompanionInputAck? {
        router.handle(.inputText(CompanionInputText(paneId: pane, text: text)), fromDeviceId: Self.phoneId)
    }

    private func sendKey(_ key: CompanionInputKey, pane: String = "p1") -> CompanionInputAck? {
        router.handle(.inputKey(CompanionInputKeyMessage(paneId: pane, key: key)), fromDeviceId: Self.phoneId)
    }

    private func sendQuickAction(_ actionId: String, pane: String = "p1") -> CompanionInputAck? {
        router.handle(
            .inputQuickAction(CompanionInputQuickAction(paneId: pane, actionId: actionId)),
            fromDeviceId: Self.phoneId
        )
    }

    // MARK: - input.text

    func testInputTextPastesVerbatim() {
        let ack = sendText("hello")
        XCTAssertEqual(ack?.ok, true)
        XCTAssertEqual(sink.texts.map(\.text), ["hello"])
        XCTAssertEqual(sink.keys.count, 0, "printable text must not take the key path")
    }

    // MARK: - input.key routes every named key through the key-event path

    func testNamedKeysRouteToKeyEventNeverText() {
        let cases: [(CompanionInputKey, TerminalSpecialKey)] = [
            (.enter, .enter),
            (.escape, .escape),
            (.tab, .tab),
            (.up, .up),
            (.down, .down),
            (.left, .left),
            (.right, .right),
            (.ctrlC, .ctrlC),
            (.ctrlD, .ctrlD),
            (.ctrlZ, .ctrlZ),
            (.ctrlR, .ctrlR),
        ]

        for (wireKey, expected) in cases {
            sink.keys.removeAll()
            sink.texts.removeAll()
            let ack = sendKey(wireKey)
            XCTAssertEqual(ack?.ok, true)
            XCTAssertEqual(sink.keys.map(\.key), [expected], "\(wireKey) should map to \(expected)")
            XCTAssertEqual(sink.texts.count, 0, "\(wireKey) must never be pasted as text")
        }
    }

    /// The exact regression: an arrow must be a key event, so libghostty emits a
    /// real CSI (with ESC), not a paste of "[A".
    func testArrowIsKeyEventNotEscapeSequenceText() {
        _ = sendKey(.up)
        XCTAssertEqual(sink.keys.map(\.key), [.up])
        XCTAssertFalse(sink.texts.contains { $0.text.contains("[") },
                       "arrow must not be delivered as a literal '[A' paste")
    }

    /// The other regression: Return is a key event (which submits) rather than a
    /// pasted CR/LF (which Claude Code treats as a newline insert).
    func testEnterIsKeyEventNotPastedNewline() {
        _ = sendKey(.enter)
        XCTAssertEqual(sink.keys.map(\.key), [.enter])
        XCTAssertEqual(sink.texts.count, 0)
    }

    // MARK: - Failure surfacing

    func testKeyFailureSurfacesPaneNotFound() {
        sink.keyResult = false
        let ack = sendKey(.up, pane: "gone")
        XCTAssertEqual(ack?.ok, false)
        XCTAssertEqual(ack?.error, "pane_not_found")
    }

    // MARK: - Quick actions

    func testQuickActionApproveAndDenyAndInterruptAreKeyEvents() {
        for (actionId, expected): (String, TerminalSpecialKey) in [
            ("approve", .enter), ("submit", .enter), ("enter", .enter),
            ("deny", .escape), ("cancel", .escape), ("escape", .escape),
            ("interrupt", .ctrlC),
        ] {
            sink.keys.removeAll()
            sink.texts.removeAll()
            let ack = sendQuickAction(actionId)
            XCTAssertEqual(ack?.ok, true)
            XCTAssertEqual(sink.keys.map(\.key), [expected], "quick action \(actionId)")
            XCTAssertEqual(sink.texts.count, 0)
        }
    }

    func testQuickActionOptionDigitPastesAsText() {
        let ack = sendQuickAction("option:3")
        XCTAssertEqual(ack?.ok, true)
        XCTAssertEqual(sink.texts.map(\.text), ["3"])
        XCTAssertEqual(sink.keys.count, 0)
    }

    func testUnknownQuickActionIsRejected() {
        let ack = sendQuickAction("option:")
        XCTAssertEqual(ack?.ok, false)
        XCTAssertEqual(ack?.error, "unknown_action")

        let bogus = sendQuickAction("frobnicate")
        XCTAssertEqual(bogus?.ok, false)
        XCTAssertEqual(bogus?.error, "unknown_action")
    }

    // MARK: - Audit trail

    func testTextInjectionIsRecordedWithPaneDeviceAndKind() {
        _ = sendText("hello", pane: "pane-7")
        XCTAssertEqual(
            audit.records,
            [CompanionInputAuditRecord(
                paneId: "pane-7",
                deviceId: Self.phoneId,
                kind: .text,
                length: 5,
                outcome: .ok
            )]
        )
    }

    func testKeyAndQuickActionInjectionsAreRecordedWithTheirFamily() {
        _ = sendKey(.ctrlC, pane: "pane-7")
        _ = sendQuickAction("approve", pane: "pane-7")
        XCTAssertEqual(audit.records.map(\.kind), [.key, .quickAction])
        XCTAssertEqual(audit.records.map(\.outcome), [.ok, .ok])
        XCTAssertEqual(audit.records.map(\.length), [0, 0])
    }

    func testFailedInjectionIsRecordedWithItsOutcome() {
        sink.keyResult = false
        sink.textResult = false
        _ = sendKey(.up, pane: "gone")
        _ = sendText("hello", pane: "gone")
        _ = sendQuickAction("frobnicate", pane: "gone")

        XCTAssertEqual(audit.records.map(\.outcome), [.paneNotFound, .paneNotFound, .unknownAction])
        XCTAssertTrue(audit.records.allSatisfy { $0.paneId == "gone" })
        XCTAssertTrue(audit.records.allSatisfy { $0.deviceId == Self.phoneId })
    }

    /// A dropped sink (pane host torn down) still leaves a trace.
    func testUnavailableSinkIsRecorded() {
        var detachedSink: RecordingSink? = RecordingSink()
        let detachedRouter = CompanionInputRouter(sink: detachedSink!, audit: audit)
        detachedSink = nil

        let ack = detachedRouter.handle(
            .inputText(CompanionInputText(paneId: "p1", text: "hello")),
            fromDeviceId: Self.phoneId
        )
        XCTAssertEqual(ack?.error, "unavailable")
        XCTAssertEqual(audit.records.map(\.outcome), [.unavailable])
    }

    /// The point of the audit trail: it must never leak what was typed. Phones
    /// type passwords and tokens into panes.
    func testAuditRecordNeverCarriesInputContent() {
        let secret = "hunter2-super-secret-token"
        _ = sendText(secret)
        _ = sendQuickAction("option:7")

        XCTAssertEqual(audit.records.count, 2)
        for record in audit.records {
            let dumped = String(describing: record)
            XCTAssertFalse(dumped.contains(secret), "audit record must not carry the injected text")
            XCTAssertFalse(dumped.contains("hunter"), "audit record must not carry the injected text")
            XCTAssertFalse(dumped.contains("option:7"), "audit record must not carry the quick-action payload")
        }
        // Only the family and a character count survive.
        XCTAssertEqual(audit.records.map(\.kind), [.text, .quickAction])
        XCTAssertEqual(audit.records.map(\.length), [secret.count, 1])
    }
}
