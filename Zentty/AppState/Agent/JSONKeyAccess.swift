import Foundation

/// Small pure-Foundation helpers for reading values out of `[String: Any]`
/// dictionaries deserialised from agent hook payloads. Lives in a standalone
/// file so it can be compiled into both the app target and the `ZenttyCLI`
/// tool target without dragging in `AgentStatusPayload` and the rest of the
/// state graph.
enum JSONKeyAccess {

    /// First non-empty string value found at any of the top-level `keys`.
    static func firstString(in object: [String: Any]?, keys: [String]) -> String? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    /// First non-empty string array found at any of the top-level `keys`.
    /// Accepts both `[String]` and heterogeneous `[Any]` shapes.
    static func firstStringArray(in object: [String: Any]?, keys: [String]) -> [String]? {
        guard let object else { return nil }
        for key in keys {
            if let values = object[key] as? [String] {
                let trimmedValues = values.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                if !trimmedValues.isEmpty {
                    return trimmedValues
                }
            }
            if let values = object[key] as? [Any] {
                let trimmedValues = values.compactMap { value -> String? in
                    guard let string = value as? String else { return nil }
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                if !trimmedValues.isEmpty {
                    return trimmedValues
                }
            }
        }
        return nil
    }

    /// First `Int` value found at any of the top-level `keys`. Accepts both
    /// `NSNumber` and `Int` (JSONSerialization emits `NSNumber` for numerics).
    static func firstInt(in object: [String: Any]?, keys: [String]) -> Int? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? NSNumber { return value.intValue }
            if let value = object[key] as? Int { return value }
        }
        return nil
    }

    /// First `Int32` value found at any of the top-level `keys`.
    static func firstInt32(in object: [String: Any]?, keys: [String]) -> Int32? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? NSNumber { return value.int32Value }
            if let value = object[key] as? Int { return Int32(value) }
        }
        return nil
    }

    /// First `[String: Any]` value found at any of the top-level `keys`.
    static func firstObject(in object: [String: Any]?, keys: [String]) -> [String: Any]? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? [String: Any] { return value }
        }
        return nil
    }

    /// Walks each nested key `path` (e.g. `["session", "id"]`) and returns the
    /// first non-empty string value found. Used when an agent nests its
    /// identifiers (Grok puts the session id under `session.id`,
    /// `context.session_id`, etc.) so we don't need to flatten payloads with
    /// `jq` or similar.
    static func firstStringPath(in object: [String: Any]?, paths: [[String]]) -> String? {
        guard let object else { return nil }
        for path in paths where !path.isEmpty {
            var current: Any? = object
            for segment in path {
                guard let dict = current as? [String: Any] else {
                    current = nil
                    break
                }
                current = dict[segment]
            }
            if let value = current as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}
