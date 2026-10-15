import AppKit

enum TerminalOverlayError: LocalizedError, Equatable {
    case paneNotFound
    case alreadyOpen
    case notOpen
    case invalidWorkingDirectory(String)

    var errorDescription: String? {
        switch self {
        case .paneNotFound: "Target pane not found."
        case .alreadyOpen: "An overlay already exists for this placement and target."
        case .notOpen: "This pane has no overlay."
        case .invalidWorkingDirectory(let path): "Overlay directory does not exist: \(path)"
        }
    }
}

/// Root view of an overlay. Clicks on its chrome must not fall through to the
/// pane it covers, whose `mouseDown` would focus the hidden terminal.
final class TerminalOverlayContainerView: NSView {
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
    }

    override func rightMouseDown(with event: NSEvent) {}
}

/// A persistent terminal embedded above its owning worklane or pane.
@MainActor
final class TerminalOverlaySession: NSObject {
    let id = "ov_\(UUID().uuidString.lowercased())"
    var paneID: PaneID
    var worklaneID: WorklaneID
    let placement: PaneOverlayIPCOptions.Placement
    /// The command the overlay runs; empty for an interactive shell.
    let command: String
    let view = TerminalOverlayContainerView()
    private let adapter: any TerminalAdapter
    private let host: TerminalPaneHostView
    private let titleLabel = NSTextField(labelWithString: "Quick action")
    private let closeButton: NSButton
    private let request: TerminalSessionRequest
    private let sizePercent: Int
    private var placementConstraints: [NSLayoutConstraint] = []
    private var isClosing = false
    var isPresented = true
    /// Set for `--notify` overlays opened out of sight, so following the
    /// notification to the pane shows the overlay it points at.
    var revealsOnNextNavigation = false
    private(set) var exitCode: Int?
    var onClose: (() -> Void)?
    var onRestoreFocus: (() -> Void)?

    init(
        paneID: PaneID,
        worklaneID: WorklaneID,
        command: String,
        workingDirectory: String?,
        wait: Bool,
        sizePercent: Int,
        placement: PaneOverlayIPCOptions.Placement,
        adapterFactory: (PaneID) -> any TerminalAdapter = { LibghosttyAdapter(paneID: $0) }
    ) {
        self.paneID = paneID
        self.worklaneID = worklaneID
        self.sizePercent = sizePercent
        self.placement = placement
        self.command = command
        adapter = adapterFactory(PaneID(id))
        host = TerminalPaneHostView(adapter: adapter)
        closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close overlay")!,
            target: nil, action: nil
        )
        request = TerminalSessionRequest(
            workingDirectory: workingDirectory,
            nativeCommand: command,
            waitAfterNativeCommand: wait,
            surfaceContext: .split
        )
        super.init()
        view.identifier = NSUserInterfaceItemIdentifier(id)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1

        let title = titleLabel
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false
        let close = closeButton
        close.target = self
        close.action = #selector(closeOverlay)
        close.bezelStyle = .inline
        close.isBordered = false
        close.translatesAutoresizingMaskIntoConstraints = false
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(title)
        view.addSubview(close)
        view.addSubview(host)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            close.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            close.widthAnchor.constraint(equalToConstant: 24),
            close.heightAnchor.constraint(equalToConstant: 24),
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 1),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -1),
            host.topAnchor.constraint(equalTo: view.topAnchor, constant: 32),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -1),
        ])
        host.onEventDidOccur = { [weak self] event in
            switch event {
            case .commandFinished(let code, _): self?.exitCode = code
            case .surfaceClosed: self?.close()
            default: break
            }
        }
        view.onMouseDown = { [weak self] in self?.focusTerminal() }
    }

    /// Ghostty draws no background of its own (Zentty sets `background-opacity = 0`
    /// and paints the backing), so the overlay paints the theme's terminal
    /// background. It stays opaque even for translucent themes, so the pane it
    /// covers never shows through.
    func apply(theme: ZenttyTheme) {
        view.layer?.backgroundColor = theme.windowBackground.withAlphaComponent(1).cgColor
        view.layer?.borderColor = theme.paneBorderFocused.cgColor
        titleLabel.textColor = theme.secondaryText
        closeButton.contentTintColor = theme.secondaryText
    }

    /// Shown on screen right now, as opposed to `isPresented`, which only records intent.
    var isShowing: Bool { !isClosing && !view.isHidden && view.window != nil }

    var holdsKeyboardFocus: Bool {
        (view.window?.firstResponder as? NSView)?.isDescendant(of: view) ?? false
    }

    /// Whether closing would kill a live process, so quit and close prompts must ask first.
    var needsCloseConfirmation: Bool { !isClosing && adapter.needsConfirmQuit }

    var runningQuickAction: RunningQuickAction {
        RunningQuickAction(command: command.isEmpty ? nil : command)
    }

    func focusTerminal() {
        guard isShowing else { return }
        host.focusTerminal()
    }

    func start() throws {
        do {
            try host.startSessionIfNeeded(using: request)
        } catch {
            close()
            throw error
        }
    }

    func setVisible(_ visible: Bool, anchor: NSView?, focus: Bool = false) {
        guard !isClosing else { return }
        if let anchor, view.superview !== anchor {
            NSLayoutConstraint.deactivate(placementConstraints)
            view.removeFromSuperview()
            anchor.addSubview(view, positioned: .above, relativeTo: nil)
            let fraction = CGFloat(sizePercent) / 100
            placementConstraints = [
                view.centerXAnchor.constraint(equalTo: anchor.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: anchor.centerYAnchor),
                view.widthAnchor.constraint(equalTo: anchor.widthAnchor, multiplier: fraction, constant: -32 * fraction),
                view.heightAnchor.constraint(equalTo: anchor.heightAnchor, multiplier: fraction, constant: -32 * fraction),
            ]
            NSLayoutConstraint.activate(placementConstraints)
        }
        view.isHidden = !visible || anchor == nil
        view.superview?.layoutSubtreeIfNeeded()
        let isVisible = !view.isHidden
        if isVisible { revealsOnNextNavigation = false }
        if isVisible && focus { host.focusTerminal() }
        host.setSurfaceActivity(TerminalSurfaceActivity(
            isVisible: isVisible, isFocused: isVisible && (focus || host.isTerminalFocused)
        ))
    }

    func hide(restoringFocus: Bool = true) {
        guard !isClosing else { return }
        let hadFocus = holdsKeyboardFocus
        isPresented = false
        setVisible(false, anchor: view.superview)
        if restoringFocus && hadFocus { onRestoreFocus?() }
    }

    @objc private func closeOverlay() { close() }

    func close(restoringFocus: Bool = true) {
        guard !isClosing else { return }
        isClosing = true
        let hadFocus = holdsKeyboardFocus
        adapter.close()
        NSLayoutConstraint.deactivate(placementConstraints)
        view.removeFromSuperview()
        onClose?()
        if restoringFocus && hadFocus { onRestoreFocus?() }
    }
}
