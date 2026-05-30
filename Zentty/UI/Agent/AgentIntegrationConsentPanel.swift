import AppKit

/// First-run consent prompt for a persistent-config agent. Shown the first time
/// such an agent launches, or when enabling one from Settings. Explains what
/// Zentty will write to the user's config and offers Enable / Not Now.
///
/// It is a genuine `NSAlert` (same idiom as the Quit confirmation and the
/// uninstall-failure warning) so the buttons are exactly native. It is presented
/// as a sheet on the key window when there is one, so the rest of Zentty stays
/// usable while the agent itself stays halted (its launch is blocked on the IPC
/// handshake until this resolves); it falls back to a modal run only when no host
/// window is available. `completion` fires exactly once with `.on` (install hooks)
/// or `.off` (skip).
@MainActor
enum AgentIntegrationConsentPanel {
    /// Per-tool in-flight registry. Concurrent prompts for the SAME agent (e.g. a
    /// launch-time prompt and a Settings toggle) coalesce onto one alert instead of
    /// stacking; all queued completions fire once on resolve.
    private static var pending: [AgentBootstrapTool: [(AgentIntegrationState) -> Void]] = [:]

    /// Present the consent alert for `tool`, or attach `completion` to the one
    /// already in flight for it.
    static func present(
        tool: AgentBootstrapTool,
        completion: @escaping (AgentIntegrationState) -> Void
    ) {
        if pending[tool] != nil {
            pending[tool]?.append(completion)
            return
        }
        pending[tool] = [completion]
        show(tool: tool)
    }

    // MARK: - Presentation

    private static func show(tool: AgentBootstrapTool) {
        let name = tool.integrationDisplayName

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Enable \(name) status in Zentty?"
        alert.informativeText = informativeText(name: name)
        // No icon: presented as a sheet, NSAlert renders without one (same as the Quit
        // confirmation, which also sets none). The app icon only shows on the rare
        // modal fallback below.
        if let path = tool.integrationConfigPathDisplay {
            alert.accessoryView = makePathBox(path: path)
        }

        // First button added is the rightmost / default one (prominent blue).
        let enable = alert.addButton(withTitle: "Enable")
        enable.keyEquivalent = "\r"
        let notNow = alert.addButton(withTitle: "Not Now")
        notNow.keyEquivalent = "\u{1b}" // Escape

        NSApp.activate(ignoringOtherApps: true)
        // Attach to the key window, or the main window when the app isn't frontmost
        // (e.g. an agent launching in the background). Only when there is no visible
        // host at all do we fall back to a modal run.
        let host = NSApp.keyWindow ?? NSApp.mainWindow
        if let host, host.isVisible {
            alert.beginSheetModal(for: host) { response in
                resolve(tool: tool, state: state(for: response))
            }
        } else {
            resolve(tool: tool, state: state(for: alert.runModal()))
        }
    }

    private static func state(for response: NSApplication.ModalResponse) -> AgentIntegrationState {
        // Enable is the first button; anything else (Not Now, Escape) declines.
        response == .alertFirstButtonReturn ? .on : .off
    }

    /// Fire all queued completions once and drop the per-tool registration.
    private static func resolve(tool: AgentBootstrapTool, state: AgentIntegrationState) {
        let completions = pending[tool] ?? []
        pending[tool] = nil
        for completion in completions {
            completion(state)
        }
    }

    // MARK: - Content

    /// Two short paragraphs — why the hooks are needed, then what changes and how to
    /// undo it — so the prompt scans quickly. NSAlert renders `\n\n` as a paragraph
    /// break.
    private static func informativeText(name: String) -> String {
        let why = "On its own, Zentty can't tell what \(name) is doing. Status hooks let \(name) report "
            + "that, so Zentty can show its status in the sidebar and notify you when it needs input."

        let change = "Zentty adds these hooks to your \(name) config, tagged so it can remove them again "
            + "when you turn this off or run `zentty uninstall`. You can change this anytime in "
            + "Settings › Agents."

        return why + "\n\n" + change
    }

    /// A fixed-size rounded box showing the config path, used as the alert's
    /// accessory view. NSAlert sizes an accessory view from its frame, so the box
    /// keeps an explicit frame and constrains the label within it.
    private static func makePathBox(path: String) -> NSView {
        let label = NSTextField(labelWithString: path)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 30))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        box.layer?.cornerRadius = 6
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }
}
