import AppKit
import QuartzCore
import XCTest
@testable import Zentty

@MainActor
final class TerminalScrollFrameSamplerTests: AppKitTestCase {
    func test_sampler_uses_view_bound_appkit_display_link_with_preferred_frame_rate_range() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let displayLink = TerminalDisplayLinkSpy()
        let maker = TerminalDisplayLinkMakerSpy(displayLink: displayLink)
        let sampler = TerminalScrollFrameSampler(displayLinkMaker: maker)

        sampler.start(attachedTo: view, preferredFramesPerSecond: 144)

        XCTAssertTrue(maker.requestedView === view)
        XCTAssertEqual(sampler.pacingMode, .appKitDisplayLink)
        XCTAssertEqual(displayLink.addCalls, [.common])
        XCTAssertEqual(displayLink.preferredFrameRateRange.minimum, 60)
        XCTAssertEqual(displayLink.preferredFrameRateRange.maximum, 144)
        XCTAssertEqual(displayLink.preferredFrameRateRange.preferred, 144)
    }

    func test_sampler_clamps_display_link_target_to_high_refresh_bounds() {
        let displayLink = TerminalDisplayLinkSpy()
        let sampler = TerminalScrollFrameSampler(
            displayLinkMaker: TerminalDisplayLinkMakerSpy(displayLink: displayLink)
        )

        sampler.start(attachedTo: NSView(), preferredFramesPerSecond: 500)

        XCTAssertEqual(displayLink.preferredFrameRateRange.minimum, 60)
        XCTAssertEqual(displayLink.preferredFrameRateRange.maximum, 240)
        XCTAssertEqual(displayLink.preferredFrameRateRange.preferred, 240)
    }

    func test_sampler_invalidates_display_link_on_stop() {
        let displayLink = TerminalDisplayLinkSpy()
        let sampler = TerminalScrollFrameSampler(
            displayLinkMaker: TerminalDisplayLinkMakerSpy(displayLink: displayLink)
        )

        sampler.start(attachedTo: NSView(), preferredFramesPerSecond: 120)
        sampler.stop()

        XCTAssertTrue(displayLink.didInvalidate)
        XCTAssertEqual(sampler.pacingMode, .stopped)
    }

    func test_sampler_uses_fallback_timer_mode_when_display_link_cannot_be_created() {
        let sampler = TerminalScrollFrameSampler(
            displayLinkMaker: TerminalDisplayLinkMakerSpy(displayLink: nil)
        )

        sampler.start(attachedTo: NSView(), preferredFramesPerSecond: 120)
        addTeardownBlock {
            sampler.stop()
        }

        XCTAssertEqual(sampler.pacingMode, .fallbackTimer)
    }
}

@MainActor
private final class TerminalDisplayLinkMakerSpy: TerminalDisplayLinkMaking {
    private let displayLink: TerminalDisplayLinkSpy?
    private(set) weak var requestedView: NSView?

    init(displayLink: TerminalDisplayLinkSpy?) {
        self.displayLink = displayLink
    }

    func makeDisplayLink(
        attachedTo view: NSView,
        target: Any,
        selector: Selector
    ) -> (any TerminalDisplayLinking)? {
        requestedView = view
        return displayLink
    }
}

@MainActor
private final class TerminalDisplayLinkSpy: TerminalDisplayLinking {
    var preferredFrameRateRange = CAFrameRateRange(minimum: 0, maximum: 0, preferred: 0)
    private(set) var addCalls: [RunLoop.Mode] = []
    private(set) var didInvalidate = false

    func add(to runLoop: RunLoop, forMode mode: RunLoop.Mode) {
        addCalls.append(mode)
    }

    func invalidate() {
        didInvalidate = true
    }
}
