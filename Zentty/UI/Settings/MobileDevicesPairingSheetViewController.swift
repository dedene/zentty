import AppKit
import CoreImage

/// The "Pair New Device" sheet: renders the current pairing offer as a QR code,
/// shows the paste-able short-code fallback, and counts down to expiry —
/// re-minting a fresh offer automatically when the timer runs out.
///
/// All offer lifecycle lives in `CompanionPairingSession` (window-free, tested in
/// `ZenttyLogicTests`); this controller only draws it and drives the timer.
@MainActor
final class MobileDevicesPairingSheetViewController: NSViewController {
    private let session: CompanionPairingSession
    private let onClose: () -> Void

    private var countdownTimer: Timer?
    private var copyFeedbackWorkItem: DispatchWorkItem?

    private let qrImageView = NSImageView()
    private let codeField = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let cautionLabel = NSTextField(labelWithString: "")
    private let copyCodeButton = NSButton(title: "Copy Code", target: nil, action: nil)

    private static let qrDisplaySize: CGFloat = 240
    /// Width of the wrapped manual-code block, matching the subtitle's cap so
    /// the sheet stays a consistent width regardless of code length.
    private static let codeFieldWidth: CGFloat = 320
    private static let copyFeedbackTitle = "Copied"
    private static let copyIdleTitle = "Copy Code"

    init(session: CompanionPairingSession, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let titleLabel = NSTextField(labelWithString: "Pair a Mobile Device")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(titleLabel)

        let subtitle = SettingsFormBuilder.label(
            "Scan this code with the Zentty app on your phone while it is on the same Wi\u{2011}Fi network.",
            font: .systemFont(ofSize: 12, weight: .regular)
        )
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        stack.addArrangedSubview(subtitle)
        subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true

        qrImageView.translatesAutoresizingMaskIntoConstraints = false
        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        qrImageView.wantsLayer = true
        qrImageView.layer?.magnificationFilter = .nearest
        qrImageView.layer?.cornerRadius = 8
        qrImageView.layer?.backgroundColor = NSColor.white.cgColor
        stack.addArrangedSubview(qrImageView)
        NSLayoutConstraint.activate([
            qrImageView.widthAnchor.constraint(equalToConstant: Self.qrDisplaySize),
            qrImageView.heightAnchor.constraint(equalToConstant: Self.qrDisplaySize),
        ])

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        countdownLabel.textColor = .secondaryLabelColor
        countdownLabel.alignment = .center
        stack.addArrangedSubview(countdownLabel)

        let codeHeader = SettingsFormBuilder.label(
            "Can't scan? Enter this code on your phone:",
            font: .systemFont(ofSize: 12, weight: .regular)
        )
        codeHeader.textColor = .secondaryLabelColor
        codeHeader.alignment = .center
        stack.addArrangedSubview(codeHeader)

        // Wraps the full base64url code instead of ellipsizing it — the manual
        // code is the phone's only fallback when it can't scan the QR, so
        // truncating it here would make that fallback useless.
        codeField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        codeField.isSelectable = true
        codeField.isBezeled = false
        codeField.drawsBackground = false
        codeField.lineBreakMode = .byCharWrapping
        codeField.maximumNumberOfLines = 0
        codeField.cell?.wraps = true
        codeField.alignment = .left
        codeField.translatesAutoresizingMaskIntoConstraints = false
        // `labelWithString:` defaults to single-line mode; disable it so the
        // cell actually lays the text out across multiple wrapped lines.
        (codeField.cell as? NSTextFieldCell)?.usesSingleLineMode = false
        // Without this a wrapping NSTextField reports a single-line intrinsic
        // height inside the stack view; 20 = the 10pt horizontal insets below.
        codeField.preferredMaxLayoutWidth = Self.codeFieldWidth - 20

        // A rounded, subtly-filled wrapper (no NSTextField bezel, which looks
        // wrong on a multi-line label) with real insets so the wrapped code
        // doesn't touch the border.
        let codeBackground = CodeBackgroundView()
        codeBackground.translatesAutoresizingMaskIntoConstraints = false
        codeBackground.wantsLayer = true
        codeBackground.layer?.cornerRadius = 6
        codeBackground.layer?.cornerCurve = .continuous
        codeBackground.layer?.borderWidth = 1
        codeBackground.addSubview(codeField)
        stack.addArrangedSubview(codeBackground)
        NSLayoutConstraint.activate([
            codeBackground.widthAnchor.constraint(equalToConstant: Self.codeFieldWidth),
            codeField.topAnchor.constraint(equalTo: codeBackground.topAnchor, constant: 8),
            codeField.bottomAnchor.constraint(equalTo: codeBackground.bottomAnchor, constant: -8),
            codeField.leadingAnchor.constraint(equalTo: codeBackground.leadingAnchor, constant: 10),
            codeField.trailingAnchor.constraint(equalTo: codeBackground.trailingAnchor, constant: -10),
        ])

        copyCodeButton.target = self
        copyCodeButton.action = #selector(handleCopyCode(_:))
        copyCodeButton.bezelStyle = .rounded
        copyCodeButton.controlSize = .small
        stack.addArrangedSubview(copyCodeButton)

        hintLabel.font = .systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center
        stack.addArrangedSubview(hintLabel)

        // Shown only while the offer carries no reachable endpoint (no LAN hint and
        // no relay), so an unscannable-but-unreachable code is never presented as
        // if it will work. Cleared once the listener's port appears and the offer
        // is re-minted with a LAN hint.
        cautionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        cautionLabel.textColor = .systemOrange
        cautionLabel.alignment = .center
        cautionLabel.lineBreakMode = .byWordWrapping
        cautionLabel.maximumNumberOfLines = 0
        cautionLabel.isHidden = true
        stack.addArrangedSubview(cautionLabel)
        cautionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        let regenerateButton = NSButton(title: "New Code", target: self, action: #selector(handleRegenerate(_:)))
        regenerateButton.bezelStyle = .rounded
        let doneButton = NSButton(title: "Done", target: self, action: #selector(handleDone(_:)))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        buttonRow.addArrangedSubview(regenerateButton)
        buttonRow.addArrangedSubview(doneButton)
        stack.addArrangedSubview(buttonRow)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])

        view = root
        render(session.current)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startCountdown()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopCountdown()
        copyFeedbackWorkItem?.cancel()
        onClose()
    }

    // MARK: - Timer

    private func startCountdown() {
        stopCountdown()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    private func tick() {
        if session.regenerateIfExpired() {
            render(session.current)
        } else {
            countdownLabel.stringValue = "Expires in \(session.current.countdownText())"
        }
    }

    /// Called by the settings section when the bridge signals its advertising
    /// state changed (the LAN listener came up or went away). Re-mints when the
    /// displayed offer still lacks an endpoint so it can pick up the now-live LAN
    /// hint, and re-renders to clear the caution.
    func advertisingStateDidChange() {
        if session.regenerateIfMissingEndpoint() {
            render(session.current)
        }
    }

    // MARK: - Actions

    @objc
    private func handleRegenerate(_ sender: Any?) {
        session.regenerate()
        render(session.current)
    }

    @objc
    private func handleDone(_ sender: Any?) {
        guard let sheetWindow = view.window else { return }
        sheetWindow.sheetParent?.endSheet(sheetWindow)
    }

    @objc
    private func handleCopyCode(_ sender: Any?) {
        // Read the code at click time rather than capturing it earlier — the
        // session re-mints on expiry, so a stale capture could copy a code
        // the phone can no longer redeem.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.current.manualCode, forType: .string)

        copyFeedbackWorkItem?.cancel()
        copyCodeButton.title = Self.copyFeedbackTitle
        let workItem = DispatchWorkItem { [weak self] in
            self?.copyCodeButton.title = Self.copyIdleTitle
        }
        copyFeedbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    // MARK: - Rendering

    private func render(_ model: CompanionPairingOfferModel) {
        qrImageView.image = Self.qrImage(from: model.qrPayloadJSON, displaySize: Self.qrDisplaySize)
        codeField.stringValue = model.manualCode
        countdownLabel.stringValue = "Expires in \(model.countdownText())"
        hintLabel.stringValue = "The code refreshes automatically when it expires."

        // While the offer has no reachable endpoint, warn instead of presenting a
        // dead code. The listener reports its port asynchronously, so the very
        // first minted offer is usually endpoint-less for a moment; if the listener
        // never comes up (permission denied, port exhaustion, feature disabled) the
        // caution simply persists.
        let lacksEndpoint = session.currentOfferLacksEndpoint
        cautionLabel.isHidden = !lacksEndpoint
        if lacksEndpoint {
            cautionLabel.stringValue = "Waiting for the local network listener\u{2026}"
        }

        // The old code's "Copied" feedback no longer applies to a freshly
        // minted code — reset it so the button doesn't lie about what's on
        // the pasteboard.
        copyFeedbackWorkItem?.cancel()
        copyCodeButton.title = Self.copyIdleTitle
    }

    /// Renders a string into a crisp QR `NSImage` sized for `displaySize`.
    static func qrImage(from string: String, displaySize: CGFloat) -> NSImage? {
        let data = Data(string.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        // Medium correction balances density against resilience for a ~250-byte
        // offer displayed on-screen (not printed).
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let moduleExtent = output.extent
        guard moduleExtent.width > 0 else { return nil }
        let scale = max(1, displaySize / moduleExtent.width)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Rounded fill behind the manual pairing code that re-resolves its dynamic
/// colors through `updateLayer`, so it tracks light/dark appearance changes
/// (a one-time `cgColor` snapshot would not).
private final class CodeBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
