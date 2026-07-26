import AppKit

/// The desktop overlay shown over a pane while a phone holds its control lease
/// (spec §2.6). The pane's live surface keeps rendering behind the overlay (a
/// render keep-alive streams it to the phone mirror), and it is reframed to the
/// phone's exact grid and centered in the pane. The overlay dims everything
/// *around* that centered grid — the scrim carries a cutout for it — while a
/// frosted card names the controlling device, states the grid it is pinned to,
/// and offers a "Take Back Control" button that reclaims the pane instantly.
///
/// Compositing note: the scrim is a plain layer-backed view (a dynamic dark
/// fill) rather than a full-pane vibrancy view. Within-window vibrancy is not a
/// dependable way to sample the pane's Metal-backed surface, so we darken with a
/// translucent layer that always composites correctly over Metal and keeps the
/// live content visible underneath. The frosted look is reserved for the small
/// card, which sits over the scrim (a normal layer) and therefore blurs
/// predictably.
///
/// The view stands alone from system materials so it can be exercised in a
/// detached AppKit component test with no window or theme injection.
@MainActor
final class CompanionLeasePlaceholderView: NSView {
    private enum Layout {
        static let cornerRadius: CGFloat = 14
        static let cardInset: CGFloat = 26
        static let cardMaxWidth: CGFloat = 340
        static let glyphPointSize: CGFloat = 30
        static let glyphToTitle: CGFloat = 14
        static let titleToMessage: CGFloat = 5
        static let messageToGrid: CGFloat = 8
        static let messageToButton: CGFloat = 18
        /// Breathing room between the live grid's edge and the card.
        static let cardToGridGap: CGFloat = 16
    }

    private enum Animation {
        static let fadeDuration: TimeInterval = 0.18
        static let appearScale: CGFloat = 0.96
    }

    private let onTakeBack: () -> Void

    private let scrimView = ScrimView()
    private let cardContainer = NSView()
    private let cardView = NSVisualEffectView()
    private let glyphView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Controlled remotely")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let gridLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    private let takeBackButton = NSButton(title: "Take Back Control", target: nil, action: nil)

    /// Vertical offset of the card from the pane's centre, driven by
    /// `setLiveGridRect` so the card never sits on top of the live grid.
    private lazy var cardCenterYConstraint: NSLayoutConstraint =
        cardContainer.centerYAnchor.constraint(equalTo: centerYAnchor)

    init(
        deviceName: String,
        gridSize: (cols: Int, rows: Int)? = nil,
        onTakeBack: @escaping () -> Void
    ) {
        self.onTakeBack = onTakeBack
        super.init(frame: .zero)
        setup(deviceName: deviceName, gridSize: gridSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Updates the controlling-device line without rebuilding the view (used when a
    /// lease is superseded by another device without an intervening restore).
    func updateDeviceName(_ deviceName: String) {
        messageLabel.stringValue = Self.message(for: deviceName)
    }

    /// Refreshes both lines in place. A lease is re-applied on every phone-side
    /// resize and on supersede, so the card must follow without being rebuilt.
    func update(deviceName: String, gridSize: (cols: Int, rows: Int)?) {
        updateDeviceName(deviceName)
        applyGridSize(gridSize)
    }

    /// The rect (in this view's coordinates) occupied by the live, centered grid.
    /// The scrim leaves it undimmed; `nil` dims the whole pane.
    ///
    /// The card is pushed clear of that rect so the cutout actually exposes live
    /// output: centering both on the pane would park a 340pt-wide card over a
    /// 360pt-wide grid, occluding exactly what the cutout exists to reveal.
    func setLiveGridRect(_ rect: CGRect?) {
        scrimView.cutoutRect = rect
        positionCard(clearOf: rect)
    }

    /// Moves the card below the live grid when there is room, otherwise above it,
    /// falling back to pane-centered when no grid rect is known (or it fills the
    /// pane, in which case nothing is undimmed anyway).
    private func positionCard(clearOf gridRect: CGRect?) {
        guard let gridRect, !gridRect.isEmpty else {
            cardCenterYConstraint.constant = 0
            return
        }
        // AppKit's default (unflipped) geometry: minY is the bottom edge.
        let spaceBelow = gridRect.minY - bounds.minY
        let spaceAbove = bounds.maxY - gridRect.maxY
        let needed = cardContainer.fittingSize.height + Layout.cardToGridGap
        let paneCenterY = bounds.midY

        if spaceBelow >= needed {
            cardCenterYConstraint.constant = (gridRect.minY - needed / 2) - paneCenterY
        } else if spaceAbove >= needed {
            cardCenterYConstraint.constant = (gridRect.maxY + needed / 2) - paneCenterY
        } else {
            // The grid leaves no room on either side; centering keeps the card
            // fully on-screen, and an edge-to-edge grid has nothing to reveal.
            cardCenterYConstraint.constant = 0
        }
    }

    private func applyGridSize(_ gridSize: (cols: Int, rows: Int)?) {
        guard let gridSize, gridSize.cols > 0, gridSize.rows > 0 else {
            gridLabel.stringValue = ""
            gridLabel.isHidden = true
            return
        }
        gridLabel.stringValue = "\(gridSize.cols) × \(gridSize.rows)"
        gridLabel.isHidden = false
    }

    private static func message(for deviceName: String) -> String {
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "another device" : trimmed
        return "This pane is controlled by \(name)."
    }

    private func setup(deviceName: String, gridSize: (cols: Int, rows: Int)?) {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        scrimView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrimView)

        // The container carries the (unclipped) drop shadow; the material inside
        // clips itself to the rounded corners. Keeping them separate lets the card
        // both cast a shadow and mask its blur.
        cardContainer.wantsLayer = true
        cardContainer.layer?.masksToBounds = false
        cardContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardContainer)

        cardView.material = .hudWindow
        cardView.blendingMode = .withinWindow
        cardView.state = .active
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = Layout.cornerRadius
        cardView.layer?.cornerCurve = .continuous
        cardView.layer?.masksToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardContainer.addSubview(cardView)

        if let glyph = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil) {
            glyphView.image = glyph
            glyphView.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: Layout.glyphPointSize,
                weight: .regular
            )
        }
        glyphView.contentTintColor = .secondaryLabelColor
        glyphView.imageScaling = .scaleProportionallyUpOrDown
        glyphView.translatesAutoresizingMaskIntoConstraints = false
        glyphView.setContentHuggingPriority(.required, for: .vertical)

        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.stringValue = Self.message(for: deviceName)
        messageLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        // Monospaced digits keep the grid line from jittering as the phone
        // re-measures its viewport mid-lease.
        gridLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        gridLabel.textColor = .tertiaryLabelColor
        gridLabel.alignment = .center
        gridLabel.translatesAutoresizingMaskIntoConstraints = false
        applyGridSize(gridSize)

        textStack.orientation = .vertical
        textStack.alignment = .width
        textStack.spacing = Layout.titleToMessage
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setViews([titleLabel, messageLabel, gridLabel], in: .top)
        textStack.setCustomSpacing(Layout.messageToGrid, after: messageLabel)

        takeBackButton.bezelStyle = .rounded
        takeBackButton.controlSize = .large
        takeBackButton.keyEquivalent = "\r"
        takeBackButton.target = self
        takeBackButton.action = #selector(handleTakeBack)
        takeBackButton.translatesAutoresizingMaskIntoConstraints = false

        cardView.addSubview(glyphView)
        cardView.addSubview(textStack)
        cardView.addSubview(takeBackButton)

        NSLayoutConstraint.activate([
            scrimView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrimView.topAnchor.constraint(equalTo: topAnchor),
            scrimView.bottomAnchor.constraint(equalTo: bottomAnchor),

            cardContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            cardCenterYConstraint,
            cardContainer.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.cardMaxWidth),
            cardContainer.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
            cardContainer.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            cardContainer.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            cardContainer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            cardView.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor),
            cardView.topAnchor.constraint(equalTo: cardContainer.topAnchor),
            cardView.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor),

            glyphView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: Layout.cardInset),
            glyphView.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),

            textStack.topAnchor.constraint(equalTo: glyphView.bottomAnchor, constant: Layout.glyphToTitle),
            textStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: Layout.cardInset),
            textStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -Layout.cardInset),

            takeBackButton.topAnchor.constraint(equalTo: textStack.bottomAnchor, constant: Layout.messageToButton),
            takeBackButton.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            takeBackButton.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -Layout.cardInset),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Pane controlled remotely")

        applyCardShadow()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCardShadow()
    }

    /// A soft drop shadow lifts the card off the receding surface. Rebuilt on
    /// appearance changes so it reads on both light and dark backdrops.
    private func applyCardShadow() {
        guard let layer = cardContainer.layer else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = isDark ? 0.55 : 0.28
        layer.shadowRadius = 22
        layer.shadowOffset = CGSize(width: 0, height: -6)
        layer.masksToBounds = false
    }

    // MARK: - Appearance transitions

    /// Fades the overlay in from transparent with a subtle card lift, matching the
    /// app's short overlay timings (~180ms, ease-out).
    func animateIn() {
        alphaValue = 0
        cardContainer.layer?.transform = CATransform3DMakeScale(Animation.appearScale, Animation.appearScale, 1)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Animation.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            animator().alphaValue = 1
            cardContainer.layer?.transform = CATransform3DIdentity
        }
    }

    /// Fades the overlay out, then removes it from its superview. Safe to call on a
    /// view that has already been detached from the lease (the host clears its
    /// reference first so a fresh lease builds a new overlay).
    func animateOutAndRemove() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Animation.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
        })
    }

    @objc
    private func handleTakeBack() {
        onTakeBack()
    }

    // MARK: - Testing hooks

    var messageTextForTesting: String {
        messageLabel.stringValue
    }

    var gridTextForTesting: String {
        gridLabel.stringValue
    }

    var isGridLineHiddenForTesting: Bool {
        gridLabel.isHidden
    }

    var liveGridRectForTesting: CGRect? {
        scrimView.cutoutRect
    }

    /// Fires the button's action exactly as a click would, for the detached
    /// component test (no window / run loop needed).
    func simulateTakeBackTapForTesting() {
        handleTakeBack()
    }
}

/// Translucent dark fill that dims the pane around the centered live grid. The
/// grid itself is punched out (even-odd fill) so it keeps reading as live while
/// the surround recedes; with no cutout the whole pane dims. Drawn rather than
/// set as a layer background so the cutout and the light/dark alpha are both
/// re-resolved on every redraw.
private final class ScrimView: NSView {
    var cutoutRect: CGRect? {
        didSet {
            guard cutoutRect != oldValue else { return }
            needsDisplay = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let alpha: CGFloat = isDark ? 0.55 : 0.42
        let path = NSBezierPath(rect: bounds)
        if let cutoutRect {
            let hole = cutoutRect.intersection(bounds)
            if !hole.isNull, !hole.isEmpty {
                path.append(NSBezierPath(rect: hole))
                path.windingRule = .evenOdd
            }
        }
        NSColor.black.withAlphaComponent(alpha).setFill()
        path.fill()
    }
}
