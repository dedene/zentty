import AppKit

final class PaneStripView: NSView {
    var onFocusSettled: ((PaneID) -> Void)?

    private let motionController = PaneStripMotionController()
    private let gestureDriver = TrackpadPanGestureDriver()
    private let viewportView = NSView()

    private var currentState: PaneStripState?
    private var currentPresentation: StripPresentation?
    private var orderedPaneIDs: [PaneID] = []
    private var paneViews: [PaneID: PaneContainerView] = [:]
    private var lastRenderedSize: CGSize = .zero
    private var currentOffset: CGFloat = 0
    private var gestureBaseOffset: CGFloat = 0
    private var isInteracting = false

    override var fittingSize: NSSize {
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        return NSSize(width: width, height: height)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true

        viewportView.wantsLayer = true
        viewportView.layer?.backgroundColor = NSColor.clear.cgColor
        viewportView.layer?.masksToBounds = true
        viewportView.frame = bounds
        viewportView.autoresizingMask = [.width, .height]
        addSubview(viewportView)

        gestureDriver.onBegan = { [weak self] in
            self?.beginInteraction()
        }
        gestureDriver.onChanged = { [weak self] translationX in
            self?.updateInteraction(translationX: translationX)
        }
        gestureDriver.onEnded = { [weak self] translationX in
            self?.finishInteraction(translationX: translationX)
        }
        gestureDriver.install(on: self)
    }

    override func layout() {
        super.layout()
        viewportView.frame = bounds

        guard let currentState, bounds.size != .zero, bounds.size != lastRenderedSize else {
            return
        }

        renderCurrentState(currentState, animated: false)
    }

    func render(_ state: PaneStripState) {
        currentState = state
        guard bounds.size != .zero else {
            return
        }
        renderCurrentState(state, animated: !orderedPaneIDs.isEmpty && !isInteracting)
    }

    private func renderCurrentState(_ state: PaneStripState, animated: Bool) {
        let presentation = motionController.presentation(for: state, in: bounds.size)
        currentPresentation = presentation
        let targetOffset = isInteracting ? currentOffset : presentation.targetOffset
        let nextPaneIDs = presentation.panes.map(\.paneID)

        guard orderedPaneIDs == nextPaneIDs else {
            rebuildPaneViews(with: state, presentation: presentation)
            orderedPaneIDs = nextPaneIDs
            applyPresentation(presentation, state: state, offset: targetOffset)
            currentOffset = targetOffset
            lastRenderedSize = bounds.size
            return
        }

        let updates = {
            self.applyPresentation(presentation, state: state, offset: targetOffset)
        }

        if animated {
            motionController.animate(in: self, updates: updates)
        } else {
            updates()
        }

        if !isInteracting {
            currentOffset = targetOffset
        }
        lastRenderedSize = bounds.size
    }

    private func subtitle(for index: Int, focusedIndex: Int) -> String {
        if index == focusedIndex {
            return "focused"
        }

        if index < focusedIndex {
            return index == focusedIndex - 1 ? "left" : "off-left"
        }

        return index == focusedIndex + 1 ? "right" : "off-right"
    }

    private func rebuildPaneViews(with state: PaneStripState, presentation: StripPresentation) {
        viewportView.subviews.forEach { $0.removeFromSuperview() }
        paneViews.removeAll()

        presentation.panes.enumerated().forEach { index, panePresentation in
            let pane = state.panes[index]
            let paneView = PaneContainerView(
                title: pane.title,
                subtitle: subtitle(for: index, focusedIndex: state.focusedIndex),
                width: panePresentation.frame.width,
                height: panePresentation.frame.height,
                emphasis: panePresentation.emphasis,
                isFocused: panePresentation.isFocused
            )
            paneViews[panePresentation.paneID] = paneView
            viewportView.addSubview(paneView)
        }
    }

    private func applyPresentation(_ presentation: StripPresentation, state: PaneStripState, offset: CGFloat) {
        presentation.panes.enumerated().forEach { index, panePresentation in
            guard let paneView = paneViews[panePresentation.paneID] else {
                return
            }

            let pane = state.panes[index]
            paneView.render(
                title: pane.title,
                subtitle: subtitle(for: index, focusedIndex: state.focusedIndex),
                width: panePresentation.frame.width,
                height: panePresentation.frame.height,
                emphasis: panePresentation.emphasis,
                isFocused: panePresentation.isFocused
            )
            paneView.animator().frame = panePresentation.frame.offsetBy(dx: -offset, dy: 0)
        }
    }

    private func beginInteraction() {
        guard let currentPresentation else {
            return
        }

        isInteracting = true
        gestureBaseOffset = currentPresentation.targetOffset
    }

    private func updateInteraction(translationX: CGFloat) {
        guard let currentPresentation, let currentState else {
            return
        }

        currentOffset = motionController.clampedOffset(
            gestureBaseOffset - translationX,
            contentWidth: currentPresentation.contentWidth,
            viewportWidth: bounds.width
        )
        applyPresentation(currentPresentation, state: currentState, offset: currentOffset)
    }

    private func finishInteraction(translationX: CGFloat) {
        guard let currentPresentation, let currentState else {
            return
        }

        let proposedOffset = motionController.clampedOffset(
            gestureBaseOffset - translationX,
            contentWidth: currentPresentation.contentWidth,
            viewportWidth: bounds.width
        )
        let settledPaneID = motionController.nearestSettlePaneID(
            in: currentPresentation,
            proposedOffset: proposedOffset,
            viewportWidth: bounds.width
        )

        isInteracting = false

        guard let settledPaneID else {
            renderCurrentState(currentState, animated: true)
            return
        }

        if settledPaneID == currentState.focusedPaneID {
            currentOffset = currentPresentation.targetOffset
            renderCurrentState(currentState, animated: true)
            return
        }

        onFocusSettled?(settledPaneID)
    }
}
