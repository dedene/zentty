import AppKit

/// The desktop placeholder shown over a pane while a phone holds its control
/// lease (spec §2.6): a centered card naming the controlling device with an
/// always-visible "Take Back Control" button that reclaims the pane instantly.
///
/// Styling mirrors the pane status/failure overlay (`PaneContainerView`):
/// a rounded, masked card over a dimmed backdrop, a semibold title, a secondary
/// message, and a rounded action button — built from system materials so the
/// view stands alone (it is exercised in a detached AppKit component test with no
/// window or theme injection).
@MainActor
final class CompanionLeasePlaceholderView: NSView {
    private enum Layout {
        static let cornerRadius: CGFloat = 10
        static let cardInset: CGFloat = 24
        static let cardMaxWidth: CGFloat = 360
        static let titleToMessage: CGFloat = 6
        static let messageToButton: CGFloat = 16
    }

    private let onTakeBack: () -> Void

    private let backdropView = NSView()
    private let cardView = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Controlled remotely")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let takeBackButton = NSButton(title: "Take Back Control", target: nil, action: nil)

    init(deviceName: String, onTakeBack: @escaping () -> Void) {
        self.onTakeBack = onTakeBack
        super.init(frame: .zero)
        setup(deviceName: deviceName)
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

    private static func message(for deviceName: String) -> String {
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "another device" : trimmed
        return "This pane is controlled by \(name)."
    }

    private func setup(deviceName: String) {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        backdropView.wantsLayer = true
        backdropView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdropView)

        cardView.material = .hudWindow
        cardView.blendingMode = .withinWindow
        cardView.state = .active
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = Layout.cornerRadius
        cardView.layer?.cornerCurve = .continuous
        cardView.layer?.masksToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardView)

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.stringValue = Self.message(for: deviceName)
        messageLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        takeBackButton.bezelStyle = .rounded
        takeBackButton.keyEquivalent = "\r"
        takeBackButton.target = self
        takeBackButton.action = #selector(handleTakeBack)
        takeBackButton.translatesAutoresizingMaskIntoConstraints = false

        cardView.addSubview(titleLabel)
        cardView.addSubview(messageLabel)
        cardView.addSubview(takeBackButton)

        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: bottomAnchor),

            cardView.centerXAnchor.constraint(equalTo: centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: centerYAnchor),
            cardView.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.cardMaxWidth),
            cardView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            cardView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: Layout.cardInset),
            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: Layout.cardInset),
            titleLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -Layout.cardInset),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Layout.titleToMessage),
            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            takeBackButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: Layout.messageToButton),
            takeBackButton.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            takeBackButton.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -Layout.cardInset),
        ])
    }

    @objc
    private func handleTakeBack() {
        onTakeBack()
    }

    // MARK: - Testing hooks

    var messageTextForTesting: String {
        messageLabel.stringValue
    }

    /// Fires the button's action exactly as a click would, for the detached
    /// component test (no window / run loop needed).
    func simulateTakeBackTapForTesting() {
        handleTakeBack()
    }
}
