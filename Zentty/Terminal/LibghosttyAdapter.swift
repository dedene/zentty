import AppKit
import GhosttyKit

@MainActor
protocol LibghosttyRuntimeProviding: AnyObject {
    func makeSurface(
        for hostView: LibghosttyView,
        request: TerminalSessionRequest,
        configTemplate: ghostty_surface_config_s?,
        metadataDidChange: @escaping (TerminalMetadata) -> Void,
        eventDidOccur: @escaping (TerminalEvent) -> Void
    ) throws -> any LibghosttySurfaceControlling
}

enum TerminalKeyAction: Equatable {
    case press
    case release
    case repeatPress
}

@MainActor
protocol LibghosttySurfaceControlling: AnyObject {
    var hasScrollback: Bool { get }
    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?)
    func setFocused(_ isFocused: Bool)
    func refresh()
    func sendKey(event: NSEvent, action: TerminalKeyAction, text: String?, composing: Bool) -> Bool
    func sendMouseScroll(x: Double, y: Double, precision: Bool, momentum: NSEvent.Phase)
    func sendMousePosition(_ position: CGPoint, modifiers: NSEvent.ModifierFlags)
    func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        modifiers: NSEvent.ModifierFlags
    )
    func sendText(_ text: String)
    func performBindingAction(_ action: String) -> Bool
    func hasSelection() -> Bool
    func inheritedConfig(for context: ghostty_surface_context_e) -> ghostty_surface_config_s?
}

@MainActor
final class LibghosttyAdapter: TerminalAdapter {
    private let runtime: any LibghosttyRuntimeProviding
    private let hostView = LibghosttyView()
    private var surfaceController: (any LibghosttySurfaceControlling)?
    private var lastSurfaceActivity = TerminalSurfaceActivity(isVisible: false, isFocused: false)
    private var inheritedConfigTemplate: ghostty_surface_config_s?

    var hasScrollback: Bool { surfaceController?.hasScrollback ?? false }
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?

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
            configTemplate: inheritedConfigTemplate,
            metadataDidChange: { [weak self] metadata in
                self?.metadataDidChange?(metadata)
            },
            eventDidOccur: { [weak self] event in
                self?.eventDidOccur?(event)
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

extension LibghosttyAdapter: TerminalSessionInheritanceConfiguring {
    func prepareSessionStart(from sourceAdapter: (any TerminalAdapter)?) {
        guard surfaceController == nil else {
            return
        }

        guard
            let sourceAdapter = sourceAdapter as? LibghosttyAdapter,
            let inheritedConfig = sourceAdapter.surfaceController?.inheritedConfig(
                for: GHOSTTY_SURFACE_CONTEXT_SPLIT
            )
        else {
            inheritedConfigTemplate = nil
            return
        }

        inheritedConfigTemplate = inheritedConfig
    }
}
