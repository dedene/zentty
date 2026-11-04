import AppKit
import XCTest
@testable import Zentty

/// The pill bar showing or leaving resizes the strip; that one resize
/// animates like a reflow, any other viewport resize still snaps.
@MainActor
final class PaneStripViewportResizeAnimationTests: AppKitTestCase {
    private let state = PaneStripState(
        panes: [
            PaneState(id: PaneID("left"), title: "left", width: 400),
            PaneState(id: PaneID("right"), title: "right", width: 400),
        ],
        focusedPaneID: PaneID("left")
    )

    private func makeVisibleStrip() -> PaneStripView {
        let strip = PaneStripView(
            frame: CGRect(x: 0, y: 0, width: 900, height: 600),
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() })
        )
        strip.accessibilityReduceMotionForTesting = false
        let window = NSWindow(
            contentRect: strip.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        let container = NSView(frame: strip.frame)
        container.addSubview(strip)
        window.contentView = container
        window.makeKeyAndOrderFrontForAppKitTesting(nil)
        addTeardownBlock {
            MainActor.assumeIsolated {
                strip.prepareForTestingTearDown()
                window.orderOut(nil)
                window.close()
            }
        }
        strip.render(state, animated: false)
        strip.layoutSubtreeIfNeeded()
        return strip
    }

    func test_flagged_viewport_resize_animates_once() {
        let strip = makeVisibleStrip()

        strip.frame = CGRect(x: 0, y: PillBarLayout.barHeight, width: 900, height: 600 - PillBarLayout.barHeight)
        strip.animatesNextViewportResize = true
        XCTAssertEqual(strip.window?.isVisible, true)
        strip.render(state, animated: true)

        XCTAssertTrue(strip.lastRenderWasAnimated)
        XCTAssertFalse(strip.animatesNextViewportResize, "the flag is one-shot")
    }

    func test_unflagged_viewport_resize_still_snaps() {
        let strip = makeVisibleStrip()

        strip.frame = CGRect(x: 0, y: PillBarLayout.barHeight, width: 900, height: 600 - PillBarLayout.barHeight)
        strip.render(state, animated: true)

        XCTAssertFalse(strip.lastRenderWasAnimated)
    }
}
