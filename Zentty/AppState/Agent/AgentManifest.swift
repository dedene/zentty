import Foundation

/// A declarative description of a supported agent CLI, loaded from `agents/*.json`
/// resource files. Manifest agents reuse the OpenCode-family integration seam
/// (config overlay + plugin) or launch as plain "canonical" tools.
struct AgentManifest: Codable, Equatable, Sendable {
    enum Family: String, Codable, Sendable {
        case canonical
        case opencodePlugin = "opencode-plugin"
    }

    struct Passthrough: Codable, Equatable, Sendable {
        var subcommands: [String] = []
        var flags: [String] = []

        init(subcommands: [String] = [], flags: [String] = []) {
            self.subcommands = subcommands
            self.flags = flags
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            subcommands = try container.decodeIfPresent([String].self, forKey: .subcommands) ?? []
            flags = try container.decodeIfPresent([String].self, forKey: .flags) ?? []
        }
    }

    struct Resume: Codable, Equatable, Sendable {
        /// Command template supporting `{sessionId}` and/or `{workingDirectory}`.
        var command: String
        var sessionIdPattern: String?
    }

    struct OpenCodePluginOptions: Codable, Equatable, Sendable {
        /// "KILO" -> KILO_CONFIG_DIR, KILO_TUI_CONFIG, ZENTTY_KILO_BASE_CONFIG_DIR.
        var envPrefix: String
        /// "kilo" -> ~/.config/kilo, xdg-config-home/kilo, xdg-state-home/kilo.
        var configDirName: String
        /// ".kilo" (the `.opencode` sibling-binary trick).
        var siblingBinary: String?
    }

    struct CanonicalOptions: Codable, Equatable, Sendable {
        /// Values may contain `{cliBin}`.
        var env: [String: String] = [:]
        /// May contain `{cliBin}`.
        var prependArguments: [String] = []

        init(env: [String: String] = [:], prependArguments: [String] = []) {
            self.env = env
            self.prependArguments = prependArguments
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
            prependArguments = try container.decodeIfPresent([String].self, forKey: .prependArguments) ?? []
        }
    }

    var schemaVersion: Int
    var id: String
    var displayName: String
    var binaries: [String]
    var family: Family
    var opencodePlugin: OpenCodePluginOptions?
    var canonical: CanonicalOptions?
    var passthrough: Passthrough?
    var resume: Resume?
    /// Fork command, same template shape as `resume`. Only `{sessionId}`
    /// templates fork: a fork needs the exact conversation to branch from.
    var fork: Resume?
    /// Asset catalog image name, optional.
    var icon: String?

    init(
        schemaVersion: Int,
        id: String,
        displayName: String,
        binaries: [String],
        family: Family,
        opencodePlugin: OpenCodePluginOptions? = nil,
        canonical: CanonicalOptions? = nil,
        passthrough: Passthrough? = nil,
        resume: Resume? = nil,
        fork: Resume? = nil,
        icon: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.binaries = binaries
        self.family = family
        self.opencodePlugin = opencodePlugin
        self.canonical = canonical
        self.passthrough = passthrough
        self.resume = resume
        self.fork = fork
        self.icon = icon
    }
}

extension AgentManifest {
    static let supportedSchemaVersion = 1

    /// First validation failure, or nil when the manifest is usable.
    func validationError() -> String? {
        guard schemaVersion == Self.supportedSchemaVersion else {
            return "unsupported schemaVersion \(schemaVersion)"
        }
        guard Self.isValidID(id) else {
            return "invalid id '\(id)'"
        }
        guard !AgentBootstrapTool.isBuiltinID(id) else {
            return "id '\(id)' collides with a builtin agent"
        }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "empty displayName"
        }
        guard !displayName.contains(";"), !displayName.contains("="), !displayName.contains(",") else {
            return "displayName contains a reserved character"
        }
        guard !AgentTool.builtinDisplayNames.contains(displayName) else {
            return "displayName '\(displayName)' collides with a builtin agent"
        }
        guard !binaries.isEmpty else {
            return "empty binaries"
        }
        for binary in binaries where binary.contains(";") || binary.contains("=") || binary.contains(",") {
            return "binary '\(binary)' contains a reserved character"
        }
        switch family {
        case .canonical:
            break
        case .opencodePlugin:
            guard opencodePlugin != nil else {
                return "family 'opencode-plugin' requires opencodePlugin options"
            }
        }
        return nil
    }

    private static func isValidID(_ id: String) -> Bool {
        guard let first = id.first, first.isLowercaseASCIIOrDigit else { return false }
        return id.allSatisfy { $0.isLowercaseASCIIOrDigit || $0 == "-" }
    }
}

private extension Character {
    var isLowercaseASCIIOrDigit: Bool {
        ("a"..."z").contains(self) || ("0"..."9").contains(self)
    }
}
