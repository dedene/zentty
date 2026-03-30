import AppKit
import GhosttyKit

struct LibghosttySurfaceScrollbarUpdate: Equatable, Sendable {
    let total: UInt64
    let offset: UInt64
    let len: UInt64
}

enum LibghosttySurfaceCoalescedValue<Value> {
    case absent
    case present(Value)

    var value: Value? {
        switch self {
        case .absent:
            return nil
        case .present(let value):
            return value
        }
    }
}

enum LibghosttySurfaceActionQueueEntry: Equatable {
    case title
    case pwd
    case progressReport
    case scrollbar
    case mouseShape
    case ordered(LibghosttySurfaceActionPayload)
}

struct LibghosttySurfaceActionDrainBatch {
    var title: LibghosttySurfaceCoalescedValue<String?> = .absent
    var pwd: LibghosttySurfaceCoalescedValue<String?> = .absent
    var progressReport: LibghosttySurfaceCoalescedValue<TerminalProgressReport> = .absent
    var scrollbar: LibghosttySurfaceCoalescedValue<LibghosttySurfaceScrollbarUpdate> = .absent
    var mouseShape: LibghosttySurfaceCoalescedValue<ghostty_action_mouse_shape_e> = .absent
    var sequence: [LibghosttySurfaceActionQueueEntry] = []

    var isEmpty: Bool {
        sequence.isEmpty
    }
}

final class LibghosttySurfaceActionCoalescer {
    private struct State {
        var pendingDrain = false
        var title: LibghosttySurfaceCoalescedValue<String?> = .absent
        var pwd: LibghosttySurfaceCoalescedValue<String?> = .absent
        var progressReport: LibghosttySurfaceCoalescedValue<TerminalProgressReport> = .absent
        var scrollbar: LibghosttySurfaceCoalescedValue<LibghosttySurfaceScrollbarUpdate> = .absent
        var mouseShape: LibghosttySurfaceCoalescedValue<ghostty_action_mouse_shape_e> = .absent
        var sequence: [LibghosttySurfaceActionQueueEntry] = []

        mutating func record(_ entry: LibghosttySurfaceActionQueueEntry) {
            sequence.removeAll { $0 == entry }
            sequence.append(entry)
        }
    }

    private let lock = NSLock()
    private var state = State()

    func enqueue(_ payload: LibghosttySurfaceActionPayload) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        switch payload {
        case .setTitle(let title):
            state.title = .present(title)
            state.record(.title)
        case .pwd(let pwd):
            state.pwd = .present(pwd)
            state.record(.pwd)
        case .progressReport(let report):
            state.progressReport = .present(report)
            state.record(.progressReport)
        case .scrollbar(let total, let offset, let len):
            state.scrollbar = .present(LibghosttySurfaceScrollbarUpdate(total: total, offset: offset, len: len))
            state.record(.scrollbar)
        case .mouseShape(let shape):
            state.mouseShape = .present(shape)
            state.record(.mouseShape)
        case .commandFinished, .desktopNotification, .openURL:
            state.sequence.append(.ordered(payload))
        }

        guard !state.pendingDrain else {
            return false
        }

        state.pendingDrain = true
        return true
    }

    func drain() -> LibghosttySurfaceActionDrainBatch {
        lock.lock()
        defer { lock.unlock() }

        state.pendingDrain = false
        let batch = LibghosttySurfaceActionDrainBatch(
            title: state.title,
            pwd: state.pwd,
            progressReport: state.progressReport,
            scrollbar: state.scrollbar,
            mouseShape: state.mouseShape,
            sequence: state.sequence
        )
        state.title = .absent
        state.pwd = .absent
        state.progressReport = .absent
        state.scrollbar = .absent
        state.mouseShape = .absent
        state.sequence.removeAll(keepingCapacity: true)
        return batch
    }
}

@MainActor
final class LibghosttySurface: LibghosttySurfaceControlling {
    nonisolated(unsafe) var surface: ghostty_surface_t?
    nonisolated(unsafe) private let actionCoalescer = LibghosttySurfaceActionCoalescer()
    nonisolated let paneID: PaneID
    nonisolated let diagnostics: TerminalDiagnostics
    private var metadata = TerminalMetadata()
    private let metadataDidChange: (TerminalMetadata) -> Void
    private let eventDidOccur: (TerminalEvent) -> Void
    private weak var hostView: LibghosttyView?
    private(set) var hasScrollback = false

    var cellWidth: CGFloat {
        guard let surface else { return 0 }
        let size = ghostty_surface_size(surface)
        return CGFloat(size.cell_width_px)
    }

    var cellHeight: CGFloat {
        guard let surface else { return 0 }
        let size = ghostty_surface_size(surface)
        return CGFloat(size.cell_height_px)
    }

    init(
        app: ghostty_app_t,
        paneID: PaneID,
        hostView: LibghosttyView,
        request: TerminalSessionRequest,
        configTemplate: ghostty_surface_config_s?,
        diagnostics: TerminalDiagnostics,
        metadataDidChange: @escaping (TerminalMetadata) -> Void,
        eventDidOccur: @escaping (TerminalEvent) -> Void
    ) throws {
        self.paneID = paneID
        self.diagnostics = diagnostics
        self.metadataDidChange = metadataDidChange
        self.eventDidOccur = eventDidOccur

        var config = configTemplate ?? ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(hostView).toOpaque()
            )
        )
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(hostView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        config.context = switch request.surfaceContext {
        case .window:
            GHOSTTY_SURFACE_CONTEXT_WINDOW
        case .tab:
            GHOSTTY_SURFACE_CONTEXT_TAB
        case .split:
            GHOSTTY_SURFACE_CONTEXT_SPLIT
        }
        let surfaceEnvironment = makeSurfaceEnvironment(from: request.environmentVariables)
        defer {
            surfaceEnvironment.retainedPointers.forEach { free($0) }
        }

        var createdSurface: ghostty_surface_t?
        let createSurface = {
            if surfaceEnvironment.envVars.isEmpty {
                createdSurface = ghostty_surface_new(app, &config)
                return
            }

            var buffer = surfaceEnvironment.envVars
            let envVarCount = buffer.count
            buffer.withUnsafeMutableBufferPointer { envBuffer in
                config.env_vars = envBuffer.baseAddress
                config.env_var_count = envVarCount
                createdSurface = ghostty_surface_new(app, &config)
            }
        }

        if let workingDirectory = request.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workingDirectory.isEmpty {
            workingDirectory.withCString { cString in
                config.working_directory = cString
                createSurface()
            }
        } else {
            createSurface()
        }

        guard let surface = createdSurface else {
            throw LibghosttyRuntime.Error.surfaceCreationFailed
        }

        self.surface = surface
        self.hostView = hostView
        metadata.currentWorkingDirectory = request.workingDirectory
        updateViewport(
            size: hostView.convertToBacking(hostView.bounds).size,
            scale: hostView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1,
            displayID: hostView.currentDisplayID
        )
        setFocused(hostView.window?.firstResponder === hostView)
        publishMetadata()
    }

    func close() {
        guard let surface else { return }
        ghostty_surface_request_close(surface)
        ghostty_surface_free(surface)
        self.surface = nil
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

    func performBindingAction(_ action: String) -> Bool {
        guard let surface else {
            return false
        }

        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(action.lengthOfBytes(using: .utf8)))
        }
    }

    func hasSelection() -> Bool {
        guard let surface else {
            return false
        }

        return ghostty_surface_has_selection(surface)
    }

    func sendMouseScroll(x: Double, y: Double, precision: Bool, momentum: NSEvent.Phase) {
        guard let surface else {
            return
        }

        ghostty_surface_mouse_scroll(
            surface,
            x,
            y,
            Self.scrollMods(precision: precision, momentum: momentum)
        )
    }

    func sendMousePosition(_ position: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard let surface else {
            return
        }

        ghostty_surface_mouse_pos(surface, position.x, position.y, Self.modsFromFlags(modifiers))
    }

    func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        modifiers: NSEvent.ModifierFlags
    ) {
        guard let surface else {
            return
        }

        _ = ghostty_surface_mouse_button(surface, state, button, Self.modsFromFlags(modifiers))
    }

    func inheritedConfig(for context: ghostty_surface_context_e) -> ghostty_surface_config_s? {
        guard let surface else {
            return nil
        }

        return ghostty_surface_inherited_config(surface, context)
    }

    func handle(payload: LibghosttySurfaceActionPayload) {
        apply(payload: payload)
    }

    nonisolated func enqueue(payload: LibghosttySurfaceActionPayload) -> Bool {
        actionCoalescer.enqueue(payload)
    }

    @MainActor
    func drainCoalescedActions(queueDelayNanoseconds: UInt64 = 0) {
        diagnostics.recordActionDrain(paneID: paneID, queueDelayNanoseconds: queueDelayNanoseconds)
        let batch = actionCoalescer.drain()
        guard batch.isEmpty == false else {
            return
        }

        var metadataChanged = false

        func flushMetadataIfNeeded() {
            guard metadataChanged else {
                return
            }

            publishMetadata()
            metadataChanged = false
        }

        for entry in batch.sequence {
            switch entry {
            case .title:
                guard let title = batch.title.value else {
                    continue
                }
                if metadata.title != title {
                    metadata.title = title
                    metadataChanged = true
                }
            case .pwd:
                guard let pwd = batch.pwd.value else {
                    continue
                }
                if metadata.currentWorkingDirectory != pwd {
                    metadata.currentWorkingDirectory = pwd
                    metadataChanged = true
                }
            case .progressReport:
                flushMetadataIfNeeded()
                guard let progressReport = batch.progressReport.value else {
                    continue
                }
                eventDidOccur(.progressReport(progressReport))
            case .scrollbar:
                flushMetadataIfNeeded()
                guard let scrollbar = batch.scrollbar.value else {
                    continue
                }
                hasScrollback = scrollbar.total > scrollbar.len
                hostView?.applyScrollbarUpdate(scrollbar)
            case .mouseShape:
                flushMetadataIfNeeded()
                guard let mouseShape = batch.mouseShape.value else {
                    continue
                }
                hostView?.setMouseCursorShape(mouseShape)
            case .ordered(let payload):
                flushMetadataIfNeeded()
                apply(payload: payload)
            }
        }

        flushMetadataIfNeeded()
    }

    private func apply(payload: LibghosttySurfaceActionPayload) {
        switch payload {
        case .setTitle(let title):
            metadata.title = title
            publishMetadata()
        case .pwd(let path):
            metadata.currentWorkingDirectory = path
            publishMetadata()
        case .progressReport(let report):
            eventDidOccur(.progressReport(report))
        case .commandFinished(let exitCode, let durationNanoseconds):
            eventDidOccur(.commandFinished(exitCode: exitCode, durationNanoseconds: durationNanoseconds))
        case .desktopNotification(let notification):
            eventDidOccur(.desktopNotification(notification))
        case .scrollbar(let total, _, let len):
            hasScrollback = total > len
        case .openURL(let urlString):
            if let url = URL(string: urlString), url.scheme != nil {
                NSWorkspace.shared.open(url)
            } else {
                let expanded = NSString(string: urlString).standardizingPath
                NSWorkspace.shared.open(URL(filePath: expanded))
            }
        case .mouseShape(let shape):
            hostView?.setMouseCursorShape(shape)
        }
    }

    private func publishMetadata() {
        metadataDidChange(metadata)
    }

    nonisolated func recordActionCallback(payload: LibghosttySurfaceActionPayload) {
        diagnostics.recordActionCallback(paneID: paneID, payload: payload)
    }

    private func makeSurfaceEnvironment(from requestEnvironment: [String: String]) -> (
        envVars: [ghostty_env_var_s],
        retainedPointers: [UnsafeMutablePointer<CChar>]
    ) {
        var environment = requestEnvironment
        if let helperPath = AgentStatusHelper.binaryPath(), !helperPath.isEmpty {
            environment["ZENTTY_AGENT_BIN"] = helperPath
        }

        var retainedPointers: [UnsafeMutablePointer<CChar>] = []
        let envVars = environment
            .sorted(by: { $0.key < $1.key })
            .map { key, value in
                let retainedKey = strdup(key)!
                let retainedValue = strdup(value)!
                retainedPointers.append(retainedKey)
                retainedPointers.append(retainedValue)
                return ghostty_env_var_s(
                    key: UnsafePointer(retainedKey),
                    value: UnsafePointer(retainedValue)
                )
            }

        return (envVars, retainedPointers)
    }

    static func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        modsFromFlags(event.modifierFlags)
    }

    static func modsFromFlags(_ modifierFlags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var rawValue = GHOSTTY_MODS_NONE.rawValue
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.shift) {
            rawValue |= GHOSTTY_MODS_SHIFT.rawValue
        }
        if flags.contains(.control) {
            rawValue |= GHOSTTY_MODS_CTRL.rawValue
        }
        if flags.contains(.option) {
            rawValue |= GHOSTTY_MODS_ALT.rawValue
        }
        if flags.contains(.command) {
            rawValue |= GHOSTTY_MODS_SUPER.rawValue
        }

        return ghostty_input_mods_e(rawValue: rawValue)
    }

    static func scrollMods(precision: Bool, momentum: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        var rawValue: Int32 = precision ? 0b0000_0001 : 0
        rawValue |= scrollMomentumValue(from: momentum) << 1
        return rawValue
    }

    static func scrollMomentumValue(from phase: NSEvent.Phase) -> Int32 {
        switch phase {
        case .began:
            1
        case .stationary:
            2
        case .changed:
            3
        case .ended:
            4
        case .cancelled:
            5
        case .mayBegin:
            6
        default:
            0
        }
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
