import AppKit
import GhosttyKit

@MainActor
final class LibghosttySurface: LibghosttySurfaceControlling {
    nonisolated(unsafe) private var surface: ghostty_surface_t?
    private var metadata = TerminalMetadata()
    private let metadataDidChange: (TerminalMetadata) -> Void

    init(
        app: ghostty_app_t,
        hostView: LibghosttyView,
        metadataDidChange: @escaping (TerminalMetadata) -> Void
    ) throws {
        self.metadataDidChange = metadataDidChange

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(hostView).toOpaque()
            )
        )
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(hostView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        guard let surface = ghostty_surface_new(app, &config) else {
            throw LibghosttyRuntime.Error.surfaceCreationFailed
        }

        self.surface = surface
        updateViewport(
            size: hostView.convertToBacking(hostView.bounds).size,
            scale: hostView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1,
            displayID: hostView.currentDisplayID
        )
        setFocused(hostView.window?.firstResponder === hostView)
    }

    deinit {
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?) {
        guard let surface else {
            return
        }

        if let displayID {
            ghostty_surface_set_display_id(surface, displayID)
        }

        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(
            surface,
            UInt32(max(1, size.width.rounded(.down))),
            UInt32(max(1, size.height.rounded(.down)))
        )
    }

    func setFocused(_ isFocused: Bool) {
        guard let surface else {
            return
        }

        ghostty_surface_set_focus(surface, isFocused)
    }

    func refresh() {
        guard let surface else {
            return
        }

        ghostty_surface_refresh(surface)
    }

    func handle(action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            metadata.title = action.action.set_title.title.map { String(cString: $0) }
            publishMetadata()
        case GHOSTTY_ACTION_PWD:
            metadata.currentWorkingDirectory = action.action.pwd.pwd.map { String(cString: $0) }
            publishMetadata()
        default:
            break
        }
    }

    private func publishMetadata() {
        metadataDidChange(metadata)
    }
}
