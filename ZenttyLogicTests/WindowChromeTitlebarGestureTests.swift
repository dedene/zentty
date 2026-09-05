import AppKit
import XCTest
@testable import Zentty

@MainActor
final class WindowChromeTitlebarGestureTests: AppKitTestCase {
    // MARK: - Resolver

    func test_single_click_stays_a_window_drag() {
        XCTAssertEqual(
            WindowChromeTitlebarGesture.resolve(clickCount: 1, isFullscreen: false, doubleClickActionPreference: "Maximize"),
            .windowDrag
        )
    }

    func test_double_click_resolves_maximize_preference_to_zoom() {
        XCTAssertEqual(
            WindowChromeTitlebarGesture.resolve(clickCount: 2, isFullscreen: false, doubleClickActionPreference: "Maximize"),
            .zoom
        )
    }

    func test_double_click_defaults_to_zoom_without_or_with_unknown_preference() {
        XCTAssertEqual(
            WindowChromeTitlebarGesture.resolve(clickCount: 2, isFullscreen: false, doubleClickActionPreference: nil),
            .zoom
        )
        XCTAssertEqual(
            WindowChromeTitlebarGesture.resolve(clickCount: 2, isFullscreen: false, doubleClickActionPreference: "Unrecognized"),
            .zoom
        )
    }

    func test_double_click_resolves_fill_preference_to_fill() {
        XCTAssertEqual(
            WindowChromeTitlebarGesture.resolve(clickCount: 2, isFullscreen: false, doubleClickActionPreference: "Fill"),
            .fill
        )
    }

    func test_double_click_resolves_minimize_preference_to_miniaturize() {
        XCTAssertEqual(
            WindowChromeTitlebarGesture.resolve(clickCount: 2, isFullscreen: false, doubleClickActionPreference: "Minimize"),
            .miniaturize
        )
    }

    func test_double_click_with_none_preference_still_drags_the_window() {
        XCTAssertEqual(
            WindowChromeTitlebarGesture.resolve(clickCount: 2, isFullscreen: false, doubleClickActionPreference: "None"),
            .windowDrag
        )
    }

    func test_double_click_in_fullscreen_still_drags_the_window() {
        XCTAssertEqual(
            WindowChromeTitlebarGesture.resolve(clickCount: 2, isFullscreen: true, doubleClickActionPreference: "Maximize"),
            .windowDrag
        )
    }

    // MARK: - Wiring

    /// Records which titlebar action the chrome asked for, without moving real windows.
    private final class RecordingWindow: NSWindow {
        var preference: String?
        var dragCount = 0
        var zoomCount = 0
        var fillCount = 0
        var miniaturizeCount = 0

        override var windowChromeDoubleClickActionPreference: String? { preference }
        override func performDrag(with event: NSEvent) { dragCount += 1 }
        override func performZoom(_ sender: Any?) { zoomCount += 1 }
        override func performWindowChromeFill(_ sender: Any?) { fillCount += 1 }
        override func performMiniaturize(_ sender: Any?) { miniaturizeCount += 1 }
    }

    private func makeChrome() throws -> (RecordingWindow, WindowChromeView, [(String, NSPoint)]) {
        let window = RecordingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 120),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        addTeardownBlock { window.close() }

        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 900, height: WindowChromeView.preferredHeight)
        )
        window.contentView?.addSubview(view)
        view.render(summary: WorklaneChromeSummary(
            focusedLabel: "Claude Code",
            remoteContextLabel: "remote ~/zentty",
            branch: "main",
            pullRequest: nil,
            reviewChips: [WorklaneReviewChip(text: "1 failing", style: .danger)]
        ))
        view.layoutSubtreeIfNeeded()

        let focusedLabel = try XCTUnwrap(findLabel(in: view, withText: "Claude Code"))
        let remoteLabel = try XCTUnwrap(findLabel(in: view, withText: "remote ~/zentty"))
        let reviewChipLabel = try XCTUnwrap(findLabel(in: view, withText: "1 failing"))
        let points = [
            ("empty header space", NSPoint(x: view.bounds.minX + 2, y: view.bounds.minY + 2)),
            ("row padding", NSPoint(x: view.rowFrame.minX + 2, y: view.rowFrame.midY)),
            ("focused passive label", focusedLabel.convert(center(of: focusedLabel.bounds), to: view)),
            ("remote passive label", remoteLabel.convert(center(of: remoteLabel.bounds), to: view)),
            ("review chip", reviewChipLabel.convert(center(of: reviewChipLabel.bounds), to: view)),
        ]
        return (window, view, points)
    }

    /// - Returns: the view that received the synthesized mouseDown, so callers can assert
    ///   which drag-surface subclass actually routed the click.
    @discardableResult
    private func click(_ view: WindowChromeView, at point: NSPoint, in window: NSWindow, clickCount: Int) throws -> NSView {
        // `hitTest(_:)` expects a point in the coordinate system of the receiver's
        // *superview*, not the receiver itself — convert explicitly rather than relying on
        // the chrome view's frame origin happening to be .zero inside contentView.
        let hitTestPoint = view.convert(point, to: view.superview)
        let hitView = try XCTUnwrap(view.hitTest(hitTestPoint))
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
        hitView.mouseDown(with: event)
        return hitView
    }

    // The review chip point is not asserted by class here: `WindowChromeReviewChipView`
    // currently gets a zero width from `intrinsicWidth(for:)` and is pruned from the row
    // layout (pre-existing, tracked separately), so it doesn't reliably hit its own class.
    // These are the classes every other surface is guaranteed to hit today.
    private let guaranteedDragSurfaceClasses: Set<String> = [
        "WindowChromeView", "WindowChromeDragRegionView", "WindowChromeDragLabel",
    ]

    func test_every_drag_surface_zooms_on_double_click() throws {
        let (window, view, points) = try makeChrome()
        window.preference = "Maximize"

        var hitTypeNames = Set<String>()
        for (target, point) in points {
            let zoomCountBefore = window.zoomCount
            let hitView = try click(view, at: point, in: window, clickCount: 2)
            XCTAssertEqual(window.zoomCount, zoomCountBefore + 1, "\(target) should zoom exactly once")
            hitTypeNames.insert(String(describing: type(of: hitView)))
        }

        XCTAssertEqual(window.zoomCount, points.count)
        XCTAssertEqual(window.dragCount, 0)
        XCTAssertTrue(
            hitTypeNames.isSuperset(of: guaranteedDragSurfaceClasses),
            "expected the guaranteed drag-surface classes to all be hit, got \(hitTypeNames)"
        )
    }

    func test_every_drag_surface_drags_on_single_click() throws {
        let (window, view, points) = try makeChrome()
        window.preference = "Maximize"

        var hitTypeNames = Set<String>()
        for (target, point) in points {
            let dragCountBefore = window.dragCount
            let hitView = try click(view, at: point, in: window, clickCount: 1)
            XCTAssertEqual(window.dragCount, dragCountBefore + 1, "\(target) should drag exactly once")
            hitTypeNames.insert(String(describing: type(of: hitView)))
        }

        XCTAssertEqual(window.dragCount, points.count)
        XCTAssertEqual(window.zoomCount, 0)
        XCTAssertTrue(
            hitTypeNames.isSuperset(of: guaranteedDragSurfaceClasses),
            "expected the guaranteed drag-surface classes to all be hit, got \(hitTypeNames)"
        )
    }

    func test_double_click_fills_when_preference_is_fill() throws {
        let (window, view, points) = try makeChrome()
        window.preference = "Fill"

        try click(view, at: points[0].1, in: window, clickCount: 2)

        XCTAssertEqual(window.fillCount, 1)
        XCTAssertEqual(window.zoomCount, 0)
    }

    func test_double_click_miniaturizes_when_preference_is_minimize() throws {
        let (window, view, points) = try makeChrome()
        window.preference = "Minimize"

        try click(view, at: points[0].1, in: window, clickCount: 2)

        XCTAssertEqual(window.miniaturizeCount, 1)
        XCTAssertEqual(window.zoomCount, 0)
        XCTAssertEqual(window.dragCount, 0)
    }

    func test_double_click_drags_when_preference_is_none() throws {
        let (window, view, points) = try makeChrome()
        window.preference = "None"

        try click(view, at: points[0].1, in: window, clickCount: 2)

        XCTAssertEqual(window.dragCount, 1)
        XCTAssertEqual(window.zoomCount, 0)
    }

    func test_double_click_does_nothing_while_window_drag_is_suppressed() throws {
        let (window, view, points) = try makeChrome()
        window.preference = "Maximize"
        window.isMovable = false

        try click(view, at: points[0].1, in: window, clickCount: 2)

        XCTAssertEqual(window.zoomCount, 0)
        XCTAssertEqual(window.dragCount, 0)
    }

    func test_fill_falls_back_to_zoom_when_private_selector_is_missing() {
        // Guard behaviour only: on a stock NSWindow the fallback path must not crash and
        // must route to performZoom when _zoomFill: is unavailable. We can't remove the
        // private selector, so assert the public contract on a window that records zoom.
        final class ZoomOnlyWindow: NSWindow {
            var zoomCount = 0
            override func responds(to aSelector: Selector!) -> Bool {
                if aSelector == NSSelectorFromString("_zoomFill:") { return false }
                return super.responds(to: aSelector)
            }
            override func performZoom(_ sender: Any?) { zoomCount += 1 }
        }
        let window = ZoomOnlyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        addTeardownBlock { window.close() }

        window.performWindowChromeFill(nil)

        XCTAssertEqual(window.zoomCount, 1)
    }

    // MARK: - Test helpers

    private func findLabel(in rootView: NSView, withText text: String) -> NSTextField? {
        if let label = rootView as? NSTextField, label.stringValue == text {
            return label
        }

        for subview in rootView.subviews {
            if let match = findLabel(in: subview, withText: text) {
                return match
            }
        }

        return nil
    }

    private func center(of rect: NSRect) -> NSPoint {
        NSPoint(x: rect.midX, y: rect.midY)
    }
}
