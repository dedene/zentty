import Foundation

/// Paste buffers, capture-pane, wait-for and request tracing.
extension TmuxCompatIPCHandler {
    // MARK: - buffers

    static func handleSaveBuffer(arguments: [String]) -> AgentIPCResponseResult {
        let store = TmuxCompatStoreIO.load()
        let bufferName = bufferName(in: arguments) ?? store.buffers.keys.sorted().first ?? ""
        let value = store.buffers[bufferName] ?? ""
        return AgentIPCResponseResult(stdout: value)
    }

    static func handleSetBuffer(
        arguments: [String],
        standardInput: String?
    ) -> AgentIPCResponseResult {
        let bufferName = bufferName(in: arguments) ?? "default"
        let value = standardInput ?? ""
        TmuxCompatStoreIO.mutate { store in
            store.buffers[bufferName] = value
        }
        return AgentIPCResponseResult()
    }

    private static func bufferName(in arguments: [String]) -> String? {
        guard let flagIndex = arguments.firstIndex(of: "-b"),
              flagIndex + 1 < arguments.count
        else {
            return nil
        }
        return arguments[flagIndex + 1]
    }

    // MARK: - capture-pane

    struct CapturePaneOptions: Equatable {
        let target: String?
        let print: Bool
        let includeScrollback: Bool
        let lineLimit: Int?
    }

    @MainActor
    static func handleCapturePane(
        arguments: [String],
        context: TmuxCompatRequestContext
    ) throws -> AgentIPCResponseResult {
        let options = capturePaneOptions(arguments: arguments)
        let paneID = PaneID(try context.pane(options.target).pane.id)
        let text = context.windowController.readText(
            from: paneID,
            includeScrollback: options.includeScrollback,
            lineLimit: options.lineLimit
        ) ?? ""

        if options.print {
            return AgentIPCResponseResult(stdout: text.hasSuffix("\n") ? text : text + "\n")
        }

        TmuxCompatStoreIO.mutate { store in
            store.buffers["default"] = text
        }
        return AgentIPCResponseResult()
    }

    static func capturePaneOptions(arguments: [String]) -> CapturePaneOptions {
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-b", "-E", "-S", "-t"],
            boolFlags: ["-a", "-C", "-e", "-J", "-M", "-N", "-P", "-p", "-q", "-T"]
        )
        let lineLimit = parsed.value("-S").flatMap { value -> Int? in
            guard let start = Int(value), start < 0 else {
                return nil
            }
            return abs(start)
        }
        return CapturePaneOptions(
            target: parsed.value("-t"),
            print: parsed.hasFlag("-p"),
            includeScrollback: true,
            lineLimit: lineLimit
        )
    }

    static func tailTerminalLines(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else {
            return ""
        }
        let hadTrailingNewline = text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hadTrailingNewline, lines.last == "" {
            lines.removeLast()
        }
        var output = lines.suffix(maxLines).joined(separator: "\n")
        if hadTrailingNewline, !output.isEmpty {
            output.append("\n")
        }
        return output
    }

    // MARK: - wait-for

    enum WaitForAction: Equatable {
        case signal(String)
        case wait(name: String, timeout: TimeInterval)
        case invalid
    }

    static func handleWaitFor(
        arguments: [String],
        environment: [String: String]
    ) -> AgentIPCResponseResult {
        switch waitForAction(arguments: arguments) {
        case .signal(let name):
            signalWaitFor(name: name, environment: environment)
        case .wait(let name, let timeout):
            _ = waitForSignal(name: name, timeout: timeout, environment: environment)
        case .invalid:
            tmuxLogger.warning("wait-for requires a name")
        }
        return AgentIPCResponseResult()
    }

    static func waitForAction(arguments: [String]) -> WaitForAction {
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["--timeout"],
            boolFlags: ["-L", "-S", "-U", "--signal"]
        )
        guard let name = parsed.positionals.first else {
            return .invalid
        }
        if parsed.hasFlag("-S") || parsed.hasFlag("--signal") {
            return .signal(name)
        }
        let timeout = parsed.value("--timeout").flatMap(TimeInterval.init) ?? 30
        return .wait(name: name, timeout: timeout)
    }

    static func waitForSignalURL(name: String, environment: [String: String] = [:]) -> URL {
        let scope = environment["ZENTTY_INSTANCE_ID"] ?? environment["ZENTTY_WORKLANE_ID"] ?? "global"
        let rawName = "\(scope)-\(name)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = rawName.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        return URL(fileURLWithPath: "/tmp/zentty-tmux-wait-for-\(String(sanitized)).sig")
    }

    static func signalWaitFor(name: String, environment: [String: String] = [:]) {
        let url = waitForSignalURL(name: name, environment: environment)
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    static func waitForSignal(
        name: String,
        timeout: TimeInterval,
        environment: [String: String] = [:]
    ) -> Bool {
        let url = waitForSignalURL(name: name, environment: environment)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        return false
    }

    // MARK: - tracing

    static func trace(
        event: String,
        request: AgentIPCRequest,
        fields: [String: String]
    ) {
        guard let path = request.environment["ZENTTY_TMUX_COMPAT_TRACE_PATH"], !path.isEmpty else {
            return
        }

        var payload: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "event": event,
            "subcommand": request.subcommand ?? "",
            "arguments": request.arguments,
            "worklane_id": request.environment["ZENTTY_WORKLANE_ID"] ?? "",
            "pane_id": request.environment["ZENTTY_PANE_ID"] ?? "",
        ]
        fields.forEach { payload[$0.key] = $0.value }
        appendTracePayload(payload, to: path)
    }

    private static func appendTracePayload(_ payload: [String: Any], to path: String) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else {
            return
        }

        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let handle = try? FileHandle(forWritingTo: url) else {
            var line = data
            line.append(UInt8(ascii: "\n"))
            try? line.write(to: url, options: .atomic)
            return
        }
        defer {
            try? handle.close()
        }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.write(contentsOf: Data([UInt8(ascii: "\n")]))
    }
}
