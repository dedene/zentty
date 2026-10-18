import Foundation

/// tmux command-line handling shared by the CLI (`zentty __tmux-compat`) and
/// the app: command aliases, `;` sequences, tmux's command-string quoting,
/// and the local `if-shell` / `run-shell` commands.
enum TmuxCommandLine {
    /// Canonical command name for a tmux command or alias. Unknown names come
    /// back unchanged (lowercased) so the app can decide how to treat them.
    static func canonicalName(_ name: String) -> String {
        let lowered = name.lowercased()
        return aliases[lowered] ?? lowered
    }

    private static let aliases: [String: String] = [
        "attach": "attach-session",
        "breakp": "break-pane",
        "capturep": "capture-pane",
        "deleteb": "delete-buffer",
        "detach": "detach-client",
        "display": "display-message",
        "displayp": "display-panes",
        "popup": "display-popup",
        "has": "has-session",
        "if": "if-shell",
        "joinp": "join-pane",
        "killp": "kill-pane",
        "killw": "kill-window",
        "lastp": "last-pane",
        "last": "last-window",
        "lsb": "list-buffers",
        "lsc": "list-clients",
        "lsp": "list-panes",
        "ls": "list-sessions",
        "lsw": "list-windows",
        "loadb": "load-buffer",
        "movep": "move-pane",
        "new": "new-session",
        "neww": "new-window",
        "pasteb": "paste-buffer",
        "refresh": "refresh-client",
        "rename": "rename-session",
        "renamew": "rename-window",
        "resizep": "resize-pane",
        "respawnp": "respawn-pane",
        "respawnw": "respawn-window",
        "run": "run-shell",
        "saveb": "save-buffer",
        "selectl": "select-layout",
        "selectp": "select-pane",
        "selectw": "select-window",
        "send": "send-keys",
        "set": "set-option",
        "setb": "set-buffer",
        "setenv": "set-environment",
        "setw": "set-window-option",
        "show": "show-options",
        "show-option": "show-options",
        "showb": "show-buffer",
        "showenv": "show-environment",
        "showmsgs": "show-messages",
        "showw": "show-window-options",
        "source": "source-file",
        "splitw": "split-window",
        "start": "start-server",
        "swapp": "swap-pane",
        "switchc": "switch-client",
        "wait": "wait-for",
    ]

    /// Splits a command-line argv into separate commands on `;`. A lone `;`
    /// argument or an argument ending in an unescaped `;` ends a command; a
    /// trailing `\;` is a literal semicolon. Empty commands are dropped.
    static func splitSequence(_ arguments: [String]) -> [[String]] {
        var commands: [[String]] = []
        var current: [String] = []
        for argument in arguments {
            if argument == ";" {
                commands.append(current)
                current = []
                continue
            }
            if argument.hasSuffix("\\;") {
                current.append(String(argument.dropLast(2)) + ";")
                continue
            }
            if argument.hasSuffix(";") {
                current.append(String(argument.dropLast()))
                commands.append(current)
                current = []
                continue
            }
            current.append(argument)
        }
        commands.append(current)
        return commands.filter { !$0.isEmpty }
    }

    enum ParseError: Error, Equatable {
        case unterminatedQuote
    }

    /// Parses a tmux command string (the branches of `if-shell`, `run-shell
    /// -C`) into argv-style commands. Follows tmux's quoting: single quotes
    /// are literal, double quotes honour backslash escapes, an unquoted `;`
    /// ends a command, `\;` is a literal semicolon and an unquoted `#` at the
    /// start of a word starts a comment.
    static func parseCommandString(_ source: String) throws -> [[String]] {
        var commands: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        let characters = Array(source)
        var index = 0

        func endWord() {
            if inWord {
                words.append(word)
            }
            word = ""
            inWord = false
        }
        func endCommand() {
            endWord()
            if !words.isEmpty {
                commands.append(words)
            }
            words = []
        }

        while index < characters.count {
            let character = characters[index]
            switch character {
            case " ", "\t":
                endWord()
            case "\n":
                endCommand()
            case ";":
                endCommand()
            case "#" where !inWord && (index + 1 >= characters.count || characters[index + 1] != "{"):
                while index < characters.count, characters[index] != "\n" {
                    index += 1
                }
                continue
            case "\\":
                index += 1
                if index < characters.count {
                    word.append(characters[index])
                }
                inWord = true
            case "'":
                inWord = true
                index += 1
                while index < characters.count, characters[index] != "'" {
                    word.append(characters[index])
                    index += 1
                }
                guard index < characters.count else {
                    throw ParseError.unterminatedQuote
                }
            case "\"":
                inWord = true
                index += 1
                while index < characters.count, characters[index] != "\"" {
                    if characters[index] == "\\", index + 1 < characters.count {
                        index += 1
                        word.append(escapedCharacter(characters[index]))
                    } else {
                        word.append(characters[index])
                    }
                    index += 1
                }
                guard index < characters.count else {
                    throw ParseError.unterminatedQuote
                }
            default:
                word.append(character)
                inWord = true
            }
            index += 1
        }
        endCommand()
        return commands
    }

    private static func escapedCharacter(_ character: Character) -> Character {
        switch character {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        default: return character
        }
    }

    /// tmux's global options, accepted before the subcommand and ignored:
    /// routing goes through the Zentty IPC socket.
    static let globalValueOptions: Set<String> = ["-S", "-L", "-T", "-f", "-c"]
    static let globalBoolOptions: Set<String> = [
        "-2", "-C", "-CC", "-D", "-d", "-l", "-N", "-P", "-q", "-u", "-U", "-v",
    ]

    /// True when the global options before the subcommand ask for the
    /// version: `tmux -V`, possibly after others (`tmux -S sock -V`).
    static func isVersionRequest(_ arguments: [String]) -> Bool {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-V" {
                return true
            }
            if globalValueOptions.contains(argument) {
                index += 2
                continue
            }
            if globalBoolOptions.contains(argument) {
                index += 1
                continue
            }
            return false
        }
        return false
    }

    /// Reported by `tmux -V` and `#{version}`. Tools gate features on 3.2+
    /// (`split-window -e`, `display-popup`) and on 3.x pane-option syntax.
    static let version = "3.4"

    static var versionLine: String {
        "tmux \(version)\n"
    }
}

/// Result of one tmux command, as the CLI prints it.
struct TmuxCommandOutcome: Equatable {
    var stdout: String = ""
    var stderr: String = ""
    var exitCode: Int32 = 0

    static let success = TmuxCommandOutcome()

    static func failure(_ message: String) -> TmuxCommandOutcome {
        TmuxCommandOutcome(stderr: message.hasSuffix("\n") ? message : message + "\n", exitCode: 1)
    }
}

/// What the interpreter needs from its host: forward one command to the app,
/// expand a format for a target, and run shell commands.
protocol TmuxCommandBackend {
    func send(subcommand: String, arguments: [String]) -> TmuxCommandOutcome
    func expandFormat(_ format: String, target: String?) -> String?
    func runShell(_ command: String) -> (stdout: String, exitCode: Int32)
    func runShellInBackground(_ command: String)
}

/// Runs a tmux invocation: sequences, `if-shell`, `run-shell`, and
/// everything else through the backend. Execution stops at the first
/// failing command, like tmux.
struct TmuxCommandRunner {
    let backend: any TmuxCommandBackend
    var maxDepth = 8

    func run(_ arguments: [String]) -> TmuxCommandOutcome {
        run(commands: TmuxCommandLine.splitSequence(arguments), depth: 0)
    }

    private func run(commands: [[String]], depth: Int) -> TmuxCommandOutcome {
        var combined = TmuxCommandOutcome()
        for command in commands {
            let outcome = run(command: command, depth: depth)
            combined.stdout += outcome.stdout
            combined.stderr += outcome.stderr
            if outcome.exitCode != 0 {
                combined.exitCode = outcome.exitCode
                return combined
            }
        }
        return combined
    }

    private func run(command: [String], depth: Int) -> TmuxCommandOutcome {
        guard let name = command.first else {
            return .success
        }
        let arguments = Array(command.dropFirst())
        switch TmuxCommandLine.canonicalName(name) {
        case "if-shell":
            return ifShell(arguments, depth: depth)
        case "run-shell":
            return runShell(arguments, depth: depth)
        default:
            return backend.send(subcommand: name, arguments: arguments)
        }
    }

    private func runCommandString(_ source: String, depth: Int) -> TmuxCommandOutcome {
        guard depth < maxDepth else {
            return .failure("command nesting too deep")
        }
        do {
            return run(commands: try TmuxCommandLine.parseCommandString(source), depth: depth + 1)
        } catch {
            return .failure("syntax error in command: \(source)")
        }
    }

    private func ifShell(_ arguments: [String], depth: Int) -> TmuxCommandOutcome {
        let parsed = TmuxCompatArguments.parse(arguments, valueFlags: ["-t"], boolFlags: ["-b", "-F"])
        guard parsed.positionals.count == 2 || parsed.positionals.count == 3 else {
            return .failure("usage: if-shell [-bF] [-t target-pane] shell-command command [command]")
        }
        let target = parsed.value("-t")
        let condition = parsed.positionals[0]
        let succeeded: Bool
        if parsed.hasFlag("-F") {
            guard let expanded = backend.expandFormat(condition, target: target) else {
                return .failure("can't find pane: \(target ?? "")")
            }
            succeeded = TmuxFormatRenderer.isTruthy(expanded)
        } else {
            let command = condition.contains("#") ? backend.expandFormat(condition, target: target) : condition
            guard let command else {
                return .failure("can't find pane: \(target ?? "")")
            }
            succeeded = backend.runShell(command).exitCode == 0
        }
        if succeeded {
            return runCommandString(parsed.positionals[1], depth: depth)
        }
        if parsed.positionals.count == 3 {
            return runCommandString(parsed.positionals[2], depth: depth)
        }
        return .success
    }

    private func runShell(_ arguments: [String], depth: Int) -> TmuxCommandOutcome {
        let parsed = TmuxCompatArguments.parse(arguments, valueFlags: ["-d", "-t", "-c"], boolFlags: ["-b", "-C", "-E"])
        guard let source = parsed.positionals.first else {
            return .success
        }
        if parsed.hasFlag("-C") {
            return runCommandString(source, depth: depth)
        }
        let command = source.contains("#") ? backend.expandFormat(source, target: parsed.value("-t")) : source
        guard let command else {
            return .failure("can't find pane: \(parsed.value("-t") ?? "")")
        }
        if parsed.hasFlag("-b") {
            backend.runShellInBackground(command)
            return .success
        }
        let result = backend.runShell(command)
        var outcome = TmuxCommandOutcome(stdout: result.stdout)
        if result.exitCode != 0 {
            outcome.stderr = "'\(source)' returned \(result.exitCode)\n"
            outcome.exitCode = 1
        }
        return outcome
    }
}
