import AppKit

/// Asks the user about a clipboard request libghostty could not decide on its own: a program reading
/// (or, if configured, writing) the clipboard, or a paste that looks like it runs commands.
@MainActor
enum TerminalClipboardConfirmationAlert {
    /// Calls `completion` exactly once with whether the user allowed the request and whether that
    /// choice should be remembered for the session.
    static func present(
        _ confirmation: TerminalClipboardConfirmation,
        window: NSWindow?,
        completion: @escaping @MainActor (_ allowed: Bool, _ remember: Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = confirmation.kind.messageText
        alert.informativeText = confirmation.kind.informativeText
        alert.accessoryView = previewView(confirmation)
        // Deny first so Return never hands over the clipboard by accident.
        alert.addButton(withTitle: confirmation.kind.denyButtonTitle)
        alert.addButton(withTitle: confirmation.kind.allowButtonTitle)
        if confirmation.canRemember {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Remember this choice for the session"
        }

        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            let allowed = response == .alertSecondButtonReturn
            completion(allowed, allowed && alert.suppressionButton?.state == .on)
        }

        // Deferred to the next main-loop turn so a modal never runs inside a libghostty callback.
        DispatchQueue.main.async {
            if let window, window.isVisible {
                alert.beginSheetModal(for: window) { response in
                    finish(response)
                }
            } else {
                finish(alert.runModal())
            }
        }
    }

    private static func previewView(_ confirmation: TerminalClipboardConfirmation) -> NSView {
        if let imageData = confirmation.imageData, let image = NSImage(data: imageData) {
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyDown
            imageView.imageFrameStyle = .grayBezel
            return imageView
        }

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = confirmation.previewText
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        return scrollView
    }
}
