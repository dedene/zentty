import Darwin
import Foundation

enum AgentStatusHelper {
    static func runIfNeeded(arguments: [String], environment: [String: String]) -> Int32? {
        let subcommand = arguments.dropFirst().first
        guard subcommand == "agent-status" || subcommand == "agent-signal" else {
            return nil
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

    static func binaryPath(in bundle: Bundle = .main) -> String? {
        guard let path = bundle.executableURL?.path, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    static func claudeHookCommand(in bundle: Bundle = .main) -> String? {
        guard let binaryPath = binaryPath(in: bundle) else {
            return nil
        }

        return "\(binaryPath) claude-hook"
    }

    static func agentSignalCommand(in bundle: Bundle = .main) -> String? {
        guard let binaryPath = binaryPath(in: bundle) else {
            return nil
        }

        return "\(binaryPath) agent-signal"
    }

    static func wrapperBinPath(in bundle: Bundle = .main) -> String? {
        validatedDirectoryPath(
            bundle.resourceURL?.appendingPathComponent("bin", isDirectory: true),
            requiredRelativePaths: [
                "zentty-agent-wrapper",
                "claude",
                "codex",
                "opencode",
            ],
            executableRelativePaths: [
                "zentty-agent-wrapper",
                "claude",
                "codex",
                "opencode",
            ]
        )
    }

    static func shellIntegrationDirectoryPath(in bundle: Bundle = .main) -> String? {
        validatedDirectoryPath(
            bundle.resourceURL?.appendingPathComponent("shell-integration", isDirectory: true),
            requiredRelativePaths: [
                ".zshenv",
                "zentty-zsh-integration.zsh",
                "zentty-bash-integration.bash",
            ],
            executableRelativePaths: []
        )
    }

    static func post(_ payload: AgentStatusPayload) {
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            AgentStatusTransport.notificationName,
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
}
