import AppKit

@MainActor
protocol LibghosttyRuntimeProviding: AnyObject {
    func makeSurface(
        for hostView: LibghosttyView,
        request: TerminalSessionRequest,
        metadataDidChange: @escaping (TerminalMetadata) -> Void
    ) throws -> any LibghosttySurfaceControlling
}

enum TerminalKeyAction: Equatable {
    case press
    case release
    case repeatPress
}

@MainActor
protocol LibghosttySurfaceControlling: AnyObject {
    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?)
    func setFocused(_ isFocused: Bool)
    func refresh()
    func sendKey(event: NSEvent, action: TerminalKeyAction, text: String?, composing: Bool) -> Bool
    func sendText(_ text: String)
}

@MainActor
final class LibghosttyAdapter: TerminalAdapter {
    private let runtime: any LibghosttyRuntimeProviding
    private let hostView = LibghosttyView()
    private var surfaceController: (any LibghosttySurfaceControlling)?
    private var lastSurfaceActivity = TerminalSurfaceActivity(isVisible: false, isFocused: false)

    var metadataDidChange: ((TerminalMetadata) -> Void)?

    init(runtime: any LibghosttyRuntimeProviding = LibghosttyRuntime.shared) {
        self.runtime = runtime
    }

    func makeTerminalView() -> NSView {
        hostView
    }

    func startSession(using request: TerminalSessionRequest) throws {
        guard surfaceController == nil else {
            return
        }

        let surfaceController = try runtime.makeSurface(
            for: hostView,
            request: request,
            metadataDidChange: { [weak self] metadata in
                self?.metadataDidChange?(metadata)
            }
        )

        hostView.bind(surfaceController: surfaceController)
        self.surfaceController = surfaceController
        setSurfaceActivity(lastSurfaceActivity)
    }

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        let wasVisible = lastSurfaceActivity.isVisible
        lastSurfaceActivity = activity

        guard let surfaceController else {
            return
        }

        surfaceController.setFocused(activity.isVisible && activity.isFocused)

        if !wasVisible && activity.isVisible {
            hostView.needsLayout = true
            hostView.layoutSubtreeIfNeeded()
            surfaceController.refresh()
        }
    }
}
