import Darwin
import Foundation

enum AgentStatusHelper {
    private static let wrappedToolNames = ["claude", "codex", "copilot", "gemini", "opencode"]
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static func runIfNeeded(arguments: [String], environment: [String: String]) -> Int32? {
        let subcommand = arguments.dropFirst().first
        guard subcommand == "agent-event"
            || subcommand == "agent-status"
            || subcommand == "agent-signal"
        else {
            return nil
        }

        if subcommand == "agent-event" {
            return AgentEventBridge.runIfNeeded(arguments: arguments, environment: environment)
        }

        do {
            let payload: AgentStatusPayload
            if subcommand == "agent-signal" {
                payload = try AgentSignalCommand.parse(arguments: arguments, environment: environment).payload
            } else {
                payload = try AgentStatusCommand.parse(arguments: arguments, environment: environment).payload
            }
            post(payload)
            return EXIT_SUCCESS
        } catch {
            writeError(error)
            return EXIT_FAILURE
        }
    }

    static func cliPath(in bundle: Bundle = .main) -> String? {
        for candidateBundle in candidateBundles(for: bundle) {
            let cliURL = candidateBundle.resourceURL?
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("shared", isDirectory: true)
                .appendingPathComponent("zentty", isDirectory: false)
            if let cliURL, FileManager.default.isExecutableFile(atPath: cliURL.path) {
                return cliURL.path
            }
        }
        return nil
    }

    static func wrapperBinPath(in bundle: Bundle = .main) -> String? {
        for candidateBundle in candidateBundles(for: bundle) {
            if let path = validatedDirectoryPath(
                candidateBundle.resourceURL?.appendingPathComponent("bin", isDirectory: true),
                requiredRelativePaths: [
                    "claude/claude",
                    "codex/codex",
                    "copilot/copilot",
                    "gemini/gemini",
                    "opencode/opencode",
                    "shared/zentty-agent-wrapper",
                ],
                executableRelativePaths: [
                    "claude/claude",
                    "codex/codex",
                    "copilot/copilot",
                    "gemini/gemini",
                    "opencode/opencode",
                    "shared/zentty-agent-wrapper",
                ]
            ) {
                return path
            }
        }
        return nil
    }

    static func wrapperDirectoryPaths(in bundle: Bundle = .main) -> [String]? {
        guard let rootPath = wrapperBinPath(in: bundle) else {
            return nil
        }

        return wrappedToolNames.map {
            URL(fileURLWithPath: rootPath, isDirectory: true)
                .appendingPathComponent($0, isDirectory: true)
                .path
        }
    }

    static func wrapperSupportDirectoryPath(in bundle: Bundle = .main) -> String? {
        guard let rootPath = wrapperBinPath(in: bundle) else {
            return nil
        }

        let supportDirectory = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("shared", isDirectory: true)
        let bundledCLIPath = supportDirectory
            .appendingPathComponent("zentty", isDirectory: false)
            .path
        guard FileManager.default.isExecutableFile(atPath: bundledCLIPath) else {
            return nil
        }

        return supportDirectory.path
    }

    static func enabledWrapperDirectoryPaths(
        in bundle: Bundle = .main,
        processEnvironment: [String: String]
    ) -> [String] {
        guard let wrapperDirectories = wrapperDirectoryPaths(in: bundle) else {
            return []
        }

        let supportDirectory = wrapperSupportDirectoryPath(in: bundle)
        let rootDirectory = wrapperBinPath(in: bundle)
        let excludedDirectories = Set(wrapperDirectories + [supportDirectory, rootDirectory].compactMap { $0 })
        let pathEntries = (processEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)

        return wrapperDirectories.filter { wrapperDirectory in
            let toolName = URL(fileURLWithPath: wrapperDirectory, isDirectory: true).lastPathComponent
            return pathEntries.contains { entry in
                guard !excludedDirectories.contains(entry) else {
                    return false
                }

                let candidatePath = URL(fileURLWithPath: entry, isDirectory: true)
                    .appendingPathComponent(toolName, isDirectory: false)
                    .path
                return FileManager.default.isExecutableFile(atPath: candidatePath)
            }
        }
    }

    static func shellIntegrationDirectoryPath(in bundle: Bundle = .main) -> String? {
        for candidateBundle in candidateBundles(for: bundle) {
            if let path = validatedDirectoryPath(
                candidateBundle.resourceURL?.appendingPathComponent("shell-integration", isDirectory: true),
                requiredRelativePaths: [
                    ".zshenv",
                    "zentty-zsh-integration.zsh",
                    "zentty-bash-integration.bash",
                ],
                executableRelativePaths: []
            ) {
                return path
            }
        }
        return nil
    }

    static func post(
        _ payload: AgentStatusPayload,
        instanceID: String? = ProcessInfo.processInfo.environment[AgentStatusTransport.instanceIDEnvironmentKey]
    ) {
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            AgentStatusTransport.notificationName(instanceID: instanceID),
            object: nil,
            userInfo: payload.notificationUserInfo,
            deliverImmediately: true
        )
    }

    static func writeError(_ error: Error) {
        let errorDescription: String
        if let payloadError = error as? AgentStatusPayloadError {
            errorDescription = String(describing: payloadError)
        } else {
            errorDescription = error.localizedDescription
        }
        FileHandle.standardError.write(Data((errorDescription + "\n").utf8))
    }

    private static func validatedDirectoryPath(
        _ directoryURL: URL?,
        requiredRelativePaths: [String],
        executableRelativePaths: [String]
    ) -> String? {
        guard let directoryURL else {
            return nil
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        for relativePath in requiredRelativePaths {
            let requiredURL = directoryURL.appendingPathComponent(relativePath, isDirectory: false)
            guard fileManager.isReadableFile(atPath: requiredURL.path) else {
                return nil
            }
        }

        for relativePath in executableRelativePaths {
            let requiredURL = directoryURL.appendingPathComponent(relativePath, isDirectory: false)
            guard fileManager.isExecutableFile(atPath: requiredURL.path) else {
                return nil
            }
        }

        return directoryURL.path
    }

    private static func candidateBundles(for bundle: Bundle) -> [Bundle] {
        var bundles = [bundle]
        guard isRunningTests else {
            return bundles
        }
        let shouldSearchAdjacentApp =
            bundle == .main || bundle.bundleURL.pathExtension == "xctest"
        guard shouldSearchAdjacentApp else {
            return bundles
        }

        let bundleURLs = [bundle] + Bundle.allBundles + Bundle.allFrameworks
        let candidateAppURLs = Set(bundleURLs.flatMap { candidate -> [URL] in
            let urls = [
                candidate.bundleURL,
                candidate.resourceURL,
                candidate.executableURL,
            ].compactMap { $0?.standardizedFileURL }

            return urls.flatMap { url -> [URL] in
                let baseDirectory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
                return [
                    baseDirectory.appendingPathComponent("Zentty.app", isDirectory: true),
                    baseDirectory.deletingLastPathComponent().appendingPathComponent("Zentty.app", isDirectory: true),
                ]
            }
        })

        var seenPaths = Set(bundles.map(\.bundleURL.path))
        for appURL in candidateAppURLs where appURL.path != bundle.bundleURL.path {
            guard !seenPaths.contains(appURL.path),
                  let appBundle = Bundle(url: appURL) else {
                continue
            }
            bundles.append(appBundle)
            seenPaths.insert(appURL.path)
        }

        return bundles
    }
}
