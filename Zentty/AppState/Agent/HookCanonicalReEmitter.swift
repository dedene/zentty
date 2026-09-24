import Foundation

/// Re-emits canonical Agent Status Protocol events derived from a raw agent
/// hook payload. Conformers are stateless types whose only responsibility is
/// to inspect a single payload and return zero or more canonical JSON envelopes
/// that the CLI fan-out logic should additionally send.
///
/// Today only Grok needs this — the bench profile expects discrete
/// `task.progress`, `agent.needs-input`, and `session.start` records, and
/// `GrokCanonicalReEmitter` mints them in Swift. The protocol exists so the
/// CLI's fan-out site is generic: any future agent that needs the same
/// treatment registers a conformance and adds itself to the registry below.
protocol HookCanonicalReEmitter: Sendable {
    /// Canonical JSON envelopes to additionally send, one IPC request per
    /// element. Empty when the payload contains nothing worth re-emitting (or
    /// is already canonical itself).
    static func reEmissions(forHookPayload data: Data) -> [String]
}

/// Maps the value of a `--adapter=<name>` CLI flag to the appropriate
/// `HookCanonicalReEmitter`. Adding a new agent is a single-line change here.
enum HookCanonicalReEmitterRegistry {
    static let reEmitters: [String: any HookCanonicalReEmitter.Type] = [
        "grok": GrokCanonicalReEmitter.self,
        "agy": AgyCanonicalReEmitter.self,
        // Vibe deliberately has no CLI fan-out entry: the app-side
        // `vibeAdapter` (VibeCanonicalReEmitter) is the single source of
        // canonical Vibe status, so a re-emitter here would double-emit.
    ]

    /// Returns the re-emitter registered for the adapter encoded in `arg`
    /// (expected form: `--adapter=<name>`). Returns `nil` for unknown adapters
    /// or arguments that aren't the adapter flag.
    static func reEmitter(forAdapterArgument arg: String) -> (any HookCanonicalReEmitter.Type)? {
        guard let name = adapterName(from: arg) else { return nil }
        return reEmitters[name]
    }

    /// First re-emitter resolved from any `--adapter=<name>` argument in the
    /// list. Returns `nil` when no `--adapter=<name>` argument is present or
    /// the named adapter has no registered re-emitter.
    static func reEmitter(forArguments arguments: [String]) -> (any HookCanonicalReEmitter.Type)? {
        for arg in arguments {
            if let reEmitter = reEmitter(forAdapterArgument: arg) {
                return reEmitter
            }
        }
        return nil
    }

    private static func adapterName(from arg: String) -> String? {
        guard arg.hasPrefix("--adapter=") else { return nil }
        let name = String(arg.dropFirst("--adapter=".count))
        return name.isEmpty ? nil : name
    }
}

/// Context returned to the owning agent through its command hook's stdout.
/// Kept separate from IPC status events: only these two lifecycle hooks accept
/// context in both Claude and Codex, including SessionStart(source: compact).
enum AgentPaneTitleHook {
    static func response(arguments: [String], standardInput: String?, environment: [String: String]) -> String? {
        guard environment["ZENTTY_AUTO_PANE_TITLES"] == "1",
              arguments.contains("--adapter=claude") || arguments.contains("--adapter=codex"),
              let standardInput,
              let data = standardInput.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = payload["hook_event_name"] as? String,
              event == "SessionStart" || event == "UserPromptSubmit",
              JSONKeyAccess.firstString(in: payload, keys: ["agent_id", "agentId"]) == nil else {
            return nil
        }

        // Do not interpolate prompts or paths into instructions or shell code.
        // The agent already has its current task and project in context.
        let context = """
        Zentty pane title: at the start of this run, once the current task is known, \
        rename your own pane to "Project — current task". Use the actual current \
        project name as the prefix, or the working-folder name if no project is known, \
        and a concise task description (about 3–8 words). Replace any existing title, \
        including a manually renamed title. Refresh it when the task, topic, or project \
        meaningfully changes during the run, and after resuming or compacting context. \
        Run `"$ZENTTY_CLI_BIN" pane rename -- 'Project — current task' >/dev/null 2>&1 || true`, \
        replacing the example with one safely shell-quoted literal title argument \
        (escape embedded quotes; never interpolate raw user text into shell code). \
        Omit pane/worklane selectors so the command targets only your own pane. \
        Do this without asking for confirmation; a rename failure must not interrupt \
        the user's task. Only the top-level agent that owns this pane should rename it; \
        delegated subagents must not rename their parent's pane.
        """
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": event,
                "additionalContext": context,
            ],
        ]
        guard let outputData = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: outputData, encoding: .utf8)
    }
}
