import Foundation

enum AppConfigTOML {
    private struct DecodedShortcutBinding {
        var commandID: AppCommandID?
        var shortcut: KeyboardShortcut?
        var hasShortcutValue = false
    }

    private enum Section: Equatable {
        case root
        case sidebar
        case paneLayout
        case openWith
        case customApp(Int)
        case shortcuts
        case shortcutBinding(Int)
        case notifications
        case confirmations
    }

    static func encode(_ config: AppConfig) -> String {
        var lines: [String] = []

        lines.append("[sidebar]")
        lines.append("width = \(format(number: config.sidebar.width))")
        lines.append("visibility = \(encode(string: config.sidebar.visibility.rawValue))")
        lines.append("")
        lines.append("[pane_layout]")
        lines.append("laptop = \(encode(string: config.paneLayout.laptopPreset.rawValue))")
        lines.append("large_display = \(encode(string: config.paneLayout.largeDisplayPreset.rawValue))")
        lines.append("ultrawide = \(encode(string: config.paneLayout.ultrawidePreset.rawValue))")
        lines.append("")
        lines.append("[open_with]")
        lines.append("primary_target_id = \(encode(string: config.openWith.primaryTargetID))")
        lines.append("enabled_target_ids = \(encode(strings: config.openWith.enabledTargetIDs))")

        if !config.openWith.customApps.isEmpty {
            lines.append("")
            for app in config.openWith.customApps {
                lines.append("[[open_with.custom_apps]]")
                lines.append("id = \(encode(string: app.id))")
                lines.append("name = \(encode(string: app.name))")
                lines.append("path = \(encode(string: app.appPath))")
                lines.append("")
            }

            while lines.last?.isEmpty == true {
                lines.removeLast()
            }
        }

        if !config.shortcuts.bindings.isEmpty {
            lines.append("")
            for binding in config.shortcuts.bindings {
                lines.append("[[shortcuts.bindings]]")
                lines.append("command_id = \(encode(string: binding.commandID.rawValue))")
                lines.append("shortcut = \(encode(string: binding.shortcut?.storageString ?? ""))")
                lines.append("")
            }

            while lines.last?.isEmpty == true {
                lines.removeLast()
            }
        }

        lines.append("")
        lines.append("[notifications]")
        lines.append("sound_name = \(encode(string: config.notifications.soundName))")

        lines.append("")
        lines.append("[confirmations]")
        lines.append("confirm_before_closing_pane = \(config.confirmations.confirmBeforeClosingPane)")
        lines.append("confirm_before_closing_window = \(config.confirmations.confirmBeforeClosingWindow)")
        lines.append("confirm_before_quitting = \(config.confirmations.confirmBeforeQuitting)")

        return lines.joined(separator: "\n") + "\n"
    }

    static func decode(_ source: String) -> AppConfig? {
        var config = AppConfig.default
        var section = Section.root
        var customApps: [OpenWithCustomApp] = []
        var decodedShortcutBindings: [DecodedShortcutBinding] = []

        for rawLine in source.components(separatedBy: .newlines) {
            let line = stripComment(from: rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                continue
            }

            if line == "[sidebar]" {
                section = .sidebar
                continue
            }
            if line == "[pane_layout]" {
                section = .paneLayout
                continue
            }
            if line == "[open_with]" {
                section = .openWith
                continue
            }
            if line == "[[open_with.custom_apps]]" {
                customApps.append(OpenWithCustomApp(id: "", name: "", appPath: ""))
                section = .customApp(customApps.count - 1)
                continue
            }
            if line == "[shortcuts]" {
                section = .shortcuts
                continue
            }
            if line == "[[shortcuts.bindings]]" {
                decodedShortcutBindings.append(DecodedShortcutBinding())
                section = .shortcutBinding(decodedShortcutBindings.count - 1)
                continue
            }
            if line == "[notifications]" {
                section = .notifications
                continue
            }
            if line == "[confirmations]" {
                section = .confirmations
                continue
            }
            guard let assignment = parseAssignment(line) else {
                return nil
            }

            switch section {
            case .sidebar:
                guard decodeSidebarAssignment(assignment, into: &config) else {
                    return nil
                }
            case .paneLayout:
                guard decodePaneLayoutAssignment(assignment, into: &config) else {
                    return nil
                }
            case .openWith:
                guard decodeOpenWithAssignment(assignment, into: &config) else {
                    return nil
                }
            case .customApp(let index):
                guard customApps.indices.contains(index) else {
                    return nil
                }
                guard decodeCustomAppAssignment(assignment, into: &customApps[index]) else {
                    return nil
                }
            case .shortcutBinding(let index):
                guard decodedShortcutBindings.indices.contains(index) else {
                    return nil
                }
                guard decodeShortcutAssignment(assignment, into: &decodedShortcutBindings[index]) else {
                    return nil
                }
            case .shortcuts:
                continue
            case .notifications:
                guard decodeNotificationsAssignment(assignment, into: &config) else {
                    return nil
                }
            case .confirmations:
                guard decodeConfirmationsAssignment(assignment, into: &config) else {
                    return nil
                }
            case .root:
                continue
            }
        }

        guard customApps.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty && !$0.appPath.isEmpty }) else {
            return nil
        }
        let shortcuts = decodedShortcutBindings.compactMap { binding -> ShortcutBindingOverride? in
            guard let commandID = binding.commandID, binding.hasShortcutValue else {
                return nil
            }

            return ShortcutBindingOverride(commandID: commandID, shortcut: binding.shortcut)
        }
        guard shortcuts.count == decodedShortcutBindings.count else {
            return nil
        }
        config.openWith.customApps = customApps
        config.shortcuts.bindings = shortcuts
        return config
    }

    private static func decodeSidebarAssignment(
        _ assignment: (key: String, value: String),
        into config: inout AppConfig
    ) -> Bool {
        switch assignment.key {
        case "width":
            guard let value = Double(assignment.value) else {
                return false
            }
            config.sidebar.width = CGFloat(value)
        case "visibility":
            guard let raw = decodeString(assignment.value),
                  let visibility = SidebarVisibilityMode(rawValue: raw) else {
                return false
            }
            config.sidebar.visibility = visibility
        default:
            return true
        }

        return true
    }

    private static func decodePaneLayoutAssignment(
        _ assignment: (key: String, value: String),
        into config: inout AppConfig
    ) -> Bool {
        guard let raw = decodeString(assignment.value),
              let preset = PaneLayoutPreset(rawValue: raw) else {
            return false
        }

        switch assignment.key {
        case "laptop":
            config.paneLayout.laptopPreset = preset
        case "large_display":
            config.paneLayout.largeDisplayPreset = preset
        case "ultrawide":
            config.paneLayout.ultrawidePreset = preset
        default:
            return true
        }

        return true
    }

    private static func decodeOpenWithAssignment(
        _ assignment: (key: String, value: String),
        into config: inout AppConfig
    ) -> Bool {
        switch assignment.key {
        case "primary_target_id":
            guard let value = decodeString(assignment.value), !value.isEmpty else {
                return false
            }
            config.openWith.primaryTargetID = value
        case "enabled_target_ids":
            guard let values = decodeStringArray(assignment.value) else {
                return false
            }
            config.openWith.enabledTargetIDs = values
        default:
            return true
        }

        return true
    }

    private static func decodeCustomAppAssignment(
        _ assignment: (key: String, value: String),
        into app: inout OpenWithCustomApp
    ) -> Bool {
        guard let decoded = decodeString(assignment.value) else {
            return false
        }

        switch assignment.key {
        case "id":
            app.id = decoded
        case "name":
            app.name = decoded
        case "path":
            app.appPath = decoded
        default:
            return true
        }

        return true
    }

    private static func decodeShortcutAssignment(
        _ assignment: (key: String, value: String),
        into binding: inout DecodedShortcutBinding
    ) -> Bool {
        switch assignment.key {
        case "command_id":
            guard let raw = decodeString(assignment.value),
                  let commandID = AppCommandID(rawValue: raw) else {
                return false
            }

            binding.commandID = commandID
        case "shortcut":
            guard let raw = decodeString(assignment.value) else {
                return false
            }

            binding.hasShortcutValue = true
            if raw.isEmpty {
                binding.shortcut = nil
            } else {
                guard let shortcut = KeyboardShortcut(storageString: raw) else {
                    return false
                }
                binding.shortcut = shortcut
            }
        default:
            return true
        }

        return true
    }

    private static func decodeNotificationsAssignment(
        _ assignment: (key: String, value: String),
        into config: inout AppConfig
    ) -> Bool {
        switch assignment.key {
        case "sound_name":
            guard let value = decodeString(assignment.value) else {
                return false
            }
            config.notifications.soundName = value
        default:
            return true
        }

        return true
    }

    private static func decodeConfirmationsAssignment(
        _ assignment: (key: String, value: String),
        into config: inout AppConfig
    ) -> Bool {
        switch assignment.key {
        case "confirm_before_closing_pane":
            guard let value = decodeBool(assignment.value) else { return false }
            config.confirmations.confirmBeforeClosingPane = value
        case "confirm_before_closing_window":
            guard let value = decodeBool(assignment.value) else { return false }
            config.confirmations.confirmBeforeClosingWindow = value
        case "confirm_before_quitting":
            guard let value = decodeBool(assignment.value) else { return false }
            config.confirmations.confirmBeforeQuitting = value
        default:
            return true
        }
        return true
    }

    private static func decodeBool(_ source: String) -> Bool? {
        switch source {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func parseAssignment(_ line: String) -> (key: String, value: String)? {
        guard let separatorIndex = line.firstIndex(of: "=") else {
            return nil
        }

        let key = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else {
            return nil
        }
        return (key, value)
    }

    private static func stripComment(from line: String) -> String {
        var result = ""
        var isInsideString = false
        var previousWasEscape = false

        for character in line {
            if character == "\"" && !previousWasEscape {
                isInsideString.toggle()
            }

            if character == "#" && !isInsideString {
                break
            }

            result.append(character)
            previousWasEscape = character == "\\" && !previousWasEscape
        }

        return result
    }

    private static func decodeString(_ source: String) -> String? {
        guard source.hasPrefix("\""), source.hasSuffix("\"") else {
            return nil
        }

        let raw = String(source.dropFirst().dropLast())
        var decoded = ""
        var isEscaping = false

        for character in raw {
            if isEscaping {
                switch character {
                case "\"":
                    decoded.append("\"")
                case "\\":
                    decoded.append("\\")
                case "n":
                    decoded.append("\n")
                case "t":
                    decoded.append("\t")
                default:
                    decoded.append(character)
                }
                isEscaping = false
                continue
            }

            if character == "\\" {
                isEscaping = true
                continue
            }

            decoded.append(character)
        }

        guard !isEscaping else {
            return nil
        }

        return decoded
    }

    private static func decodeStringArray(_ source: String) -> [String]? {
        guard source.hasPrefix("["), source.hasSuffix("]") else {
            return nil
        }

        let content = String(source.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            return []
        }

        var values: [String] = []
        var token = ""
        var isInsideString = false
        var previousWasEscape = false

        for character in content {
            if character == "\"" && !previousWasEscape {
                isInsideString.toggle()
            }

            if character == "," && !isInsideString {
                guard let value = decodeString(token.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    return nil
                }
                values.append(value)
                token = ""
                previousWasEscape = false
                continue
            }

            token.append(character)
            previousWasEscape = character == "\\" && !previousWasEscape
        }

        guard !isInsideString else {
            return nil
        }

        guard let value = decodeString(token.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        values.append(value)

        return values
    }

    private static func encode(string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private static func encode(strings: [String]) -> String {
        "[" + strings.map(encode(string:)).joined(separator: ", ") + "]"
    }

    private static func format(number: CGFloat) -> String {
        let rounded = number.rounded()
        if abs(number - rounded) < 0.000_1 {
            return String(Int(rounded))
        }

        return String(Double(number))
    }

    // MARK: - Shortcuts-only encode/decode for export/import

    static func encodeShortcuts(_ bindings: [ShortcutBindingOverride]) -> String {
        var lines: [String] = []

        for binding in bindings {
            lines.append("[[shortcuts.bindings]]")
            lines.append("command_id = \(encode(string: binding.commandID.rawValue))")
            lines.append("shortcut = \(encode(string: binding.shortcut?.storageString ?? ""))")
            lines.append("")
        }

        while lines.last?.isEmpty == true {
            lines.removeLast()
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func decodeShortcuts(_ source: String) -> [ShortcutBindingOverride]? {
        var decodedBindings: [DecodedShortcutBinding] = []
        var inBinding = false

        for rawLine in source.components(separatedBy: .newlines) {
            let line = stripComment(from: rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line == "[[shortcuts.bindings]]" {
                decodedBindings.append(DecodedShortcutBinding())
                inBinding = true
                continue
            }

            if line.hasPrefix("[") {
                inBinding = false
                continue
            }

            guard inBinding, let assignment = parseAssignment(line) else { continue }

            let index = decodedBindings.count - 1
            guard index >= 0 else { continue }

            guard decodeShortcutAssignment(assignment, into: &decodedBindings[index]) else {
                return nil
            }
        }

        let bindings = decodedBindings.compactMap { binding -> ShortcutBindingOverride? in
            guard let commandID = binding.commandID, binding.hasShortcutValue else {
                return nil
            }
            return ShortcutBindingOverride(commandID: commandID, shortcut: binding.shortcut)
        }

        guard bindings.count == decodedBindings.count else {
            return nil
        }

        return bindings
    }
}
