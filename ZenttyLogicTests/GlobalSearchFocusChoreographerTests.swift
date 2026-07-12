import XCTest
@testable import Zentty

@MainActor
final class GlobalSearchFocusChoreographerTests: XCTestCase {

    func test_stale_navigation_token_does_not_refocus() {
        let spy = Spy()
        spy.hudVisible = true
        let choreographer = GlobalSearchFocusChoreographer(hooks: spy.hooks)

        // Two navigations in the same runloop turn: the first token is superseded
        // by the second, so only the second's refocus should fire.
        choreographer.performNavigationPreservingHUD {}
        choreographer.performNavigationPreservingHUD {}

        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)

        XCTAssertEqual(spy.focusFieldCount, 1)
    }

    func test_should_retain_focus_while_preservation_token_is_active() {
        let spy = Spy()
        spy.hudVisible = true
        let choreographer = GlobalSearchFocusChoreographer(hooks: spy.hooks)

        XCTAssertFalse(choreographer.shouldRetainFocus)
        choreographer.performNavigationPreservingHUD {}
        XCTAssertTrue(choreographer.shouldRetainFocus)
    }

    func test_should_retain_focus_when_hud_visible_and_field_focused() {
        let spy = Spy()
        spy.hudVisible = true
        spy.fieldFocused = true
        let choreographer = GlobalSearchFocusChoreographer(hooks: spy.hooks)

        XCTAssertTrue(choreographer.shouldRetainFocus)
    }

    func test_preservation_token_releases_after_delay() {
        let spy = Spy()
        spy.hudVisible = true
        spy.fieldFocused = false
        let choreographer = GlobalSearchFocusChoreographer(hooks: spy.hooks)

        choreographer.performNavigationPreservingHUD {}
        XCTAssertTrue(choreographer.shouldRetainFocus)

        let released = expectation(description: "release work item fired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { released.fulfill() }
        wait(for: [released], timeout: 1)

        // Token cleared; retention now depends solely on hud && field (false here).
        XCTAssertFalse(choreographer.shouldRetainFocus)
    }

    func test_close_and_focus_terminal_clears_token_and_invokes_hooks() {
        let spy = Spy()
        let choreographer = GlobalSearchFocusChoreographer(hooks: spy.hooks)

        choreographer.performNavigationPreservingHUD {}
        choreographer.closeAndFocusTerminal()

        XCTAssertFalse(choreographer.shouldRetainFocus)
        XCTAssertEqual(spy.endCount, 1)
        XCTAssertEqual(spy.exitCount, 1)
        XCTAssertEqual(spy.terminalCount, 1)
    }
}

@MainActor
private final class Spy {
    var hudVisible = false
    var fieldFocused = false
    var focusFieldCount = 0
    var lastFocusFieldSelectAll: Bool?
    var enterCount = 0
    var exitCount = 0
    var endCount = 0
    var terminalCount = 0

    var hooks: GlobalSearchFocusChoreographer.Hooks {
        GlobalSearchFocusChoreographer.Hooks(
            isHUDVisible: { [self] in hudVisible },
            isFieldFocused: { [self] in fieldFocused },
            focusField: { [self] selectAll in
                focusFieldCount += 1
                lastFocusFieldSelectAll = selectAll
            },
            enterFocusMotion: { [self] in enterCount += 1 },
            exitFocusMotion: { [self] in exitCount += 1 },
            endSearchSession: { [self] in endCount += 1 },
            focusTerminal: { [self] in terminalCount += 1 }
        )
    }
}
