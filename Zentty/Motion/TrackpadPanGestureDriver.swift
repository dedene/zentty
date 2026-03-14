import AppKit

@MainActor
final class TrackpadPanGestureDriver: NSObject {
    var onBegan: (() -> Void)?
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: ((CGFloat) -> Void)?

    private weak var hostView: NSView?
    private lazy var recognizer: NSPanGestureRecognizer = {
        NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    }()

    func install(on view: NSView) {
        guard hostView !== view else {
            return
        }

        if let hostView {
            hostView.removeGestureRecognizer(recognizer)
        }

        hostView = view
        view.addGestureRecognizer(recognizer)
    }

    @objc
    private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        guard let hostView else {
            return
        }

        let translationX = recognizer.translation(in: hostView).x

        switch recognizer.state {
        case .began:
            onBegan?()
            onChanged?(translationX)
        case .changed:
            onChanged?(translationX)
        case .ended, .cancelled:
            onEnded?(translationX)
        default:
            break
        }
    }
}
