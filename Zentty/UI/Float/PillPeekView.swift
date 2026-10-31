import AppKit

/// Hover popover above a pill: the float's name and its last lines of
/// styled output, re-read every `pollInterval` while it shows. Reading text
/// never touches the surface's activity, so a minimized pane stays occluded.
@MainActor
final class PillPeekView: NSView {
    static let size = CGSize(width: 340, height: 168)
    static let lineCount = 10
    static let pollInterval: TimeInterval = 0.25
    /// Gap between the pill's top edge and the peek.
    static let anchorGap: CGFloat = 8
    static let edgeInset: CGFloat = 8
    private static let headerHeight: CGFloat = 22
    private static let bodyInsets = NSEdgeInsets(top: 5, left: 9, bottom: 6, right: 9)
    private static let bodyFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
    private static let lineHeight: CGFloat = 13

    /// Styled text (SGR) of a pane's visible screen; nil when unreadable.
    var textProvider: ((PaneID) -> String?)?
    private(set) var paneID: PaneID?
    private(set) var pollCount = 0
    private var pollTimer: Timer?
    private var theme = ZenttyTheme.fallback(for: nil)
    private var visibilityGeneration = 0
    private let contentView = NSView()
    private let separatorView = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: CGRect(origin: frameRect.origin, size: Self.size))
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.6
        layer?.shadowRadius = 25
        layer?.shadowOffset = CGSize(width: 0, height: -18)
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 10
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true
        contentView.layer?.borderWidth = 1
        addSubview(contentView)
        separatorView.wantsLayer = true
        nameLabel.font = .systemFont(ofSize: 10.5, weight: .bold)
        subtitleLabel.font = .systemFont(ofSize: 10.5)
        for label in [nameLabel, subtitleLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        bodyLabel.maximumNumberOfLines = Self.lineCount
        bodyLabel.cell?.wraps = false
        bodyLabel.lineBreakMode = .byClipping
        [separatorView, nameLabel, subtitleLabel, bodyLabel].forEach(contentView.addSubview)
        isHidden = true
        alphaValue = 0
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopPolling()
        }
    }

    var isPolling: Bool {
        pollTimer != nil
    }

    func apply(theme: ZenttyTheme) {
        self.theme = theme
        contentView.layer?.backgroundColor = theme.paneOpaqueBackdrop.cgColor
        contentView.layer?.borderColor = theme.paneBorderUnfocused.cgColor
        separatorView.layer?.backgroundColor = theme.paneBorderUnfocused.withAlphaComponent(0.7).cgColor
        nameLabel.textColor = theme.primaryText
        subtitleLabel.textColor = theme.tertiaryText
    }

    /// Shows the peek for `item` above `anchor` (the pill's frame in the
    /// superview's coordinates), kept inside the superview, and starts polling.
    func show(_ item: PillBarItem, above anchor: CGRect) {
        let isNewPane = paneID != item.paneID
        paneID = item.paneID
        nameLabel.stringValue = item.name
        subtitleLabel.stringValue = item.subtitle ?? ""
        frame = Self.frame(above: anchor, in: superview?.bounds ?? .zero)
        needsLayout = true
        if isNewPane || pollTimer == nil {
            refresh()
            startPolling()
        }
        fade(in: true)
    }

    /// Hides the peek and stops polling.
    func hide() {
        guard paneID != nil || pollTimer != nil else { return }
        paneID = nil
        stopPolling()
        fade(in: false)
    }

    /// Re-reads the hovered pane's text.
    func refresh() {
        guard let paneID else { return }
        pollCount += 1
        let raw = textProvider?(paneID) ?? ""
        let tail = StyledTerminalText.tail(raw, maxLines: Self.lineCount)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.minimumLineHeight = Self.lineHeight
        paragraph.maximumLineHeight = Self.lineHeight
        let text = NSMutableAttributedString(attributedString: StyledTerminalText.attributedString(
            from: tail,
            style: StyledTerminalText.Style(
                font: Self.bodyFont,
                foreground: theme.primaryText,
                background: theme.paneOpaqueBackdrop
            )
        ))
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        bodyLabel.attributedStringValue = text
        needsLayout = true
    }

    /// Above the pill, right edges aligned, kept inside `container`.
    static func frame(above anchor: CGRect, in container: CGRect) -> CGRect {
        var x = anchor.maxX - size.width
        let maxX = container.maxX - edgeInset - size.width
        x = min(x, maxX)
        x = max(x, container.minX + edgeInset)
        return CGRect(x: x.rounded(), y: (anchor.maxY + anchorGap).rounded(), width: size.width, height: size.height)
    }

    var bodyTextForTesting: String {
        bodyLabel.attributedStringValue.string
    }

    var bodyAttributedTextForTesting: NSAttributedString {
        bodyLabel.attributedStringValue
    }

    var nameForTesting: String {
        nameLabel.stringValue
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        contentView.frame = bounds
        let headerY = bounds.height - Self.headerHeight
        separatorView.frame = CGRect(x: 0, y: headerY, width: bounds.width, height: 1)
        let nameSize = nameLabel.intrinsicContentSize
        let nameWidth = min(ceil(nameSize.width), bounds.width * 0.6)
        nameLabel.frame = CGRect(
            x: 9,
            y: headerY + ((Self.headerHeight - nameSize.height) / 2).rounded(),
            width: nameWidth,
            height: nameSize.height
        )
        let subtitleX = nameLabel.frame.maxX + 6
        subtitleLabel.frame = CGRect(
            x: subtitleX,
            y: nameLabel.frame.minY,
            width: max(0, bounds.width - 9 - subtitleX),
            height: nameSize.height
        )
        // Bottom-aligned, like a terminal.
        let insets = Self.bodyInsets
        let bodyHeight = min(
            headerY - insets.top - insets.bottom,
            ceil(bodyLabel.attributedStringValue.boundingRect(
                with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin]
            ).height) + 2
        )
        bodyLabel.frame = CGRect(
            x: insets.left,
            y: insets.bottom,
            width: bounds.width - insets.left - insets.right,
            height: max(0, bodyHeight)
        )
    }

    // MARK: - Polling and fade

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func fade(in visible: Bool) {
        visibilityGeneration += 1
        let generation = visibilityGeneration
        if visible {
            isHidden = false
        }
        guard window != nil, !FloatMotion.reduceMotion else {
            alphaValue = visible ? 1 : 0
            isHidden = !visible
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeIn)
            self.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: {
            MainActorShim.assumeIsolated {
                guard generation == self.visibilityGeneration else { return }
                self.isHidden = !visible
            }
        })
    }
}
