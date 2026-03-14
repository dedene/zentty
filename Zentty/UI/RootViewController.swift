import AppKit

final class RootViewController: NSViewController {
    private let paneStripStore = PaneStripStore()
    private let appCanvasView = AppCanvasView()
    private var hasInstalledKeyMonitor = false

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(
            calibratedWhite: 0.94,
            alpha: 1
        ).cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        appCanvasView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(appCanvasView)

        NSLayoutConstraint.activate([
            appCanvasView.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            appCanvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            appCanvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            appCanvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        paneStripStore.onChange = { [weak self] state in
            self?.appCanvasView.render(state)
        }
        appCanvasView.render(paneStripStore.state)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
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
}
