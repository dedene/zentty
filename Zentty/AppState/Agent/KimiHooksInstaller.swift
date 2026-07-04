import Foundation
import os

private let kimiInstallerLogger = Logger(subsystem: "be.zenjoy.zentty", category: "KimiHookInstall")

enum KimiVariant: String {
    case modern
    case legacy

    init?(rawPin: String?) {
        guard let rawPin else {
            return nil
        }
        self.init(rawValue: rawPin)
    }
}

enum KimiVariantProbe {
    private static let cache = KimiVariantProbeCache()

    static func strippingANSISequences(from text: String) -> String {
        var output = String()
        var index = text.startIndex

        while index < text.endIndex {
            let scalar = text[index].unicodeScalars.first
            guard scalar?.value == 0x1B else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }

            index = text.index(after: index)
            guard index < text.endIndex else {
                break
            }

            if text[index] == "[" {
                index = text.index(after: index)
                while index < text.endIndex {
                    let value = text[index].unicodeScalars.first?.value ?? 0
                    index = text.index(after: index)
                    if value >= 0x40 && value <= 0x7E {
                        break
                    }
                }
            } else {
                let value = text[index].unicodeScalars.first?.value ?? 0
                if value >= 0x20 && value <= 0x2F {
                    index = text.index(after: index)
                    if index < text.endIndex {
                        index = text.index(after: index)
                    }
                } else {
                    index = text.index(after: index)
                }
            }
        }

        return output
    }

    static func isModernHelpOutput(_ helpText: String) -> Bool {
        !strippingANSISequences(from: helpText).contains("--config-file")
    }

    static func probeVariant(executablePath: String, environment: [String: String]) -> KimiVariant? {
        if let cached = cache.value(for: executablePath) {
            return cached
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--help"]
        var probeEnvironment = environment
        probeEnvironment["NO_COLOR"] = "1"
        probeEnvironment["TERM"] = "dumb"
        process.environment = probeEnvironment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let outputBuffer = KimiProbeOutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            outputBuffer.append(handle.availableData)
        }
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
        }

        do {
            let semaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                semaphore.signal()
            }
            try process.run()
            let timedOut = semaphore.wait(timeout: .now() + .seconds(10)) == .timedOut
            if timedOut {
                process.terminate()
                process.waitUntilExit()
                kimiInstallerLogger.warning("Kimi variant probe timed out for \(executablePath, privacy: .public)")
                return nil
            }

            guard process.terminationStatus == 0 else {
                kimiInstallerLogger.warning(
                    "Kimi variant probe exited with status \(process.terminationStatus, privacy: .public) for \(executablePath, privacy: .public)"
                )
                return nil
            }

            pipe.fileHandleForReading.readabilityHandler = nil
            outputBuffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
            let data = outputBuffer.contents()

            guard let output = String(data: data, encoding: .utf8) else {
                kimiInstallerLogger.warning("Kimi variant probe returned undecodable output for \(executablePath, privacy: .public)")
                return nil
            }

            let variant: KimiVariant = isModernHelpOutput(output) ? .modern : .legacy
            cache.store(variant, for: executablePath)
            return variant
        } catch {
            kimiInstallerLogger.warning(
                "Kimi variant probe failed for \(executablePath, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    static func selectBinary(
        pinned: KimiVariant,
        candidates: [String],
        probe: (String) -> KimiVariant?
    ) -> String? {
        candidates.first { probe($0) == pinned }
    }

    static func resolvePreferred(
        pin: KimiVariant?,
        candidates: [String],
        probe: (String) -> KimiVariant?
    ) -> String? {
        guard !candidates.isEmpty else {
            return nil
        }
        if let pin {
            return selectBinary(pinned: pin, candidates: candidates, probe: probe)
        }
        guard candidates.count >= 2 else {
            return nil
        }
        return selectBinary(pinned: .modern, candidates: candidates, probe: probe)
    }

    private final class KimiVariantProbeCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values = [String: KimiVariant]()

        func value(for key: String) -> KimiVariant? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }

        func store(_ value: KimiVariant, for key: String) {
            lock.lock()
            values[key] = value
            lock.unlock()
        }
    }

    private final class KimiProbeOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func contents() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }
}

enum KimiHooksInstaller {
    static let beginMarker = "### BEGIN ZENTTY KIMI HOOKS"
    static let endMarker = "### END ZENTTY KIMI HOOKS"
    private static let styleMarkerPrefix = "# zentty-managed-style = "
    private static let emptyHooksPlaceholder = "hooks = []"

    static func defaultUserConfigURL(
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    ) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".kimi", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    static func modernUserConfigURL(
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    ) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".kimi-code", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    static func install(
        at configURL: URL,
        cliPath: String,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let existing = fileManager.fileExists(atPath: configURL.path)
            ? try String(contentsOf: configURL, encoding: .utf8)
            : ""

        let updated = try mergedConfigText(existingConfig: existing, cliPath: cliPath)

        if existing == updated {
            return
        }

        try updated.write(to: configURL, atomically: true, encoding: .utf8)
    }

    static func uninstall(
        at configURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: configURL.path) else {
            return
        }

        let existing = try String(contentsOf: configURL, encoding: .utf8)
        let updated = try replacingManagedBlock(in: existing, with: uninstallReplacement(for: existing))

        if updated.isEmpty {
            try fileManager.removeItem(at: configURL)
            return
        }

        if updated == existing {
            return
        }

        try updated.write(to: configURL, atomically: true, encoding: .utf8)
    }

    static func installIfPossible(
        environment: [String: String],
        fileManager: FileManager = .default
    ) {
        guard let cliPath = environment["ZENTTY_CLI_BIN"]?.nonBlank else {
            kimiInstallerLogger.debug("Skipping kimi hook install: ZENTTY_CLI_BIN is not set")
            return
        }
        guard let home = environment["HOME"]?.nonBlank else {
            kimiInstallerLogger.debug("Skipping kimi hook install: HOME is not set")
            return
        }

        let configURLs = [
            defaultUserConfigURL(home: home),
            modernUserConfigURL(home: home)
        ]

        for configURL in configURLs {
            do {
                try install(at: configURL, cliPath: cliPath, fileManager: fileManager)
                kimiInstallerLogger.info("Installed Zentty Kimi hooks in \(configURL.path, privacy: .public)")
            } catch {
                kimiInstallerLogger.error(
                    "Failed to install Kimi hooks at \(configURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    static func mergedConfigText(existingConfig: String, cliPath: String) throws -> String {
        let style = installationStyle(for: existingConfig)
        return try installedConfig(from: existingConfig, cliPath: cliPath, style: style)
    }

    private static func replacingManagedBlock(
        in source: String,
        with replacement: String?
    ) throws -> String {
        let range = try removableManagedBlockRange(in: source)
        let replacementText = replacement ?? ""

        if let range {
            let updated = source.replacingCharacters(in: range, with: replacementText)
            return updated.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let replacement else {
            return source
        }

        if source.isEmpty {
            return replacement
        }

        let separator = source.hasSuffix("\n") ? "\n" : "\n\n"
        return source + separator + replacement
    }

    private static func installedConfig(
        from source: String,
        cliPath: String,
        style: HookConfigStyle
    ) throws -> String {
        if style == .inlineArray {
            if let blockRange = try managedBlockRange(in: source) {
                let blockText = String(source[blockRange])
                let replacement: String
                if blockText.contains("hooks = [") {
                    replacement = managedInlineArrayAssignment(cliPath: cliPath)
                } else {
                    replacement = managedInlineHookEntriesBlock(
                        cliPath: cliPath,
                        trailingComma: inlineHooksArrayHasElements(
                            afterManagedBlockRange: blockRange,
                            in: source
                        )
                    )
                }
                return source.replacingCharacters(in: blockRange, with: replacement)
            }

            if let replacedPlaceholder = replacingEmptyHooksPlaceholder(
                in: source,
                with: managedInlineArrayAssignment(cliPath: cliPath)
            ) {
                return replacedPlaceholder
            }

            if let insertedInlineHooks = insertingManagedInlineHooks(in: source, cliPath: cliPath) {
                return insertedInlineHooks
            }
        }

        let replacement = managedHookBlock(cliPath: cliPath, style: style)
        return try replacingManagedBlock(in: source, with: replacement)
    }

    private static func managedBlockRange(in source: String) throws -> Range<String.Index>? {
        let beginRange = source.range(
            of: #"(?m)^### BEGIN ZENTTY KIMI HOOKS[ \t]*$"#,
            options: .regularExpression
        )
        let endRange = source.range(
            of: #"(?m)^### END ZENTTY KIMI HOOKS[ \t]*$"#,
            options: .regularExpression
        )

        switch (beginRange, endRange) {
        case (nil, nil):
            return nil
        case (.some, nil), (nil, .some):
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [NSLocalizedDescriptionKey:
                    "Kimi config contains an incomplete Zentty-managed block; remove it or run `zentty uninstall kimi-hooks` after fixing the file"]
            )
        case let (beginRange?, endRange?):
            guard beginRange.lowerBound <= endRange.lowerBound else {
                throw CocoaError(
                    .fileReadCorruptFile,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Kimi config contains an invalid Zentty-managed block ordering; fix \(defaultUserConfigURL().path) and retry"]
                )
            }

            var upperBound = endRange.upperBound
            if upperBound < source.endIndex, source[upperBound] == "\n" {
                upperBound = source.index(after: upperBound)
            }
            while upperBound < source.endIndex {
                let next = source[upperBound]
                guard next == "\n" else { break }
                upperBound = source.index(after: upperBound)
            }
            return beginRange.lowerBound..<upperBound
        }
    }

    private static func managedHookBlock(cliPath: String, style: HookConfigStyle) -> String {
        let command = tomlEscapeBasicString(
            "\"\(shellEscapeDoubleQuoted(cliPath))\" ipc agent-event --adapter=kimi"
        )
        switch style {
        case .arrayTables:
            return """
            \(beginMarker)
            \(styleMarkerPrefix)\(style.rawValue)
            [[hooks]]
            event = "SessionStart"
            command = "\(command)"

            [[hooks]]
            event = "SessionEnd"
            command = "\(command)"

            [[hooks]]
            event = "UserPromptSubmit"
            command = "\(command)"

            [[hooks]]
            event = "Stop"
            command = "\(command)"

            [[hooks]]
            event = "Notification"
            command = "\(command)"

            [[hooks]]
            event = "PreToolUse"
            command = "\(command)"

            [[hooks]]
            event = "PostToolUse"
            command = "\(command)"
            \(endMarker)
            """
        case .inlineArray:
            return managedInlineArrayAssignment(cliPath: cliPath)
        }
    }

    private static func managedInlineArrayAssignment(cliPath: String) -> String {
        """
        \(beginMarker)
        \(styleMarkerPrefix)\(HookConfigStyle.inlineArray.rawValue)
        hooks = [
        \(inlineHookEntries(cliPath: cliPath, trailingComma: false))
        ]
        \(endMarker)
        """
    }

    private static func managedInlineHookEntriesBlock(
        cliPath: String,
        trailingComma: Bool
    ) -> String {
        """
        \(beginMarker)
        \(styleMarkerPrefix)\(HookConfigStyle.inlineArray.rawValue)
        \(inlineHookEntries(cliPath: cliPath, trailingComma: trailingComma))
        \(endMarker)
        """
    }

    private static func inlineHookEntries(
        cliPath: String,
        trailingComma: Bool
    ) -> String {
        let command = tomlEscapeBasicString(
            "\"\(shellEscapeDoubleQuoted(cliPath))\" ipc agent-event --adapter=kimi"
        )
        let trailingCommaSuffix = trailingComma ? "," : ""
        return """
          { event = "SessionStart", command = "\(command)" },
          { event = "SessionEnd", command = "\(command)" },
          { event = "UserPromptSubmit", command = "\(command)" },
          { event = "Stop", command = "\(command)" },
          { event = "Notification", command = "\(command)" },
          { event = "PreToolUse", command = "\(command)" },
          { event = "PostToolUse", command = "\(command)" }\(trailingCommaSuffix)
        """
    }

    private static func installationStyle(for source: String) -> HookConfigStyle {
        if let existingStyle = existingManagedBlockStyle(in: source) {
            return existingStyle
        }
        if inlineHooksArrayContext(in: source) != nil {
            return .inlineArray
        }
        return .arrayTables
    }

    private static func existingManagedBlockStyle(in source: String) -> HookConfigStyle? {
        guard let blockRange = try? managedBlockRange(in: source) else {
            return nil
        }
        let blockText = source[blockRange]
        for style in HookConfigStyle.allCases {
            if blockText.contains("\(styleMarkerPrefix)\(style.rawValue)") {
                return style
            }
        }
        return nil
    }

    private static func insertingManagedInlineHooks(
        in source: String,
        cliPath: String
    ) -> String? {
        guard let context = inlineHooksArrayContext(in: source) else {
            return nil
        }

        let insertion = "\n" + managedInlineHookEntriesBlock(
            cliPath: cliPath,
            trailingComma: context.hasElements
        ) + "\n"
        var updated = source
        updated.insert(contentsOf: insertion, at: source.index(after: context.openBracketIndex))
        return updated
    }

    private static func inlineHooksArrayHasElements(
        afterManagedBlockRange blockRange: Range<String.Index>,
        in source: String
    ) -> Bool {
        guard let context = inlineHooksArrayContext(in: source) else {
            return false
        }
        let trailingBodyRange = blockRange.upperBound..<context.bodyRange.upperBound
        return inlineHooksBodyHasElements(in: source[trailingBodyRange])
    }

    private static func inlineHooksArrayContext(in source: String) -> InlineHooksArrayContext? {
        guard let assignmentRange = source.range(
            of: #"(?m)^[ \t]*hooks[ \t]*="#,
            options: .regularExpression
        ) else {
            return nil
        }

        var index = assignmentRange.upperBound
        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
        guard index < source.endIndex, source[index] == "[" else {
            return nil
        }

        let openBracketIndex = index
        var current = index
        var bracketDepth = 0
        var inString = false
        var inComment = false
        var escaped = false

        while current < source.endIndex {
            let character = source[current]
            if inComment {
                if character == "\n" {
                    inComment = false
                }
            } else if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "#":
                    inComment = true
                case "\"":
                    inString = true
                case "[":
                    bracketDepth += 1
                case "]":
                    bracketDepth -= 1
                    if bracketDepth == 0 {
                        let bodyStart = source.index(after: openBracketIndex)
                        let bodyRange = bodyStart..<current
                        return InlineHooksArrayContext(
                            assignmentRange: assignmentRange.lowerBound..<source.index(after: current),
                            openBracketIndex: openBracketIndex,
                            bodyRange: bodyRange,
                            hasElements: inlineHooksBodyHasElements(in: source[bodyRange])
                        )
                    }
                default:
                    break
                }
            }

            current = source.index(after: current)
        }

        return nil
    }

    private static func inlineHooksBodyHasElements(in body: Substring) -> Bool {
        var inString = false
        var inComment = false
        var escaped = false

        for character in body {
            if inComment {
                if character == "\n" {
                    inComment = false
                }
                continue
            }

            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            switch character {
            case "#":
                inComment = true
            case "\"":
                inString = true
            case "{":
                return true
            default:
                continue
            }
        }

        return false
    }

    private struct InlineHooksArrayContext {
        let assignmentRange: Range<String.Index>
        let openBracketIndex: String.Index
        let bodyRange: Range<String.Index>
        let hasElements: Bool
    }

    private static func uninstallReplacement(for source: String) -> String? {
        guard let blockRange = try? managedBlockRange(in: source),
              source[blockRange].contains("\(styleMarkerPrefix)\(HookConfigStyle.inlineArray.rawValue)") else {
            return nil
        }

        guard source[blockRange].contains("hooks = [") else {
            return nil
        }

        return emptyHooksPlaceholder
    }

    private static func removableManagedBlockRange(in source: String) throws -> Range<String.Index>? {
        guard let blockRange = try managedBlockRange(in: source) else {
            return nil
        }

        let blockText = source[blockRange]
        guard blockText.contains("\(styleMarkerPrefix)\(HookConfigStyle.inlineArray.rawValue)"),
              !blockText.contains("hooks = ["),
              blockRange.lowerBound > source.startIndex else {
            return blockRange
        }

        let precedingIndex = source.index(before: blockRange.lowerBound)
        guard source[precedingIndex] == "\n" else {
            return blockRange
        }

        return precedingIndex..<blockRange.upperBound
    }

    private static func hasEmptyHooksPlaceholder(in source: String) -> Bool {
        source
            .split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == emptyHooksPlaceholder }
    }

    private static func replacingEmptyHooksPlaceholder(in source: String, with replacement: String) -> String? {
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == emptyHooksPlaceholder
        }) else {
            return nil
        }

        var updatedLines = lines.map(String.init)
        updatedLines[index] = replacement
        return updatedLines.joined(separator: "\n")
    }

    private static func shellEscapeDoubleQuoted(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func tomlEscapeBasicString(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private enum HookConfigStyle: String, CaseIterable {
    case arrayTables = "array-tables"
    case inlineArray = "inline-array"
}

private extension String {
    var nonBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
