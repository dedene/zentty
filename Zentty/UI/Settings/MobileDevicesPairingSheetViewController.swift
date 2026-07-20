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

    private let qrImageView = NSImageView()
    private let codeField = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    private static let qrDisplaySize: CGFloat = 240

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

        codeField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        codeField.isSelectable = true
        codeField.isBezeled = true
        codeField.bezelStyle = .roundedBezel
        codeField.drawsBackground = true
        codeField.lineBreakMode = .byTruncatingMiddle
        codeField.alignment = .center
        codeField.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(codeField)
        codeField.widthAnchor.constraint(equalToConstant: 300).isActive = true

        hintLabel.font = .systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center
        stack.addArrangedSubview(hintLabel)

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

    // MARK: - Rendering

    private func render(_ model: CompanionPairingOfferModel) {
        qrImageView.image = Self.qrImage(from: model.qrPayloadJSON, displaySize: Self.qrDisplaySize)
        codeField.stringValue = model.manualCode
        countdownLabel.stringValue = "Expires in \(model.countdownText())"
        hintLabel.stringValue = "The code refreshes automatically when it expires."
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
