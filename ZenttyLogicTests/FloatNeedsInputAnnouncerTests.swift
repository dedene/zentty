import XCTest
@testable import Zentty

/// VoiceOver hears "<name> needs input" once when a pill or PiP of the active
/// worklane starts needing input (UX spec §15).
@MainActor
final class FloatNeedsInputAnnouncerTests: XCTestCase {

    func test_first_look_at_a_worklane_seeds_without_speaking() {
        var announcer = FloatNeedsInputAnnouncer()

        let messages = announcer.update(worklane: worklane(["agent": (.minimized(order: 0), true)]))

        XCTAssertEqual(messages, [], "a restored needs-input pill is not read out on launch")
    }

    func test_pill_that_starts_needing_input_is_announced_once() {
        var announcer = FloatNeedsInputAnnouncer()
        _ = announcer.update(worklane: worklane(["agent": (.minimized(order: 0), false)]))

        let first = announcer.update(worklane: worklane(["agent": (.minimized(order: 0), true)]))
        let again = announcer.update(worklane: worklane(["agent": (.minimized(order: 0), true)]))

        XCTAssertEqual(first, ["agent needs input"])
        XCTAssertEqual(again, [], "no repeat while it keeps waiting")
    }

    func test_auto_pop_into_a_pip_is_not_announced_twice() {
        var announcer = FloatNeedsInputAnnouncer()
        _ = announcer.update(worklane: worklane(["agent": (.minimized(order: 0), false)]))
        _ = announcer.update(worklane: worklane(["agent": (.minimized(order: 0), true)]))

        let popped = announcer.update(worklane: worklane(["agent": (.pip(corner: .bottomRight, order: 0), true)]))

        XCTAssertEqual(popped, [])
    }

    func test_pip_that_starts_needing_input_is_announced() {
        var announcer = FloatNeedsInputAnnouncer()
        _ = announcer.update(worklane: worklane(["watch": (.pip(corner: .topLeft, order: 0), false)]))

        let messages = announcer.update(worklane: worklane(["watch": (.pip(corner: .topLeft, order: 0), true)]))

        XCTAssertEqual(messages, ["watch needs input"])
    }

    func test_visible_float_stays_quiet_and_minimizing_it_does_not_speak() {
        var announcer = FloatNeedsInputAnnouncer()
        _ = announcer.update(worklane: worklane(["edit": (.floating, false)]))

        let floating = announcer.update(worklane: worklane(["edit": (.floating, true)]))
        let minimized = announcer.update(worklane: worklane(["edit": (.minimized(order: 0), true)]))

        XCTAssertEqual(floating, [], "the float is on screen; its own ring shows it")
        XCTAssertEqual(minimized, [], "it already needed input before it was put away")
    }

    func test_resume_then_needs_input_again_is_announced_again() {
        var announcer = FloatNeedsInputAnnouncer()
        _ = announcer.update(worklane: worklane(["agent": (.minimized(order: 0), false)]))
        _ = announcer.update(worklane: worklane(["agent": (.minimized(order: 0), true)]))
        _ = announcer.update(worklane: worklane(["agent": (.minimized(order: 0), false)]))

        let messages = announcer.update(worklane: worklane(["agent": (.minimized(order: 0), true)]))

        XCTAssertEqual(messages, ["agent needs input"])
    }

    func test_switching_worklanes_reseeds_silently() {
        var announcer = FloatNeedsInputAnnouncer()
        _ = announcer.update(worklane: worklane(["agent": (.minimized(order: 0), false)], id: "a"))

        let messages = announcer.update(worklane: worklane(["other": (.minimized(order: 0), true)], id: "b"))

        XCTAssertEqual(messages, [])
    }

    // MARK: - Fixtures

    private func worklane(
        _ floats: [String: (mode: FloatingPaneMode, needsInput: Bool)],
        id: String = "wl"
    ) -> WorklaneState {
        var auxiliary: [PaneID: PaneAuxiliaryState] = [:]
        let floatingPanes = floats.keys.sorted().enumerated().map { index, name in
            let entry = floats[name]!
            if entry.needsInput {
                var presentation = PanePresentationState()
                presentation.runtimePhase = .needsInput
                auxiliary[PaneID(name)] = PaneAuxiliaryState(raw: PaneRawState(), presentation: presentation)
            }
            return FloatingPaneState(
                pane: PaneState(id: PaneID(name), title: name),
                mode: entry.mode,
                floatFrame: NormalizedRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
                stackOrder: index,
                origin: nil
            )
        }
        return WorklaneState(
            id: WorklaneID(id),
            title: nil,
            paneStripState: PaneStripState(
                panes: [PaneState(id: PaneID("tile-\(id)"), title: "tile")],
                focusedPaneID: PaneID("tile-\(id)")
            ),
            auxiliaryStateByPaneID: auxiliary,
            floatingPanes: floatingPanes
        )
    }
}
