import AppKit

final class RootViewController: NSViewController {
    private let paneStripStore = PaneStripStore()
    private let sidebarView = SidebarView()
    private let appCanvasView = AppCanvasView()
    private var hasInstalledKeyMonitor = false

    private enum Layout {
        static let outerInset: CGFloat = 6
        static let sidebarWidth: CGFloat = 84
        static let canvasGap: CGFloat = 8
    }

    override func loadView() {
        view = WindowContentView()
        view.wantsLayer = true
        updateBackgroundColor()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        appCanvasView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebarView)
        view.addSubview(appCanvasView)

        NSLayoutConstraint.activate([
            sidebarView.topAnchor.constraint(equalTo: view.topAnchor, constant: Layout.outerInset),
            sidebarView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Layout.outerInset),
            sidebarView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Layout.outerInset),
            sidebarView.widthAnchor.constraint(equalToConstant: Layout.sidebarWidth),

            appCanvasView.topAnchor.constraint(equalTo: view.topAnchor, constant: Layout.outerInset),
            appCanvasView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: Layout.canvasGap),
            appCanvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Layout.outerInset),
            appCanvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Layout.outerInset),
        ])

        paneStripStore.onChange = { [weak self] state in
            self?.appCanvasView.render(state)
        }
        appCanvasView.onFocusSettled = { [weak self] paneID in
            self?.paneStripStore.focusPane(id: paneID)
        }
        appCanvasView.render(paneStripStore.state)
    }

    func activateWindowBindingsIfNeeded() {
        installKeyboardMonitorIfNeeded()
    }

    private func installKeyboardMonitorIfNeeded() {
        guard !hasInstalledKeyMonitor else {
            return
        }

        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }

            guard self.view.window?.isKeyWindow == true else {
                return event
            }

            guard let shortcut = KeyboardShortcut(event: event),
                  let command = KeyboardShortcutResolver.resolve(shortcut) else {
                return event
            }

            self.paneStripStore.send(command)
            return nil
        }
        hasInstalledKeyMonitor = true
    }

    private func updateBackgroundColor() {
        let backgroundColor = NSColor(name: nil) { appearance in
            let isDarkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDarkMode
                ? NSColor(calibratedWhite: 0.13, alpha: 1)
                : NSColor(calibratedRed: 196 / 255, green: 216 / 255, blue: 232 / 255, alpha: 1)
        }
        view.layer?.backgroundColor = backgroundColor.cgColor
    }
}

private final class WindowContentView: NSView {
    override var fittingSize: NSSize {
        NSSize(width: 1, height: 1)
    }
}
