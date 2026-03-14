import AppKit

final class PaneStripView: NSView {
    var onFocusSettled: ((PaneID) -> Void)?
    var onPaneSelected: ((PaneID) -> Void)?
    var onPaneMetadataDidChange: ((PaneID, TerminalMetadata) -> Void)?

    private let motionController = PaneStripMotionController()
    private let gestureDriver = TrackpadPanGestureDriver()
    private let viewportView = NSView()
    private let adapterFactory: @MainActor () -> any TerminalAdapter

    private var currentState: PaneStripState?
    private var currentPresentation: StripPresentation?
    private var orderedPaneIDs: [PaneID] = []
    private var paneViews: [PaneID: PaneContainerView] = [:]
    private var lastRenderedSize: CGSize = .zero
    private var currentOffset: CGFloat = 0
    private var gestureBaseOffset: CGFloat = 0
    private var isInteracting = false
    private var lastFocusedPaneID: PaneID?

    override var fittingSize: NSSize {
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        return NSSize(width: width, height: height)
    }

    override init(frame frameRect: NSRect) {
        self.adapterFactory = { TerminalAdapterRegistry.makeAdapter() }
        super.init(frame: frameRect)
        setup()
    }

    init(
        frame frameRect: NSRect = .zero,
        adapterFactory: @escaping @MainActor () -> any TerminalAdapter
    ) {
        self.adapterFactory = adapterFactory
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

    func focusCurrentPaneIfNeeded() {
        syncFocusedTerminal(with: currentState?.focusedPaneID, force: true)
    }

    private func renderCurrentState(_ state: PaneStripState, animated: Bool) {
        let presentation = motionController.presentation(for: state, in: bounds.size)
        currentPresentation = presentation
        let targetOffset = isInteracting ? currentOffset : presentation.targetOffset
        reconcilePaneViews(with: state, presentation: presentation)
        orderedPaneIDs = presentation.panes.map(\.paneID)

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
        syncFocusedTerminal(with: state.focusedPaneID)
    }

    private func applyPresentation(_ presentation: StripPresentation, state: PaneStripState, offset: CGFloat) {
        presentation.panes.enumerated().forEach { index, panePresentation in
            guard let paneView = paneViews[panePresentation.paneID] else {
                return
            }

            let pane = state.panes[index]
            paneView.render(
                pane: pane,
                width: panePresentation.frame.width,
                height: panePresentation.frame.height,
                emphasis: panePresentation.emphasis,
                isFocused: panePresentation.isFocused
            )
            paneView.animator().frame = panePresentation.frame.offsetBy(dx: -offset, dy: 0)
        }
    }

    private func reconcilePaneViews(with state: PaneStripState, presentation: StripPresentation) {
        let nextPaneIDs = Set(presentation.panes.map(\.paneID))
        let obsoletePaneIDs = Set(paneViews.keys).subtracting(nextPaneIDs)

        for paneID in obsoletePaneIDs {
            paneViews[paneID]?.removeFromSuperview()
            paneViews.removeValue(forKey: paneID)
        }

        presentation.panes.enumerated().forEach { index, panePresentation in
            guard paneViews[panePresentation.paneID] == nil else {
                return
            }

            let pane = state.panes[index]
            let paneView = PaneContainerView(
                pane: pane,
                width: panePresentation.frame.width,
                height: panePresentation.frame.height,
                emphasis: panePresentation.emphasis,
                isFocused: panePresentation.isFocused,
                adapter: adapterFactory()
            )
            paneView.onSelected = { [weak self] in
                self?.onPaneSelected?(pane.id)
            }
            paneView.onMetadataDidChange = { [weak self] metadata in
                self?.onPaneMetadataDidChange?(pane.id, metadata)
            }
            paneViews[panePresentation.paneID] = paneView
            viewportView.addSubview(paneView)
        }

        lastFocusedPaneID = lastFocusedPaneID.flatMap { paneViews[$0] == nil ? nil : $0 }
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

    private func syncFocusedTerminal(with paneID: PaneID?, force: Bool = false) {
        guard let paneID else {
            lastFocusedPaneID = nil
            return
        }

        guard force || paneID != lastFocusedPaneID else {
            return
        }

        lastFocusedPaneID = paneID
        DispatchQueue.main.async { [weak self] in
            self?.paneViews[paneID]?.focusTerminal()
        }
    }
}
