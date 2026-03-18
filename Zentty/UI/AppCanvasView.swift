import AppKit
import QuartzCore

final class AppCanvasView: NSView {
    var onFocusSettled: ((PaneID) -> Void)? {
        didSet {
            paneStripView.onFocusSettled = onFocusSettled
        }
    }
    var onPaneSelected: ((PaneID) -> Void)? {
        didSet {
            paneStripView.onPaneSelected = onPaneSelected
        }
    }
    var onPaneCloseRequested: ((PaneID) -> Void)? {
        didSet {
            paneStripView.onPaneCloseRequested = onPaneCloseRequested
        }
    }

    var leadingVisibleInset: CGFloat {
        get { paneStripView.leadingVisibleInset }
        set { paneStripView.setLeadingVisibleInset(newValue, animated: false) }
    }
    private let paneStripView: PaneStripView
    private var currentTheme = ZenttyTheme.fallback(for: nil)

    init(frame frameRect: NSRect = .zero, runtimeRegistry: PaneRuntimeRegistry) {
        self.paneStripView = PaneStripView(runtimeRegistry: runtimeRegistry)
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = ChromeGeometry.contentShellRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0

        paneStripView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(paneStripView)

        NSLayoutConstraint.activate([
            paneStripView.topAnchor.constraint(equalTo: topAnchor),
            paneStripView.leadingAnchor.constraint(equalTo: leadingAnchor),
            paneStripView.trailingAnchor.constraint(equalTo: trailingAnchor),
            paneStripView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        paneStripView.apply(theme: currentTheme, animated: false)
        paneStripView.setLeadingVisibleInset(0, animated: false)
    }

    func render(
        workspaceName: String,
        state: PaneStripState,
        metadataByPaneID: [PaneID: TerminalMetadata] = [:],
        theme: ZenttyTheme,
        leadingVisibleInset: CGFloat? = nil,
        animated: Bool = true,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        apply(theme: theme, animated: animated)
        if let leadingVisibleInset {
            paneStripView.transition(
                to: state,
                leadingVisibleInset: leadingVisibleInset,
                animated: animated,
                duration: duration,
                timingFunction: timingFunction
            )
        } else {
            paneStripView.render(state)
        }
    }

    func focusCurrentPaneIfNeeded() {
        paneStripView.focusCurrentPaneIfNeeded()
    }

    func setLeadingVisibleInset(
        _ leadingVisibleInset: CGFloat,
        animated: Bool,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        paneStripView.setLeadingVisibleInset(
            leadingVisibleInset,
            animated: animated,
            duration: duration,
            timingFunction: timingFunction
        )
    }

    func updateMetadata(for paneID: PaneID, metadata: TerminalMetadata) {
        _ = paneID
        _ = metadata
    }

    var lastPaneStripRenderWasAnimatedForTesting: Bool {
        paneStripView.lastRenderWasAnimatedForTesting
    }

    var paneStripRenderCountForTesting: Int {
        paneStripView.renderInvocationCountForTesting
    }

    var lastLeadingVisibleInsetForTesting: CGFloat {
        paneStripView.leadingVisibleInsetForTesting
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        let didChange = theme != currentTheme
        currentTheme = theme

        if didChange {
            paneStripView.apply(theme: theme, animated: animated)
        }

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = NSColor.clear.cgColor
            self.layer?.borderColor = NSColor.clear.cgColor
        }
    }
}
