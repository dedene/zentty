import AppKit
import QuartzCore

final class SidebarUpdateAvailableRowView: NSView {
    private enum Layout {
        static let horizontalPadding: CGFloat = 12
        static let iconLabelSpacing: CGFloat = 8
        static let iconSize: CGFloat = 14
        static let fontSize: CGFloat = 13
        static let nestedBottomRadius = ChromeGeometry.innerRadius(
            outerRadius: ShellMetrics.sidebarRadius,
            inset: ShellMetrics.sidebarContentInset
        )
    }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Update available")
    private let contentStack = NSStackView()
    var onPressed: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = Layout.nestedBottomRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.maskedCorners = [
            .layerMinXMinYCorner,
            .layerMaxXMinYCorner,
            .layerMinXMaxYCorner,
            .layerMaxXMaxYCorner,
        ]
        setAccessibilityLabel("Update available")
        setAccessibilityRole(.button)

        iconView.image = NSImage(
            systemSymbolName: "archivebox.fill",
            accessibilityDescription: "Update available"
        )?.withSymbolConfiguration(.init(pointSize: Layout.iconSize, weight: .semibold))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = NSFont.systemFont(ofSize: Layout.fontSize, weight: .semibold)
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = Layout.iconLabelSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setContentHuggingPriority(.required, for: .horizontal)
        contentStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(titleLabel)
        addSubview(contentStack)

        let clickGestureRecognizer = NSClickGestureRecognizer(
            target: self,
            action: #selector(handleClickGesture)
        )
        addGestureRecognizer(clickGestureRecognizer)

        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: Layout.horizontalPadding
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Layout.horizontalPadding
            ),
            iconView.widthAnchor.constraint(equalToConstant: Layout.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Layout.iconSize),
        ])
    }

    @objc
    private func handleClickGesture() {
        onPressed?()
    }

    func configure(theme: ZenttyTheme, animated: Bool) {
        let tint = NSColor.systemBlue
        let background = theme.sidebarBackground
            .mixed(towards: tint, amount: theme.sidebarBackground.isDarkThemeColor ? 0.34 : 0.16)
            .withAlphaComponent(theme.sidebarBackground.isDarkThemeColor ? 0.80 : 0.94)
        let text = tint
            .mixed(towards: theme.primaryText, amount: theme.sidebarBackground.isDarkThemeColor ? 0.14 : 0.06)
            .withAlphaComponent(0.98)
        let border = tint.withAlphaComponent(theme.sidebarBackground.isDarkThemeColor ? 0.22 : 0.16)

        titleLabel.textColor = text
        iconView.contentTintColor = text

        performThemeAnimation(animated: animated) {
            self.layer?.cornerRadius = Layout.nestedBottomRadius
            self.layer?.maskedCorners = [
                .layerMinXMinYCorner,
                .layerMaxXMinYCorner,
                .layerMinXMaxYCorner,
                .layerMaxXMaxYCorner,
            ]
            self.layer?.backgroundColor = background.cgColor
            self.layer?.borderColor = border.cgColor
            self.layer?.borderWidth = 1
        }
    }

    func performClickForTesting() {
        onPressed?()
    }
}
