import Foundation

enum WorklaneSessionEnvironment {
    static func make(
        windowID: WindowID,
        worklaneID: WorklaneID,
        paneID: PaneID,
        initialWorkingDirectory: String? = nil,
        processEnvironment: [String: String]
    ) -> [String: String] {
        var environment: [String: String] = [
            "ZENTTY_WINDOW_ID": windowID.rawValue,
            "ZENTTY_WORKLANE_ID": worklaneID.rawValue,
            "ZENTTY_PANE_ID": paneID.rawValue,
        ]

        if let initialWorkingDirectory = trimmed(initialWorkingDirectory) {
            environment["ZENTTY_INITIAL_WORKING_DIRECTORY"] = initialWorkingDirectory
        }

        if let connectionInfo = AgentIPCServer.shared.connectionInfo(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID
        ) {
            environment["ZENTTY_INSTANCE_SOCKET"] = connectionInfo.socketPath
            environment["ZENTTY_PANE_TOKEN"] = connectionInfo.paneToken
            environment["ZENTTY_CLI_BIN"] = connectionInfo.cliPath
        }

        if let wrapperDirectories = AgentStatusHelper.wrapperDirectoryPaths() {
            environment["ZENTTY_ALL_WRAPPER_BIN_DIRS"] = wrapperDirectories.joined(separator: ":")
        }

        if let supportDirectory = AgentStatusHelper.wrapperSupportDirectoryPath(in: .main) {
            let currentPath = processEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            let pathEntries = currentPath.split(separator: ":").map(String.init)
            environment["PATH"] = pathEntries.contains(supportDirectory)
                ? currentPath
                : ([supportDirectory] + pathEntries).joined(separator: ":")
        }

        if let shellIntegrationDirectory = AgentStatusHelper.shellIntegrationDirectoryPath() {
            environment["ZENTTY_SHELL_INTEGRATION_DIR"] = shellIntegrationDirectory
            environment["ZENTTY_SHELL_INTEGRATION"] = "1"
            environment["ZDOTDIR"] = shellIntegrationDirectory

            if let currentZDOTDIR = processEnvironment["ZDOTDIR"], !currentZDOTDIR.isEmpty {
                environment["ZENTTY_ORIGINAL_ZDOTDIR"] = currentZDOTDIR
            }

            if let currentPromptCommand = processEnvironment["PROMPT_COMMAND"], !currentPromptCommand.isEmpty {
                environment["ZENTTY_BASH_ORIGINAL_PROMPT_COMMAND"] = currentPromptCommand
            }

            environment["PROMPT_COMMAND"] = ". \"\(shellIntegrationDirectory)/zentty-bash-integration.bash\""
        }

        if let ghosttyLog = processEnvironment["GHOSTTY_LOG"], !ghosttyLog.isEmpty {
            environment["GHOSTTY_LOG"] = ghosttyLog
        } else {
            environment["GHOSTTY_LOG"] = "macos,no-stderr"
        }

        return environment
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }
}
