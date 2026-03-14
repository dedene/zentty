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
        request: TerminalSessionRequest,
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

        var createdSurface: ghostty_surface_t?
        if let workingDirectory = request.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workingDirectory.isEmpty {
            workingDirectory.withCString { cString in
                config.working_directory = cString
                createdSurface = ghostty_surface_new(app, &config)
            }
        } else {
            createdSurface = ghostty_surface_new(app, &config)
        }

        guard let surface = createdSurface else {
            throw LibghosttyRuntime.Error.surfaceCreationFailed
        }

        self.surface = surface
        metadata.currentWorkingDirectory = request.workingDirectory
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

    func sendKey(event: NSEvent, action: TerminalKeyAction, text: String?, composing: Bool) -> Bool {
        guard let surface else {
            return false
        }

        var keyEvent = ghostty_input_key_s()
        switch action {
        case .press:
            keyEvent.action = GHOSTTY_ACTION_PRESS
        case .release:
            keyEvent.action = GHOSTTY_ACTION_RELEASE
        case .repeatPress:
            keyEvent.action = GHOSTTY_ACTION_REPEAT
        }
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = composing

        if let text {
            return text.withCString { cString in
                keyEvent.text = cString
                return ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
            return ghostty_surface_key(surface, keyEvent)
        }
    }

    func sendText(_ text: String) {
        guard let surface else {
            return
        }

        text.utf8CString.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            ghostty_surface_text(surface, baseAddress, UInt(buffer.count - 1))
        }
    }

    func handle(payload: LibghosttySurfaceActionPayload) {
        switch payload {
        case .setTitle(let title):
            metadata.title = title
        case .pwd(let path):
            metadata.currentWorkingDirectory = path
        }

        publishMetadata()
    }

    private func publishMetadata() {
        metadataDidChange(metadata)
    }

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        var rawValue = GHOSTTY_MODS_NONE.rawValue

        if event.modifierFlags.contains(.shift) {
            rawValue |= GHOSTTY_MODS_SHIFT.rawValue
        }
        if event.modifierFlags.contains(.control) {
            rawValue |= GHOSTTY_MODS_CTRL.rawValue
        }
        if event.modifierFlags.contains(.option) {
            rawValue |= GHOSTTY_MODS_ALT.rawValue
        }
        if event.modifierFlags.contains(.command) {
            rawValue |= GHOSTTY_MODS_SUPER.rawValue
        }

        return ghostty_input_mods_e(rawValue: rawValue) ?? GHOSTTY_MODS_NONE
    }
}
