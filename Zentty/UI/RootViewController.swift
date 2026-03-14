import AppKit

final class RootViewController: NSViewController {
    private let appCanvasView = AppCanvasView()

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
    }
}
