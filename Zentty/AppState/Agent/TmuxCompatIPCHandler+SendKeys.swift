import AppKit
import Foundation

/// send-keys and the command-string helpers shared by the pane-creating
/// commands: how tmux text becomes keystrokes, and how a tmux command becomes
/// the native command a Zentty pane starts.
extension TmuxCompatIPCHandler {
    // MARK: - send-keys

    static let sendKeysValueFlags: Set<String> = ["-c", "-N", "-T", "-t"]
    static let sendKeysBoolFlags: Set<String> = ["-F", "-H", "-K", "-l", "-M", "-R", "-X"]

    @MainActor
    static func handleSendKeys(
        arguments: [String],
        standardInput: String?,
        context: TmuxCompatRequestContext
    ) throws -> AgentIPCResponseResult {
        let parsed = parseSendKeys(arguments)
        let location = try context.pane(parsed.value("-t"))
        let resolvedPaneID = PaneID(location.pane.id)
        let worklaneID = WorklaneID(location.window.id)
        let text = sendKeysText(parsed: parsed, standardInput: standardInput)
        guard !text.isEmpty else {
            return AgentIPCResponseResult()
        }
        if let launchCommand = launchCommandFromSendKeysText(text),
           let nativeCommand = shellWrappedGhosttyCommand(launchCommand),
           context.windowController.launchDeferredPane(id: resolvedPaneID, in: worklaneID, nativeCommand: nativeCommand) {
            return AgentIPCResponseResult()
        }
        let delivered = PaneInputService.pasteText(text, to: resolvedPaneID, in: context.windowController)
        if !delivered {
            tmuxLogger.warning(
                "send-keys: no live runtime for pane \(resolvedPaneID.rawValue, privacy: .public)"
            )
        }
        return AgentIPCResponseResult()
    }

    static func parseSendKeys(_ arguments: [String]) -> TmuxCompatArguments {
        TmuxCompatArguments.parse(arguments, valueFlags: sendKeysValueFlags, boolFlags: sendKeysBoolFlags)
    }

    static func sendKeysText(arguments: [String], standardInput: String?) -> String {
        sendKeysText(parsed: parseSendKeys(arguments), standardInput: standardInput)
    }

    /// The keys are the positionals: flags end at the first key or at `--`,
    /// so `claude --model opus Enter` is typed as written.
    static func sendKeysText(parsed: TmuxCompatArguments, standardInput: String?) -> String {
        let joined = tmuxSendKeysText(tokens: parsed.positionals, literal: parsed.hasFlag("-l"))
        if !joined.isEmpty {
            return joined
        }
        return standardInput ?? ""
    }

    static func launchCommandFromSendKeysText(_ text: String) -> String? {
        guard text.hasSuffix("\r") || text.hasSuffix("\n") else {
            return nil
        }
        let command = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty,
              !command.contains("\r"),
              !command.contains("\n")
        else {
            return nil
        }
        return command
    }

    static func shellWrappedGhosttyCommand(
        _ command: String,
        loginShellPath: String? = ProcessInfo.processInfo.environment["SHELL"]
    ) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let shellPath = loginShellPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !shellPath.isEmpty,
           isLoginShellSupported(shellPath) {
            return "\(shellQuote(shellPath)) -lic \(shellQuote(trimmed))"
        }
        return "sh -c \(shellQuote(trimmed))"
    }

    private static func isLoginShellSupported(_ shellPath: String) -> Bool {
        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
        return shellName == "zsh" || shellName == "bash" || shellName == "fish"
    }

    static func isClaudeBootstrapSplit(arguments: [String], parsed: TmuxCompatArguments) -> Bool {
        guard let separatorIndex = arguments.firstIndex(of: "--"),
              Array(arguments[arguments.index(after: separatorIndex)...]) == ["cat"],
              parsed.positionals == ["cat"],
              parsed.hasFlag("-d"),
              parsed.hasFlag("-P"),
              parsed.value("-t") != nil,
              parsed.formatTemplate == "#{pane_id}"
        else {
            return false
        }
        return true
    }

    static func splitWindowStartupRequest(
        arguments: [String],
        parsed: TmuxCompatArguments,
        loginShellPath: String? = ProcessInfo.processInfo.environment["SHELL"]
    ) -> TerminalSessionRequest {
        if isClaudeBootstrapSplit(arguments: arguments, parsed: parsed) {
            return TerminalSessionRequest(
                workingDirectory: parsed.value("-c"),
                isLaunchDeferred: true
            )
        }

        if let commandText = commandText(from: parsed.positionals),
           let nativeCommand = shellWrappedGhosttyCommand(commandText, loginShellPath: loginShellPath) {
            return TerminalSessionRequest(
                workingDirectory: parsed.value("-c"),
                nativeCommand: nativeCommand,
                waitAfterNativeCommand: true
            )
        }

        return TerminalSessionRequest(
            workingDirectory: parsed.value("-c"),
            isLaunchDeferred: true
        )
    }

    /// tmux runs a single command argument through the shell and several
    /// arguments as an argv. Joining the argv form with shell quoting keeps
    /// both meanings when the result goes through `sh -c`.
    static func commandText(from positionals: [String]) -> String? {
        let text: String
        if positionals.count > 1 {
            text = positionals.map(shellWord).joined(separator: " ")
        } else {
            text = positionals.first ?? ""
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shellWord(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%_-+=:,./"))
        if !value.isEmpty, value.unicodeScalars.allSatisfy(safe.contains) {
            return value
        }
        return shellQuote(value)
    }

    private static func tmuxSendKeysText(tokens: [String], literal: Bool) -> String {
        if literal {
            return tokens.joined(separator: " ")
        }

        var result = ""
        var pendingSpace = false
        for token in tokens {
            if let special = PaneKeyNames.controlKeyText(token) {
                result += special
                pendingSpace = false
                continue
            }
            if pendingSpace {
                result += " "
            }
            result += token
            pendingSpace = true
        }
        return result
    }
}
