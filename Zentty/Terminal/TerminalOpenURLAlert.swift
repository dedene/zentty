import AppKit

/// Carries out a TerminalOpenURLDecision: opens allowed targets, asks before a custom scheme, and
/// explains a block. Blocked targets never reach Launch Services; the user can only copy them.
@MainActor
enum TerminalOpenURLAlert {
    static func perform(_ decision: TerminalOpenURLDecision, window: NSWindow?) {
        switch decision {
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .confirm(let url, let displayString):
            presentConfirmation(for: url, displayString: displayString, window: window)
        case .block(let reason, let displayString):
            presentBlock(reason: reason, displayString: displayString, window: window)
        }
    }

    private static func presentConfirmation(for url: URL, displayString: String, window: NSWindow?) {
        let workspace = NSWorkspace.shared
        let handler = workspace.urlForApplication(toOpen: url)
            .map { "\u{201C}\($0.deletingPathExtension().lastPathComponent)\u{201D}" }
            ?? "the default application"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open Link from Terminal Output?"
        alert.informativeText = "This link will open in \(handler). Only continue if you recognize and trust the destination."
        alert.accessoryView = targetView(displayString)
        // Cancel first so Return does not open an unrecognized handler.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open Link")
        present(alert, window: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            workspace.open(url)
        }
    }

    private static func presentBlock(
        reason: TerminalUntrustedURL.DenialReason,
        displayString: String,
        window: NSWindow?
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Link Blocked"
        alert.informativeText = reason.message
        alert.accessoryView = targetView(displayString)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Link")
        present(alert, window: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(displayString, forType: .string)
        }
    }

    /// Deferred to the next main-loop turn so a modal never runs inside the action drain.
    private static func present(
        _ alert: NSAlert,
        window: NSWindow?,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) {
        DispatchQueue.main.async {
            if let window, window.isVisible {
                alert.beginSheetModal(for: window) { response in
                    completion(response)
                }
            } else {
                completion(alert.runModal())
            }
        }
    }

    private static func targetView(_ target: String) -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 72))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = target
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        return scrollView
    }
}
