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

        let originalMods = Self.modsFromEvent(event)
        let translatedFlags = Self.translatedModifierFlags(
            from: event.modifierFlags,
            ghosttyModifiers: ghostty_surface_key_translation_mods(surface, originalMods)
        )
        let translatedEvent = Self.translatedEvent(from: event, modifierFlags: translatedFlags)

        var keyEvent = ghostty_input_key_s()
        switch action {
        case .press:
            keyEvent.action = GHOSTTY_ACTION_PRESS
        case .release:
            keyEvent.action = GHOSTTY_ACTION_RELEASE
        case .repeatPress:
            keyEvent.action = GHOSTTY_ACTION_REPEAT
        }
        keyEvent.mods = originalMods
        keyEvent.consumed_mods = Self.consumedModsFromFlags(translatedFlags)
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.unshifted_codepoint = Self.unshiftedCodepointFromEvent(event)
        keyEvent.composing = composing

        let effectiveText: String?
        if action == .release {
            effectiveText = nil
        } else if let text, !text.isEmpty {
            effectiveText = text
        } else {
            effectiveText = Self.textForKeyEvent(translatedEvent)
        }

        if let effectiveText, Self.shouldSendText(effectiveText) {
            return effectiveText.withCString { cString in
                keyEvent.text = cString
                return ghostty_surface_key(surface, keyEvent)
            }
        }

        keyEvent.text = nil
        return ghostty_surface_key(surface, keyEvent)
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

    static func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
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

        return ghostty_input_mods_e(rawValue: rawValue)
    }

    static func translatedModifierFlags(
        from eventModifierFlags: NSEvent.ModifierFlags,
        ghosttyModifiers: ghostty_input_mods_e
    ) -> NSEvent.ModifierFlags {
        var translatedFlags = eventModifierFlags.intersection(.deviceIndependentFlagsMask)

        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let shouldInclude: Bool
            switch flag {
            case .shift:
                shouldInclude = (ghosttyModifiers.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control:
                shouldInclude = (ghosttyModifiers.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:
                shouldInclude = (ghosttyModifiers.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command:
                shouldInclude = (ghosttyModifiers.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:
                shouldInclude = translatedFlags.contains(flag)
            }
            if shouldInclude {
                translatedFlags.insert(flag)
            } else {
                translatedFlags.remove(flag)
            }
        }

        return translatedFlags
    }

    static func translatedEvent(from event: NSEvent, modifierFlags: NSEvent.ModifierFlags) -> NSEvent {
        guard modifierFlags != event.modifierFlags.intersection(.deviceIndependentFlagsMask) else {
            return event
        }

        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters(byApplyingModifiers: modifierFlags) ?? event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    static func consumedModsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var rawValue = GHOSTTY_MODS_NONE.rawValue

        if flags.contains(.shift) {
            rawValue |= GHOSTTY_MODS_SHIFT.rawValue
        }
        if flags.contains(.option) {
            rawValue |= GHOSTTY_MODS_ALT.rawValue
        }

        return ghostty_input_mods_e(rawValue: rawValue)
    }

    static func textForKeyEvent(_ event: NSEvent) -> String? {
        guard let characters = event.characters, !characters.isEmpty else {
            return nil
        }

        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if scalar.value < 0x20, flags.contains(.control) {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }

    static func unshiftedCodepointFromEvent(_ event: NSEvent) -> UInt32 {
        guard
            let characters = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? event.characters,
            let scalar = characters.unicodeScalars.first
        else {
            return 0
        }

        return scalar.value
    }

    static func shouldSendText(_ text: String) -> Bool {
        guard let first = text.utf8.first else {
            return false
        }
        return first >= 0x20
    }
}
