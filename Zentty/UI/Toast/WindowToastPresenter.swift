import AppKit

/// Owns the single `PathCopiedToastView` shared across the window and enforces
/// the toast identity invariants: an active progress toast suppresses transient
/// toasts, and every new toast replaces the prior one. Callers reach the toast
/// only through this presenter so the `pathCopiedToastView` slot has one owner.
@MainActor
final class WindowToastPresenter {
    private let hostViewProvider: () -> NSView?
    private let themeProvider: () -> ZenttyTheme
    private var toastView: PathCopiedToastView?

    init(
        hostViewProvider: @escaping () -> NSView?,
        themeProvider: @escaping () -> ZenttyTheme
    ) {
        self.hostViewProvider = hostViewProvider
        self.themeProvider = themeProvider
    }

    var isProgressActive: Bool {
        toastView?.isProgressActive == true
    }

    func show(message: String, duration: TimeInterval? = nil) {
        guard let (toast, host) = replaceToast() else {
            return
        }
        let theme = themeProvider()
        if duration != nil {
            let handle = toast.beginProgress(message: message, in: host, theme: theme)
            handle.fail(message: message)
        } else {
            toast.show(message: message, in: host, theme: theme)
        }
    }

    /// For a failure that is the only notice a user gets. `show` holds every
    /// failure for the same short time, whatever `duration` says.
    func showFailure(message: String, staysFor displayDuration: TimeInterval) {
        guard let (toast, host) = replaceToast() else {
            return
        }
        let handle = toast.beginProgress(message: message, in: host, theme: themeProvider())
        handle.fail(message: message, staysFor: displayDuration)
    }

    private func replaceToast() -> (toast: PathCopiedToastView, host: NSView)? {
        guard toastView?.isProgressActive != true else {
            return nil
        }
        // Tear down the prior toast even when the host is gone (mid-teardown),
        // matching the pre-extraction behavior of always removing it first.
        toastView?.removeFromSuperview()
        guard let host = hostViewProvider() else {
            toastView = nil
            return nil
        }

        let toast = PathCopiedToastView()
        toastView = toast
        return (toast, host)
    }

    func beginProgress(message: String) -> PathCopiedToastView.ProgressHandle {
        // `hostViewProvider` is optional because the VC captures itself weakly;
        // in practice the canvas is always present when a progress toast begins.
        let host = hostViewProvider() ?? NSView()
        toastView?.removeFromSuperview()
        let toast = PathCopiedToastView()
        toastView = toast
        return toast.beginProgress(
            message: message,
            in: host,
            theme: themeProvider()
        )
    }

    func temporarilyShowProgressMessage(_ message: String, duration: TimeInterval) {
        toastView?.temporarilyShowProgressMessage(message, duration: duration)
    }

    func dismiss() {
        toastView?.removeFromSuperview()
        toastView = nil
    }

#if DEBUG
    var currentToastViewForTesting: PathCopiedToastView? {
        toastView
    }
#endif
}
