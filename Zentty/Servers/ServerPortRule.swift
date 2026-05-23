import Foundation

/// An inclusive TCP port range used to suppress detected dev servers.
///
/// Backs the user-facing `server_detection.ignored_port_rules` config, whose
/// canonical strings are bare ports (`"9229"`) or inclusive ranges
/// (`"24678-24680"`).
struct ServerPortRule: Equatable, Sendable, Comparable {
    let lowerBound: Int
    let upperBound: Int

    /// Valid TCP port range. Mirrors the bound enforced by `ServerURLNormalizer`.
    static let validPorts = 1...65535

    init?(lowerBound: Int, upperBound: Int) {
        guard Self.validPorts.contains(lowerBound),
              Self.validPorts.contains(upperBound),
              lowerBound <= upperBound else {
            return nil
        }
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    func contains(_ port: Int) -> Bool {
        (lowerBound...upperBound).contains(port)
    }

    /// Canonical config string: a bare port when single, else `"lower-upper"`.
    var canonicalString: String {
        lowerBound == upperBound ? "\(lowerBound)" : "\(lowerBound)-\(upperBound)"
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.lowerBound != rhs.lowerBound
            ? lhs.lowerBound < rhs.lowerBound
            : lhs.upperBound < rhs.upperBound
    }
}

extension ServerPortRule {
    /// Parses one rule string. Returns `nil` for non-numeric input, out-of-range
    /// ports, or reversed ranges (e.g. `"5000-4000"`).
    static func parse(_ rawValue: String) -> ServerPortRule? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let port = Int(trimmed) {
            return ServerPortRule(lowerBound: port, upperBound: port)
        }

        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let lower = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let upper = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return ServerPortRule(lowerBound: lower, upperBound: upper)
    }

    /// Parses raw rule strings into a sorted, merged rule set, dropping any
    /// invalid entries.
    static func normalize(_ rawValues: [String]) -> [ServerPortRule] {
        merge(rawValues.compactMap(parse))
    }

    /// Canonical config strings for a normalized rule set (sorted, merged,
    /// invalid entries dropped).
    static func canonicalStrings(_ rawValues: [String]) -> [String] {
        normalize(rawValues).map(\.canonicalString)
    }

    /// Removes a single port from the rule set, splitting any range that
    /// contained it. e.g. removing `3001` from `["3000-3002"]` → `["3000", "3002"]`.
    static func removingPort(_ port: Int, from rawValues: [String]) -> [String] {
        let split = normalize(rawValues).flatMap { rule -> [ServerPortRule] in
            guard rule.contains(port) else {
                return [rule]
            }
            return [
                ServerPortRule(lowerBound: rule.lowerBound, upperBound: port - 1),
                ServerPortRule(lowerBound: port + 1, upperBound: rule.upperBound),
            ].compactMap { $0 }
        }
        return merge(split).map(\.canonicalString)
    }

    /// Adds a single port, returning the merged canonical rule set.
    static func addingPort(_ port: Int, to rawValues: [String]) -> [String] {
        canonicalStrings(rawValues + [String(port)])
    }

    /// Sorts ascending and merges overlapping or adjacent ranges.
    private static func merge(_ rules: [ServerPortRule]) -> [ServerPortRule] {
        var merged: [ServerPortRule] = []
        for rule in rules.sorted() {
            guard let last = merged.last, rule.lowerBound <= last.upperBound + 1 else {
                merged.append(rule)
                continue
            }
            if rule.upperBound > last.upperBound,
               let extended = ServerPortRule(lowerBound: last.lowerBound, upperBound: rule.upperBound) {
                merged[merged.count - 1] = extended
            }
        }
        return merged
    }
}
