import AppKit
import QuartzCore

/// The pill bar: a row at the bottom of the canvas with one pill per
/// minimized float of the active worklane. In flow (the strip shrinks by
/// `PillBarLayout.barHeight` while it shows), hit-transparent between pills.
///
/// Click a pill: restore. Drag it up out of the bar: promote to a PiP.
/// Hover: the canvas shows a peek above it (`onPeekChanged`).
@MainActor
final class PillBarView: NSView {
    var onPillClicked: ((PaneID) -> Void)?
    /// A VoiceOver custom action on a pill (picture in picture, close).
    var onPillActionRequested: ((PaneID, PaneBorderAction) -> Void)?
    /// A pill was released `PillBarLayout.promoteDistance` above the bar;
    /// the point is in bar coordinates.
    var onPillPromoted: ((PaneID, CGPoint) -> Void)?
    /// The hovered pill and its frame in bar coordinates; nil when no pill
    /// is hovered (or a drag started).
    var onPeekChanged: ((PillBarItem?, CGRect) -> Void)?
    /// A pill grew out of a float or PiP (pane, from frame in bar coordinates).
    var onArrivalForTesting: ((PaneID, CGRect) -> Void)?
    /// Opens the overflow menu (tests replace it; AppKit's pop-up is modal).
    var overflowMenuPresenter: ((NSMenu, PillOverflowView) -> Void) = { menu, view in
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: view.bounds.maxY + 4), in: view)
    }

    private(set) var content = PillBarContent.empty
    private var theme = ZenttyTheme.fallback(for: nil)
    private var pillViews: [PaneID: PillView] = [:]
    private let overflowView = PillOverflowView()
    private(set) var layoutResult = PillBarLayout.layout(fullWidths: [], compactWidths: [], in: .zero)
    private var hoveredPaneID: PaneID?
    private var press: Press?

    private struct Press {
        let paneID: PaneID
        let startInWindow: CGPoint
        let slotFrame: CGRect
        var isDragging = false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        overflowView.isHidden = true
        overflowView.onPress = { [weak self] in
            self?.showOverflowMenu()
        }
        addSubview(overflowView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Minimized panes")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Render

    func render(_ content: PillBarContent, theme: ZenttyTheme) {
        self.content = content
        self.theme = theme
        let ids = Set(content.items.map(\.paneID))
        for (paneID, view) in pillViews where !ids.contains(paneID) {
            view.removeFromSuperview()
            pillViews.removeValue(forKey: paneID)
            if press?.paneID == paneID {
                press = nil
            }
        }
        for item in content.items where pillViews[item.paneID] == nil {
            let view = PillView(item: item)
            let paneID = item.paneID
            view.onHoverChanged = { [weak self] hovered in
                self?.pillHoverChanged(paneID, hovered: hovered)
            }
            view.onPress = { [weak self] in
                self?.onPillClicked?(paneID)
            }
            view.onAction = { [weak self] action in
                self?.onPillActionRequested?(paneID, action)
            }
            pillViews[paneID] = view
            addSubview(view)
        }
        isHidden = content.isEmpty
        layoutPills()
        if let hoveredPaneID, pillViews[hoveredPaneID] == nil {
            self.hoveredPaneID = nil
            onPeekChanged?(nil, .zero)
        } else if let hoveredPaneID, press?.isDragging != true,
                  let item = content.items.first(where: { $0.paneID == hoveredPaneID }),
                  let view = pillViews[hoveredPaneID] {
            onPeekChanged?(item, view.frame)
        }
    }

    override func layout() {
        super.layout()
        layoutPills()
    }

    private func layoutPills() {
        let widths = content.items.map(PillView.widths(for:))
        layoutResult = PillBarLayout.layout(
            fullWidths: widths.map(\.full),
            compactWidths: widths.map(\.compact),
            in: bounds
        )
        for (index, item) in content.items.enumerated() {
            guard let view = pillViews[item.paneID] else { continue }
            view.configure(item: item, style: layoutResult.style, theme: theme)
            guard let frame = layoutResult.frames[index] else {
                view.isHidden = true
                continue
            }
            view.isHidden = false
            if press?.paneID == item.paneID, press?.isDragging == true {
                continue
            }
            view.frame = frame
        }
        if let overflowFrame = layoutResult.overflowFrame {
            overflowView.isHidden = false
            overflowView.frame = overflowFrame
            overflowView.configure(count: layoutResult.overflow.count, theme: theme)
        } else {
            overflowView.isHidden = true
        }
    }

    // MARK: - Hit testing and mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Hidden while worklane peek fades the bar out.
        guard !isHidden, alphaValue > 0 else { return nil }
        let local = convert(point, from: superview)
        if !overflowView.isHidden, overflowView.frame.contains(local) {
            return overflowView
        }
        if press != nil {
            return self
        }
        return pillView(at: local) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let view = pillView(at: local) else {
            press = nil
            return
        }
        press = Press(paneID: view.item.paneID, startInWindow: event.locationInWindow, slotFrame: view.frame)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var press, let view = pillViews[press.paneID] else { return }
        let dx = event.locationInWindow.x - press.startInWindow.x
        let dy = event.locationInWindow.y - press.startInWindow.y
        if !press.isDragging {
            guard hypot(dx, dy) >= PillBarLayout.dragThreshold else { return }
            press.isDragging = true
            hoveredPaneID = nil
            onPeekChanged?(nil, .zero)
            view.alphaValue = 0.92
            // Front-most while it travels.
            addSubview(view, positioned: .above, relativeTo: nil)
        }
        self.press = press
        view.frame = press.slotFrame.offsetBy(dx: dx, dy: dy)
    }

    override func mouseUp(with event: NSEvent) {
        guard let press else { return }
        self.press = nil
        let view = pillViews[press.paneID]
        guard press.isDragging else {
            onPillClicked?(press.paneID)
            return
        }
        view?.alphaValue = 1
        let release = convert(event.locationInWindow, from: nil)
        if PillBarLayout.promotesToPip(releasePoint: release, barBounds: bounds) {
            onPillPromoted?(press.paneID, release)
        }
        // Still here (not promoted, or the store said no): back to its slot.
        guard let view = pillViews[press.paneID], let index = content.items.firstIndex(where: {
            $0.paneID == press.paneID
        }), let slot = layoutResult.frames[index] else { return }
        if FloatMotion.reduceMotion || window == nil {
            view.frame = slot
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = FloatMotion.reflowTiming
                view.animator().frame = slot
            }
        }
    }

    private func pillView(at point: CGPoint) -> PillView? {
        pillViews.values.first { !$0.isHidden && $0.frame.contains(point) }
    }

    private func pillHoverChanged(_ paneID: PaneID, hovered: Bool) {
        if hovered {
            guard press?.isDragging != true,
                  let item = content.items.first(where: { $0.paneID == paneID }),
                  let view = pillViews[paneID] else { return }
            hoveredPaneID = paneID
            onPeekChanged?(item, view.frame)
        } else if hoveredPaneID == paneID {
            hoveredPaneID = nil
            onPeekChanged?(nil, .zero)
        }
    }

    // MARK: - Overflow

    /// The menu of pills that don't fit, oldest first; picking one restores it.
    func makeOverflowMenu() -> NSMenu {
        let menu = NSMenu(title: "Minimized panes")
        for index in layoutResult.overflow where content.items.indices.contains(index) {
            let item = content.items[index]
            let title = [item.name, item.subtitle].compactMap { $0 }.joined(separator: " · ")
            let menuItem = NSMenuItem(title: title, action: #selector(overflowItemSelected(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.paneID.rawValue
            menuItem.image = Self.dotImage(color: PillView.dotColor(for: item.attention, theme: theme))
            menuItem.setAccessibilityLabel(item.accessibilityLabel)
            menu.addItem(menuItem)
        }
        return menu
    }

    private func showOverflowMenu() {
        overflowMenuPresenter(makeOverflowMenu(), overflowView)
    }

    @objc private func overflowItemSelected(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        onPillClicked?(PaneID(rawValue))
    }

    private static func dotImage(color: NSColor) -> NSImage {
        NSImage(size: CGSize(width: 8, height: 8), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }

    // MARK: - Mode-change motion

    /// Frames of the pills on show (bar coordinates).
    func pillFrames() -> [PaneID: CGRect] {
        pillViews.filter { !$0.value.isHidden }.mapValues(\.frame)
    }

    /// `paneID`'s new pill grows out of `frame` (bar coordinates; the float
    /// or PiP it replaces) while it fades in from 0.2, like the mockup's
    /// minimize. Presentation only. Reduce Motion: a short fade in place.
    func animateArrival(of paneID: PaneID, from frame: CGRect) {
        guard window != nil, let view = pillViews[paneID], !view.isHidden,
              let layer = view.layer, view.frame.width > 0, view.frame.height > 0,
              frame.width > 0, frame.height > 0 else { return }
        let motion = FloatLayerView.TransitionMotion.self
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = FloatMotion.reduceMotion ? 0 : motion.morphStartOpacity
        opacity.toValue = 1
        let group = CAAnimationGroup()
        if FloatMotion.reduceMotion {
            group.animations = [opacity]
            group.duration = FloatMotion.reducedDuration
            group.timingFunction = FloatMotion.reducedTiming
        } else {
            let transform = CABasicAnimation(keyPath: "transform")
            transform.fromValue = NSValue(caTransform3D: FloatLayerView.transform(
                mapping: view.frame,
                to: frame,
                anchorPoint: layer.anchorPoint
            ))
            transform.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            group.animations = [transform, opacity]
            group.duration = motion.morphDuration
            group.timingFunction = FloatMotion.reflowTiming
        }
        layer.add(group, forKey: Self.arrivalAnimationKey)
        onArrivalForTesting?(paneID, frame)
    }

    static let arrivalAnimationKey = "zentty.pill.arrival"

    // MARK: - Testing

    func pillViewForTesting(_ paneID: PaneID) -> PillView? {
        pillViews[paneID]
    }

    var overflowViewForTesting: PillOverflowView {
        overflowView
    }
}
