import Foundation

// MARK: - Vibe Adapter

extension AgentEventBridge {
    static func vibeAdapter(
        data: Data,
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        let jsonObject = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])

        // Only emit status when the agent runs inside a known Zentty pane;
        // outside that context there is nothing to attribute events to.
        guard currentTargetIfAvailable(from: environment) != nil else {
            return []
        }

        // Already-canonical Agent Status Protocol envelopes are forwarded
        // straight through the shared pipeline. The most important one is the
        // `session.start` the launch bootstrap pre-sends (Vibe has no
        // session-start hook of its own); without this passthrough that
        // envelope is rejected and no Vibe session is ever created. These
        // envelopes carry `version`/`event`, not a raw `hook_event_name`.
        if (jsonObject["version"] as? Int) == 1,
           let eventName = jsonObject["event"] as? String, !eventName.isEmpty {
            let input = try parseInput(data)
            return try makePayloads(from: input, environment: environment)
        }

        // Otherwise this is a raw Vibe hook payload. Translate it into canonical
        // envelopes and run each through the shared makePayloads pipeline. No
        // fallback is needed: every handled event yields at least one canonical
        // envelope, and unknown events are intentionally dropped.
        guard jsonObject["hook_event_name"] is String else {
            throw AgentStatusPayloadError.invalidHookPayload
        }
        let canonicalPayloads = VibeCanonicalReEmitter.canonicalPayloads(from: jsonObject)
        var payloads: [AgentStatusPayload] = []
        for canonicalPayload in canonicalPayloads {
            let input = try parseInput(try JSONSerialization.data(withJSONObject: canonicalPayload))
            payloads.append(contentsOf: try makePayloads(from: input, environment: environment))
        }
        return payloads
    }

}
