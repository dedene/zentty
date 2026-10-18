import ArgumentParser
import Darwin
import Foundation

/// `zentty launch --teams <agent>` and `zentty launch --tmux-shim [command]`:
/// start a process that sees itself inside tmux, with Zentty's tmux shim
/// first on `PATH`, so a tmux-based orchestrator opens its teammates as
/// Zentty panes. Nothing is installed; the environment only applies to the
/// launched process tree.
struct TmuxShimLauncher {
    let environment: [String: String]

    func run(_ plan: TmuxShimEnvironment.LaunchPlan) throws -> Never {
        guard let shimDirectory = resolveShimDirectory() else {
            throw failure("Zentty's tmux shim was not found next to this zentty binary.")
        }
        let backend = TmuxCompatCLIBackend(environment: environment)
        guard let identity = backend.expandFormat(TmuxShimEnvironment.identityFormat, target: nil)
            .flatMap(TmuxShimEnvironment.parseIdentity) else {
            throw failure("zentty launch --teams/--tmux-shim must run inside a Zentty pane.")
        }
        let launchEnvironment = TmuxShimEnvironment.launchEnvironment(
            base: environment,
            shimDirectory: shimDirectory,
            identity: identity,
            enableClaudeAgentTeams: plan.enablesClaudeAgentTeams
        )

        switch plan.mode {
        case let .agent(toolID, arguments):
            guard let tool = AgentBootstrapTool(id: toolID) else {
                throw ValidationError("Unsupported launch tool: \(toolID)")
            }
            try AgentToolLauncher(tool: tool, arguments: arguments, environment: launchEnvironment).run()
            // AgentToolLauncher always execs; reaching here means it returned
            // without launching.
            throw ExitCode(1)
        case let .command(command):
            let argv = command.isEmpty ? loginShellCommand() : command
            try exec(argv, environment: launchEnvironment)
        }
    }

    /// The shim ships in the app bundle at `Resources/bin/tmux-shim`, next to
    /// the CLI's `Resources/bin/shared/zentty`.
    private func resolveShimDirectory() -> String? {
        var candidates: [String] = []
        if let fromEnvironment = environment[TmuxShimEnvironment.shimDirectoryKey], !fromEnvironment.isEmpty {
            candidates.append(fromEnvironment)
        }
        for cliPath in [environment["ZENTTY_CLI_BIN"], Bundle.main.executablePath, CommandLine.arguments.first].compactMap({ $0 }) {
            let resolved = URL(fileURLWithPath: cliPath).resolvingSymlinksInPath()
            candidates.append(
                resolved.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("tmux-shim", isDirectory: true)
                    .path
            )
        }
        return candidates.first { directory in
            FileManager.default.isExecutableFile(atPath: (directory as NSString).appendingPathComponent("tmux"))
        }
    }

    private func loginShellCommand() -> [String] {
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        return [shell, "-l"]
    }

    private func exec(_ argv: [String], environment: [String: String]) throws -> Never {
        guard let program = argv.first, let executable = resolveExecutable(program, path: environment["PATH"]) else {
            throw failure("command not found: \(argv.first ?? "")")
        }
        var cArguments = argv.map { strdup($0) }
        cArguments.append(nil)
        var cEnvironment = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnvironment.append(nil)
        execve(executable, &cArguments, &cEnvironment)
        let message = String(cString: strerror(errno))
        throw failure("failed to launch \(program): \(message)")
    }

    /// Runtime failures print one line and exit 1, without the usage text
    /// ArgumentParser adds to validation errors.
    private func failure(_ message: String) -> ExitCode {
        FileHandle.standardError.write(Data("zentty: \(message)\n".utf8))
        return ExitCode(1)
    }

    private func resolveExecutable(_ program: String, path: String?) -> String? {
        if program.contains("/") {
            return FileManager.default.isExecutableFile(atPath: program) ? program : nil
        }
        for directory in (path ?? "/usr/bin:/bin").split(separator: ":") {
            let candidate = (String(directory) as NSString).appendingPathComponent(program)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
