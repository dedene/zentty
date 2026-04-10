import ArgumentParser
import Darwin
import Foundation

@main
struct ZenttyCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "zentty",
        abstract: "Zentty command-line interface.",
        subcommands: [
            VersionCommand.self,
            CodexNotifyCommand.self,
            IPCCommand.self,
            LaunchCommand.self,
        ]
    )
}

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Show the running Zentty version."
    )

    mutating func run() throws {
        let metadata = ZenttyVersionMetadata.load()
        print("zentty \(metadata.version) (\(metadata.commit))")
    }
}

struct CodexNotifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "codex-notify",
        abstract: "Forward a Codex notify callback payload to the running Zentty app.",
        shouldDisplay: false
    )

    @Argument(help: "The raw JSON payload passed by Codex notify callbacks.")
    var payload: String?

    mutating func run() throws {
        guard let socketPath = ProcessInfo.processInfo.environment["ZENTTY_INSTANCE_SOCKET"],
              !socketPath.isEmpty,
              IPCCommand.hasRequiredRoutingEnvironment(ProcessInfo.processInfo.environment) else {
            return
        }

        guard let payload = payload ?? standardInputPayload() else {
            throw ValidationError("Missing Codex notify payload.")
        }

        let request = AgentIPCRequest(
            kind: .ipc,
            arguments: ["--adapter=codex-notify"],
            standardInput: payload,
            environment: IPCCommand.forwardedEnvironment(from: ProcessInfo.processInfo.environment),
            expectsResponse: false,
            subcommand: "agent-event"
        )

        do {
            _ = try AgentIPCClient.send(request: request, socketPath: socketPath)
        } catch {
            guard ProcessInfo.processInfo.environment["ZENTTY_CLI_DEBUG"] == "1" else {
                return
            }
            FileHandle.standardError.write(Data(("zentty codex-notify send failed: \(error.localizedDescription)\n").utf8))
        }
    }

    private func standardInputPayload() -> String? {
        guard isatty(STDIN_FILENO) == 0 else {
            return nil
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

struct IPCCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ipc",
        abstract: "Send agent events and signals to the running Zentty app.",
        shouldDisplay: false
    )

    private static let supportedSubcommands = Set(["agent-event", "agent-signal", "agent-status"])
    private static let forwardedEnvironmentKeys = [
        "ZENTTY_WINDOW_ID",
        "ZENTTY_WORKLANE_ID",
        "ZENTTY_PANE_ID",
        "ZENTTY_PANE_TOKEN",
        "ZENTTY_CLAUDE_PID",
        "ZENTTY_CODEX_PID",
        "ZENTTY_COPILOT_PID",
    ]

    @Argument(help: "Supported values: agent-event, agent-signal, agent-status")
    var subcommand: String

    @Argument(parsing: .captureForPassthrough, help: "Arguments forwarded to the IPC subcommand.")
    var arguments: [String] = []

    mutating func run() throws {
        guard Self.supportedSubcommands.contains(subcommand) else {
            throw ValidationError("Unsupported ipc subcommand: \(subcommand)")
        }
        guard let socketPath = ProcessInfo.processInfo.environment["ZENTTY_INSTANCE_SOCKET"],
              !socketPath.isEmpty,
              Self.hasRequiredRoutingEnvironment(ProcessInfo.processInfo.environment) else {
            return
        }

        let request = AgentIPCRequest(
            kind: .ipc,
            arguments: arguments,
            standardInput: standardInput(),
            environment: Self.forwardedEnvironment(from: ProcessInfo.processInfo.environment),
            expectsResponse: false,
            subcommand: subcommand
        )

        do {
            _ = try AgentIPCClient.send(request: request, socketPath: socketPath)
        } catch {
            guard ProcessInfo.processInfo.environment["ZENTTY_CLI_DEBUG"] == "1" else {
                return
            }
            FileHandle.standardError.write(Data(("zentty ipc send failed: \(error.localizedDescription)\n").utf8))
        }
    }

    private func standardInput() -> String? {
        guard subcommand == "agent-event", isatty(STDIN_FILENO) == 0 else {
            return nil
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func hasRequiredRoutingEnvironment(_ environment: [String: String]) -> Bool {
        for key in ["ZENTTY_PANE_TOKEN", "ZENTTY_WORKLANE_ID", "ZENTTY_PANE_ID"] {
            guard let value = environment[key], !value.isEmpty else {
                return false
            }
        }
        return true
    }

    static func forwardedEnvironment(from environment: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: Self.forwardedEnvironmentKeys.compactMap { key in
            guard let value = environment[key], !value.isEmpty else {
                return nil
            }
            return (key, value)
        })
    }
}

struct LaunchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Prepare and launch an integrated tool inside Zentty.",
        shouldDisplay: false
    )

    @Argument(help: "Supported values: claude, codex, copilot, opencode")
    var tool: String

    @Argument(parsing: .captureForPassthrough, help: "Arguments forwarded to the real tool.")
    var arguments: [String] = []

    mutating func run() throws {
        guard let tool = AgentBootstrapTool(rawValue: tool) else {
            throw ValidationError("Unsupported launch tool: \(tool)")
        }
        try AgentToolLauncher(tool: tool, arguments: arguments, environment: ProcessInfo.processInfo.environment).run()
    }
}

private struct ZenttyVersionMetadata {
    let version: String
    let commit: String

    static func load(
        currentBundle: Bundle = .main,
        executableURL: URL = resolvedExecutableURL(),
        fileManager: FileManager = .default
    ) -> ZenttyVersionMetadata {
        for candidateURL in candidateBundleURLs(
            for: executableURL,
            currentBundle: currentBundle,
            fileManager: fileManager
        ) {
            guard let candidateBundle = Bundle(url: candidateURL) else {
                continue
            }
            let metadata = from(bundle: candidateBundle)
            if metadata.version != "Unknown" || metadata.commit != "unknown" {
                return metadata
            }
        }

        return from(bundle: currentBundle)
    }

    private static func from(bundle: Bundle) -> ZenttyVersionMetadata {
        let infoDictionary = bundle.infoDictionary ?? [:]
        return ZenttyVersionMetadata(
            version: trimmedValue(for: "CFBundleShortVersionString", in: infoDictionary) ?? "Unknown",
            commit: trimmedValue(for: "ZenttyGitCommit", in: infoDictionary) ?? "unknown"
        )
    }

    private static func candidateBundleURLs(
        for executableURL: URL,
        currentBundle: Bundle,
        fileManager: FileManager
    ) -> [URL] {
        var bundleURLs: [URL] = []
        let standardizedExecutableURL = executableURL.resolvingSymlinksInPath().standardizedFileURL
        let pathComponents = standardizedExecutableURL.pathComponents

        if let appIndex = pathComponents.lastIndex(where: { $0.hasSuffix(".app") }) {
            let appURL = pathComponents[0...appIndex].reduce(URL(fileURLWithPath: "/")) { partial, component in
                partial.appendingPathComponent(component, isDirectory: true)
            }
            bundleURLs.append(appURL)
        }

        let siblingAppURL = standardizedExecutableURL
            .deletingLastPathComponent()
            .appendingPathComponent("Zentty.app", isDirectory: true)
        if fileManager.fileExists(atPath: siblingAppURL.path) {
            bundleURLs.append(siblingAppURL)
        }

        let currentBundleURL = currentBundle.bundleURL.standardizedFileURL
        if fileManager.fileExists(atPath: currentBundleURL.path) {
            bundleURLs.append(currentBundleURL)
        }

        var deduplicated: [URL] = []
        var seenPaths = Set<String>()
        for url in bundleURLs {
            if seenPaths.insert(url.path).inserted {
                deduplicated.append(url)
            }
        }
        return deduplicated
    }

    private static func trimmedValue(for key: String, in infoDictionary: [String: Any]) -> String? {
        guard let rawValue = infoDictionary[key] as? String else {
            return nil
        }

        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func resolvedExecutableURL() -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else {
            return URL(fileURLWithPath: CommandLine.arguments[0])
        }

        var buffer = [CChar](repeating: 0, count: Int(size))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            _NSGetExecutablePath(pointer.baseAddress, &size)
        }
        guard result == 0 else {
            return URL(fileURLWithPath: CommandLine.arguments[0])
        }

        let executablePath = String(cString: buffer)
        return URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().standardizedFileURL
    }
}
