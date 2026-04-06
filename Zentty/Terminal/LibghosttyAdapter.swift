import AppKit
import GhosttyKit

extension TerminalSurfaceContext {
    var libghosttyValue: ghostty_surface_context_e {
        switch self {
        case .window:
            GHOSTTY_SURFACE_CONTEXT_WINDOW
        case .tab:
            GHOSTTY_SURFACE_CONTEXT_TAB
        case .split:
            GHOSTTY_SURFACE_CONTEXT_SPLIT
        }
    }
}

@MainActor
protocol LibghosttyRuntimeProviding: AnyObject {
    func makeSurface(
        for hostView: LibghosttyView,
        paneID: PaneID,
        request: TerminalSessionRequest,
        configTemplate: ghostty_surface_config_s?,
        metadataDidChange: @escaping (TerminalMetadata) -> Void,
        eventDidOccur: @escaping (TerminalEvent) -> Void
    ) throws -> any LibghosttySurfaceControlling

    func reloadConfig()
    func applyBackgroundBlur(to window: NSWindow)
}

enum TerminalKeyAction: Equatable {
    case press
    case release
    case repeatPress
}

@MainActor
protocol LibghosttySurfaceControlling: AnyObject {
    var hasScrollback: Bool { get }
    var cellWidth: CGFloat { get }
    var cellHeight: CGFloat { get }
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
    func close()
    func inheritedConfig(for context: ghostty_surface_context_e) -> ghostty_surface_config_s?
}

@MainActor
final class LibghosttyAdapter: TerminalAdapter {
    private let runtime: any LibghosttyRuntimeProviding
    private let paneID: PaneID
    private let diagnostics: TerminalDiagnostics
    private let hostView = LibghosttyView()
    private lazy var scrollHostView = LibghosttySurfaceScrollHostView(
        surfaceView: hostView,
        paneID: paneID,
        diagnostics: diagnostics
    )
    private var surfaceController: (any LibghosttySurfaceControlling)?
    private var lastSurfaceActivity = TerminalSurfaceActivity(isVisible: false, isFocused: false)
    private var hasAppliedSurfaceActivity = false
    private var inheritedConfigTemplate: ghostty_surface_config_s?

    var hasScrollback: Bool { surfaceController?.hasScrollback ?? false }
    var cellWidth: CGFloat { surfaceController?.cellWidth ?? 0 }
    var cellHeight: CGFloat { surfaceController?.cellHeight ?? 0 }
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?

    init(
        paneID: PaneID = PaneID("unknown"),
        runtime: any LibghosttyRuntimeProviding = LibghosttyRuntime.shared,
        diagnostics: TerminalDiagnostics = .shared
    ) {
        self.paneID = paneID
        self.runtime = runtime
        self.diagnostics = diagnostics
        hostView.onLocalEventDidOccur = { [weak self] event in
            self?.eventDidOccur?(event)
        }
    }

    func makeTerminalView() -> NSView {
        scrollHostView
    }

    func startSession(using request: TerminalSessionRequest) throws {
        guard surfaceController == nil else {
            return
        }

        try ZenttyPerformanceSignposts.interval("LibghosttyAdapterStartSession") {
            let surfaceController = try runtime.makeSurface(
                for: hostView,
                paneID: paneID,
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
            hasAppliedSurfaceActivity = false
            setSurfaceActivity(lastSurfaceActivity)
        }
    }

    func close() {
        surfaceController?.close()
        surfaceController = nil
    }

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        ZenttyPerformanceSignposts.interval("LibghosttyAdapterSetSurfaceActivity") {
            let isFirstApplication = !hasAppliedSurfaceActivity
            let previouslyAppliedActivity = isFirstApplication
                ? TerminalSurfaceActivity(isVisible: false, isFocused: false)
                : lastSurfaceActivity
            lastSurfaceActivity = activity

            guard let surfaceController else {
                return
            }

            if !isFirstApplication, previouslyAppliedActivity == activity {
                return
            }

            hasAppliedSurfaceActivity = true

            if isFirstApplication || previouslyAppliedActivity.isFocused != activity.isFocused {
                surfaceController.setFocused(activity.isFocused)
            }

            if !previouslyAppliedActivity.isVisible && activity.isVisible {
                scrollHostView.needsLayout = true
                scrollHostView.layoutSubtreeIfNeeded()
                surfaceController.refresh()
            }
        }
    }
}

extension LibghosttyAdapter: TerminalSessionInheritanceConfiguring {
    func prepareSessionStart(
        from sourceAdapter: (any TerminalAdapter)?,
        context: TerminalSurfaceContext
    ) {
        guard surfaceController == nil else {
            return
        }

        guard
            let sourceAdapter = sourceAdapter as? LibghosttyAdapter,
            let inheritedConfig = sourceAdapter.surfaceController?.inheritedConfig(
                for: context.libghosttyValue
            )
        else {
            inheritedConfigTemplate = nil
            return
        }

        inheritedConfigTemplate = inheritedConfig
    }
}
