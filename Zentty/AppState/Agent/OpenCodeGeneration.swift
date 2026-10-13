import Foundation
import os

private let openCodeGenerationLogger = Logger(subsystem: "be.zenjoy.zentty", category: "OpenCodeGeneration")

/// OpenCode ships two incompatible CLIs under the same `opencode` name:
/// v1 (`opencode-ai`, prints `1.18.35`) and v2 (`@opencode/cli`, prints
/// `opencode v2.0.26`). v2 rejects the v1 plugin module shape and, by default,
/// runs plugins in a shared detached background service whose environment
/// belongs to whichever process started it first, not to the launching pane.
enum OpenCodeGeneration: Equatable {
    case v1
    case v2

    /// Bundle resource directory (under `opencode/`) holding this generation's plugin.
    var pluginResourceDirectoryName: String {
        switch self {
        case .v1: "plugins"
        case .v2: "v2-plugins"
        }
    }

    static func parse(versionOutput: String) -> OpenCodeGeneration? {
        let text = KimiVariantProbe.strippingANSISequences(from: versionOutput)
        guard let range = text.range(of: #"\d+\.\d+"#, options: .regularExpression),
              let major = Int(text[range].split(separator: ".")[0]) else {
            return nil
        }
        return major >= 2 ? .v2 : .v1
    }

    /// Subcommands that start an agent session against a server. Only these
    /// accept `--standalone`; utility subcommands (`auth`, `models`, …) are
    /// left alone.
    private static let sessionSubcommands: Set<String> = ["run", "mini"]
    private static let knownSubcommands: Set<String> = [
        "upgrade", "update", "uninstall", "acp", "api", "debug", "auth", "mcp", "plugin",
        "models", "stats", "mini", "run", "session", "service", "reload", "pair", "serve",
    ]
    private static let rootFlagsWithValue: Set<String> = [
        "--session", "-s", "--prompt", "--server", "--log-level", "--completions",
    ]

    /// v2 plugins must run in a server that inherits the pane environment, so
    /// session launches get a private (`--standalone`) server unless the user
    /// already picked a server mode.
    static func standaloneArguments(_ arguments: [String]) -> [String] {
        let pinsServerMode = arguments.contains { argument in
            argument == "--standalone" || argument == "--server" || argument.hasPrefix("--server=")
        }
        let asksForInfo = arguments.contains { ["--help", "-h", "--version", "-v"].contains($0) }
        guard !pinsServerMode, !asksForInfo else {
            return arguments
        }

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                break
            }
            if argument.hasPrefix("-") {
                index += rootFlagsWithValue.contains(argument) ? 2 : 1
                continue
            }
            guard knownSubcommands.contains(argument) else {
                break
            }
            guard sessionSubcommands.contains(argument) else {
                return arguments
            }
            var result = arguments
            result.insert("--standalone", at: index + 1)
            return result
        }
        return ["--standalone"] + arguments
    }
}

enum OpenCodeGenerationProbe {
    private static let cache = Cache()

    /// Probes `<executable> --version`. Cached per resolved binary and its
    /// modification date, so swapping the install behind a stable path (npm
    /// relinking `opencode` from `opencode-ai` to `@opencode/cli`) re-probes.
    /// Falls back to v1, the long-standing integration, when the probe fails.
    static func generation(executablePath: String, environment: [String: String]) -> OpenCodeGeneration {
        let resolvedPath = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        let modified = (try? FileManager.default.attributesOfItem(atPath: resolvedPath)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let cacheKey = "\(resolvedPath)@\(modified)"
        if let cached = cache.value(for: cacheKey) {
            return cached
        }

        var probeEnvironment = environment
        probeEnvironment["NO_COLOR"] = "1"
        probeEnvironment["TERM"] = "dumb"

        do {
            let result = try SubprocessRunner.run(
                executableURL: URL(fileURLWithPath: executablePath),
                arguments: ["--version"],
                environment: probeEnvironment,
                timeout: 10
            )
            let output = String(data: result.stdout + result.stderr, encoding: .utf8) ?? ""
            guard result.terminationStatus == 0, let generation = OpenCodeGeneration.parse(versionOutput: output) else {
                openCodeGenerationLogger.warning(
                    "OpenCode version probe gave no version (status \(result.terminationStatus, privacy: .public)) for \(executablePath, privacy: .public)"
                )
                return .v1
            }
            cache.store(generation, for: cacheKey)
            return generation
        } catch {
            openCodeGenerationLogger.warning(
                "OpenCode version probe failed for \(executablePath, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return .v1
        }
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var values = [String: OpenCodeGeneration]()

        func value(for key: String) -> OpenCodeGeneration? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }

        func store(_ value: OpenCodeGeneration, for key: String) {
            lock.lock()
            values[key] = value
            lock.unlock()
        }
    }
}
