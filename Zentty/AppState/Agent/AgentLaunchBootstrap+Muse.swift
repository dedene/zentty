import Foundation

// MARK: - Muse Code managed hooks overlay

/// Muse Code (Meta's `muse` CLI) reads Claude Code-format hooks from a
/// "managed" hooks file named by `TBH_MANAGED_HOOKS_PATH`. The env var
/// REPLACES the `managed_hooks_path` from `settings.json` rather than layering
/// on it, so the overlay starts from whichever managed file the user already
/// had and appends the Zentty status hooks. `~/.config/muse` is never written.
///
/// Muse scrubs the hook environment: only `PATH`, `HOME`, `MUSE_*` and the
/// names listed in `managed_hooks_env_vars` reach a hook process. The plan
/// passes that allowlist per run with `-c`, unioned with any list the user
/// already configured, so the Zentty routing env reaches `zentty ipc`.
extension AgentLaunchBootstrap {
    static let museManagedHooksPathKey = "TBH_MANAGED_HOOKS_PATH"

    /// Env names the hook process needs to route an event to its pane.
    static let museHookEnvironmentKeys = [
        "ZENTTY_INSTANCE_SOCKET",
        "ZENTTY_INSTANCE_ID",
        "ZENTTY_WINDOW_ID",
        "ZENTTY_WORKLANE_ID",
        "ZENTTY_PANE_ID",
        "ZENTTY_PANE_TOKEN",
        "ZENTTY_MUSE_PID",
    ]

    /// Hook events we subscribe to, with the timeout (seconds). Muse only
    /// admits `ToolUseStart` and `Interrupt` handlers declared `async: true`.
    private static let museHookSpecs: [(event: String, timeout: Int, isAsync: Bool)] = [
        ("SessionStart", 10, false),
        ("SessionEnd", 5, false),
        ("UserPromptSubmit", 10, false),
        ("PreToolUse", 5, false),
        ("ToolUseStart", 5, true),
        ("PostToolUse", 5, false),
        ("PostToolUseFailure", 5, false),
        ("PostToolBatch", 5, false),
        ("PermissionRequest", 10, false),
        ("Notification", 10, false),
        ("SubagentStart", 5, false),
        ("SubagentStop", 5, false),
        ("PreCompact", 10, false),
        ("PostCompact", 10, false),
        ("Stop", 10, false),
        ("StopFailure", 10, false),
        ("Interrupt", 5, true),
    ]

    static func musePlan(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        target: AgentIPCTarget,
        runtimeDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> AgentLaunchPlan {
        if environment["ZENTTY_MUSE_HOOKS_DISABLED"] == "1" {
            return directPlan(
                executablePath: executablePath,
                arguments: arguments,
                unsetEnvironment: museInheritedOverlayKeys(environment: environment)
            )
        }
        guard let cliPath = environment["ZENTTY_CLI_BIN"]?.nilIfBlank else {
            return AgentLaunchPlan(
                executablePath: executablePath,
                arguments: arguments,
                setEnvironment: ["ZENTTY_AGENT_TOOL": "muse"],
                unsetEnvironment: museInheritedOverlayKeys(environment: environment),
                preLaunchActions: []
            )
        }

        // Read the user's managed hooks before preparing the tool directory:
        // a nested launch inherits our own overlay path, which
        // prepareToolDirectory wipes.
        let settings = museUserSettings(environment: environment, fileManager: fileManager)
        let sourceObject = museSourceManagedHooksPath(environment: environment, settings: settings)
            .flatMap { museJSONObject(atPath: $0, fileManager: fileManager) }
            ?? [:]

        let overlayDirectoryURL = try prepareToolDirectory(
            toolID: AgentBootstrapTool.muse.id,
            target: target,
            runtimeDirectoryURL: runtimeDirectoryURL,
            fileManager: fileManager
        )
        let hooksURL = overlayDirectoryURL.appendingPathComponent("managed-hooks.json", isDirectory: false)
        let hooksObject = museManagedHooksObject(mergingInto: sourceObject, cliPath: cliPath)
        try JSONSerialization.data(withJSONObject: hooksObject, options: [.prettyPrinted, .sortedKeys])
            .write(to: hooksURL, options: .atomic)

        let (forwardedArguments, userAllowlist) = extractMuseHookEnvAllowlist(arguments)
        let configuredAllowlist = (settings["managed_hooks_env_vars"] as? [String]) ?? []
        var allowlist: [String] = []
        for name in configuredAllowlist + userAllowlist + museHookEnvironmentKeys where !allowlist.contains(name) {
            allowlist.append(name)
        }
        let allowlistArgument = "managed_hooks_env_vars=" + String(
            decoding: try compactJSONData(allowlist),
            as: UTF8.self
        )

        return AgentLaunchPlan(
            executablePath: executablePath,
            arguments: museArguments(forwardedArguments, inserting: ["-c", allowlistArgument]),
            setEnvironment: [
                "ZENTTY_AGENT_TOOL": "muse",
                museManagedHooksPathKey: hooksURL.path,
            ],
            unsetEnvironment: [],
            preLaunchActions: []
        )
    }

    /// A launch without our hooks must still shed an overlay path inherited
    /// from a parent Zentty-launched `muse`; a user-set path stays.
    static func museInheritedOverlayKeys(environment: [String: String]) -> [String] {
        guard let inherited = environment[museManagedHooksPathKey]?.nilIfBlank,
              isZenttyRuntimeHomePath(inherited) else {
            return []
        }
        return [museManagedHooksPathKey]
    }

    /// `-c` is a root option for the TUI and `resume` (accepted on either side
    /// of the subcommand), but `exec` only takes it after the subcommand.
    static func museArguments(_ arguments: [String], inserting inserted: [String]) -> [String] {
        if arguments.first == "exec" {
            return ["exec"] + inserted + arguments.dropFirst()
        }
        return inserted + arguments
    }

    /// Consumes a user-supplied `-c managed_hooks_env_vars=[...]` so its names
    /// can join ours: Muse refuses a run that sets one key twice.
    static func extractMuseHookEnvAllowlist(_ arguments: [String]) -> (forwardedArguments: [String], names: [String]) {
        let prefix = "managed_hooks_env_vars="
        var forwarded: [String] = []
        var names: [String] = []
        var index = arguments.startIndex

        func parsedNames(_ assignment: String) -> [String]? {
            guard assignment.hasPrefix(prefix),
                  let data = assignment.dropFirst(prefix.count).data(using: .utf8),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [String] else {
                return nil
            }
            return values
        }

        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--" {
                forwarded.append(contentsOf: arguments[index...])
                break
            }
            if argument == "-c" || argument == "--config",
               index + 1 < arguments.endIndex,
               let values = parsedNames(arguments[index + 1]) {
                names.append(contentsOf: values)
                index += 2
                continue
            }
            if argument.hasPrefix("--config="),
               let values = parsedNames(String(argument.dropFirst("--config=".count))) {
                names.append(contentsOf: values)
                index += 1
                continue
            }
            forwarded.append(argument)
            index += 1
        }
        return (forwarded, names)
    }

    private static func museManagedHooksObject(mergingInto source: [String: Any], cliPath: String) -> [String: Any] {
        var object = source
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        let command = museHookCommand(cliPath: cliPath)
        for spec in museHookSpecs {
            var groups = hooks[spec.event] as? [[String: Any]] ?? []
            let alreadyPresent = groups.contains { group in
                let nestedHooks = group["hooks"] as? [[String: Any]] ?? []
                return nestedHooks.contains { ($0["command"] as? String) == command }
            }
            if !alreadyPresent {
                var handler: [String: Any] = [
                    "type": "command",
                    "command": command,
                    "timeout": spec.timeout,
                ]
                if spec.isAsync {
                    handler["async"] = true
                }
                groups.append(["matcher": "", "hooks": [handler]])
            }
            hooks[spec.event] = groups
        }
        object["hooks"] = hooks
        return object
    }

    static func museHookCommand(cliPath: String) -> String {
        "\"\(shellEscapedDoubleQuoted(cliPath))\" ipc agent-event --adapter=muse"
    }

    /// The managed hooks file Muse would load without us: the env var wins
    /// over `settings.json`. An inherited Zentty overlay (a nested launch) is
    /// never a source; the settings path is then the best remaining answer.
    private static func museSourceManagedHooksPath(
        environment: [String: String],
        settings: [String: Any]
    ) -> String? {
        if let path = environment[museManagedHooksPathKey]?.nilIfBlank,
           !isZenttyRuntimeHomePath(path) {
            return path
        }
        return (settings["managed_hooks_path"] as? String)?.nilIfBlank.map {
            museExpandingHome(in: $0, environment: environment)
        }
    }

    /// Settings paths may start with `~` or `$HOME` (env-var paths arrive
    /// already expanded by the shell).
    private static func museExpandingHome(in path: String, environment: [String: String]) -> String {
        let home = environment["HOME"]?.nilIfBlank ?? NSHomeDirectory()
        for prefix in ["~/", "$HOME/", "${HOME}/"] where path.hasPrefix(prefix) {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(String(path.dropFirst(prefix.count)))
                .path
        }
        return path
    }

    private static func museUserSettings(environment: [String: String], fileManager: FileManager) -> [String: Any] {
        let configHome = environment["XDG_CONFIG_HOME"]?.nilIfBlank
            ?? URL(fileURLWithPath: environment["HOME"]?.nilIfBlank ?? NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".config", isDirectory: true)
                .path
        let path = URL(fileURLWithPath: configHome, isDirectory: true)
            .appendingPathComponent("muse", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
            .path
        return museJSONObject(atPath: path, fileManager: fileManager) ?? [:]
    }

    private static func museJSONObject(atPath path: String, fileManager: FileManager) -> [String: Any]? {
        guard fileManager.isReadableFile(atPath: path),
              let data = fileManager.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
