import AppKit
import XCTest
@testable import Zentty

@MainActor
final class NotificationChromeCoordinatorTests: XCTestCase {
    func test_clicking_inbox_button_shows_and_closes_native_popover() {
        let store = NotificationStore(debounceInterval: 0.01)
        store.add(
            windowID: WindowID("window-main"),
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("pane-main"),
            state: .needsInput,
            tool: .codex,
            interactionKind: .question,
            interactionSymbolName: "list.bullet",
            statusText: "Needs decision",
            primaryText: "Review the plan",
            isDebounced: false
        )
        let coordinator = NotificationChromeCoordinator(store: store)
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 520, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        addTeardownBlock { @MainActor in
            coordinator.closePanel()
            window.orderOut(nil)
            window.close()
        }
        let button = coordinator.inboxButton
        button.frame = NSRect(x: 420, y: 270, width: 28, height: 28)
        contentView.addSubview(button)
        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        coordinator.setup(parentView: contentView, theme: ZenttyTheme.fallback(for: nil))

        button.performClick(nil)

        XCTAssertTrue(coordinator.isPopoverShownForTesting)
        XCTAssertTrue(coordinator.usesNativePopoverChromeForTesting)
        XCTAssertFalse(coordinator.isPopoverFullSizeContentForTesting)
        XCTAssertTrue(button.isPopoverPresentedForTesting)

        coordinator.closePanel()

        XCTAssertFalse(coordinator.isPopoverShownForTesting)
        XCTAssertFalse(button.isPopoverPresentedForTesting)
    }

    func test_dismissing_last_notification_keeps_open_popover_size_stable() throws {
        let store = NotificationStore(debounceInterval: 0.01)
        store.add(
            windowID: WindowID("window-main"),
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("pane-main"),
            state: .needsInput,
            tool: .grok,
            interactionKind: .question,
            interactionSymbolName: "bell.fill",
            statusText: "Agent ready",
            primaryText: "User Requests Random Question From Agent",
            isDebounced: false
        )
        let notification = try XCTUnwrap(store.notifications.first)
        let coordinator = NotificationChromeCoordinator(store: store)
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 520, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        addTeardownBlock { @MainActor in
            coordinator.closePanel()
            window.orderOut(nil)
            window.close()
        }
        let button = coordinator.inboxButton
        button.frame = NSRect(x: 420, y: 270, width: 28, height: 28)
        contentView.addSubview(button)
        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        coordinator.setup(parentView: contentView, theme: ZenttyTheme.fallback(for: nil))

        button.performClick(nil)
        let populatedSize = try XCTUnwrap(coordinator.popoverContentSizeForTesting)
        let populatedFrame = try XCTUnwrap(popoverContentViewFrame(for: coordinator))

        store.dismiss(id: notification.id)
        let clearedSize = try XCTUnwrap(coordinator.popoverContentSizeForTesting)
        let clearedFrame = try XCTUnwrap(popoverContentViewFrame(for: coordinator))

        XCTAssertTrue(store.notifications.isEmpty)
        XCTAssertEqual(clearedSize.height, populatedSize.height, accuracy: 0.1)
        XCTAssertEqual(clearedSize.width, populatedSize.width, accuracy: 0.1)
        XCTAssertEqual(clearedFrame.origin.x, populatedFrame.origin.x, accuracy: 0.1)
        XCTAssertEqual(clearedFrame.origin.y, populatedFrame.origin.y, accuracy: 0.1)
    }

    func test_popover_anchor_rect_targets_visual_bottom_center_in_parent_coordinates() throws {
        let coordinator = NotificationChromeCoordinator(store: NotificationStore(debounceInterval: 0.01))
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let chromeBar = NSView(frame: NSRect(x: 12, y: 260, width: 140, height: 36))
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 520, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        addTeardownBlock { @MainActor in
            window.orderOut(nil)
            window.close()
        }
        let button = coordinator.inboxButton
        button.frame = NSRect(x: 84, y: 4, width: 28, height: 28)
        chromeBar.addSubview(button)
        contentView.addSubview(chromeBar)
        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        coordinator.setup(parentView: contentView, theme: ZenttyTheme.fallback(for: nil))

        let anchorRect = try XCTUnwrap(coordinator.popoverAnchorRectForTesting)
        let buttonRect = button.convert(button.bounds, to: contentView)
        let visualBottomY = contentView.isFlipped ? buttonRect.maxY : buttonRect.minY

        XCTAssertEqual(anchorRect.midX, buttonRect.midX, accuracy: 1)
        XCTAssertEqual(anchorRect.midY, visualBottomY, accuracy: 1)
        XCTAssertEqual(anchorRect.width, 1, accuracy: 0.1)
        XCTAssertEqual(anchorRect.height, 1, accuracy: 0.1)
    }

    func test_popover_preferred_edge_opens_below_unflipped_positioning_view() {
        let positioningView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))

        XCTAssertEqual(NotificationChromeCoordinator.popoverPreferredEdge(for: positioningView), .minY)
    }

    func test_popover_preferred_edge_opens_below_flipped_positioning_view() {
        let positioningView = FlippedPositioningView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))

        XCTAssertEqual(NotificationChromeCoordinator.popoverPreferredEdge(for: positioningView), .maxY)
    }
}

private final class FlippedPositioningView: NSView {
    override var isFlipped: Bool {
        true
    }
}

@MainActor
private func popoverContentViewFrame(for coordinator: NotificationChromeCoordinator) -> NSRect? {
    let mirror = Mirror(reflecting: coordinator)
    guard let value = mirror.children.first(where: { $0.label == "notificationPopover" })?.value else {
        return nil
    }

    let optionalMirror = Mirror(reflecting: value)
    let popover = optionalMirror.children.first?.value as? NSPopover
    return popover?.contentViewController?.view.frame
}
