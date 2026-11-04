import Foundation

/// Best-effort secret scrubbing for everything Agent History stores (message text, artifacts,
/// titles). Matches are replaced with `‹redacted›`; the `Authorization: Bearer` rule keeps its
/// header prefix.
///
/// Each rule has literal "needles" checked first with a byte search; a regex runs only when one
/// of its needles occurs, so ordinary text costs a few `memmem` calls and returns unchanged.
/// Rules run in order (private keys first, the bearer header last), and the output never
/// contains a needle-bearing secret again, so `redact` is idempotent.
struct AgentHistoryRedactor: Sendable {
    static let replacement = "‹redacted›"
    static let shared = AgentHistoryRedactor()

    private let rules: AgentHistoryRedactionRules

    init() {
        rules = AgentHistoryRedactionRules()
    }

    /// True when the text contains a literal that one of the rules starts from. A false result
    /// guarantees `redact` returns the input unchanged.
    func mayContainSecret(_ text: String) -> Bool {
        !rules.candidateRuleIndices(in: text).isEmpty
    }

    func redact(_ text: String) -> String {
        let candidates = rules.candidateRuleIndices(in: text)
        guard !candidates.isEmpty else {
            return text
        }
        var result = text
        for index in candidates {
            result = rules.rules[index].apply(to: result)
        }
        return result
    }
}

/// The compiled rules. `NSRegularExpression` is immutable and documented as thread-safe once
/// created; nothing here mutates after `init`, which is why the class is `@unchecked Sendable`.
private final class AgentHistoryRedactionRules: @unchecked Sendable {
    struct Rule {
        let regex: NSRegularExpression
        /// Literal byte sequences; the rule runs only when one of them occurs.
        let needles: [[UInt8]]
        /// ASCII case-insensitive needle search (the bearer header).
        let caseInsensitiveNeedles: Bool
        let template: String

        func apply(to text: String) -> String {
            let range = NSRange(location: 0, length: (text as NSString).length)
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
        }
    }

    let rules: [Rule]

    init() {
        let replacement = NSRegularExpression.escapedTemplate(for: AgentHistoryRedactor.replacement)
        func rule(_ pattern: String, _ needles: [String], caseInsensitive: Bool = false, template: String? = nil) -> Rule? {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [])
                return Rule(
                    regex: regex,
                    needles: needles.map { Array($0.utf8) },
                    caseInsensitiveNeedles: caseInsensitive,
                    template: template ?? replacement
                )
            } catch {
                AgentHistoryLog.indexer.error("Redaction pattern failed to compile")
                return nil
            }
        }
        rules = [
            // PEM private keys, including a key cut off before its END line.
            rule(
                #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)"#,
                ["PRIVATE KEY-----"]
            ),
            // OpenAI / Anthropic style keys (`sk-…`, `sk-proj-…`, `sk-ant-…`).
            rule(#"\bsk-[A-Za-z0-9_-]{20,}"#, ["sk-"]),
            // GitHub tokens. The length applies to every prefix (the spec's alternation only
            // bound it to `github_pat_`).
            rule(
                #"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#,
                ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"]
            ),
            // Slack tokens.
            rule(#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, ["xox"]),
            // AWS access key ids (long-term and STS).
            rule(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, ["AKIA", "ASIA"]),
            // JWT-shaped tokens.
            rule(#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#, ["eyJ"]),
            // Google API keys.
            rule(#"AIza[0-9A-Za-z_-]{35}"#, ["AIza"]),
            // GitLab personal access tokens.
            rule(#"glpat-[A-Za-z0-9_-]{20,}"#, ["glpat-"]),
            // Stripe secret and restricted keys.
            rule(#"\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}"#, ["k_live_", "k_test_"]),
            // npm tokens.
            rule(#"\bnpm_[A-Za-z0-9]{36}"#, ["npm_"]),
            // `Authorization: Bearer <token>`: keep the header, drop the value.
            rule(
                #"(?i)(authorization:\s*bearer\s+)\S{16,}"#,
                ["bearer"],
                caseInsensitive: true,
                template: "$1" + replacement
            ),
        ].compactMap { $0 }
    }

    /// Indices (in rule order) of the rules whose needles occur in `text`.
    func candidateRuleIndices(in text: String) -> [Int] {
        guard !text.isEmpty else {
            return []
        }
        var text = text
        return text.withUTF8 { buffer -> [Int] in
            guard let base = buffer.baseAddress else {
                return []
            }
            var indices: [Int] = []
            for (index, rule) in rules.enumerated() where rule.needles.contains(where: { needle in
                rule.caseInsensitiveNeedles
                    ? Self.containsASCIICaseInsensitive(base, buffer.count, needle)
                    : Self.contains(base, buffer.count, needle)
            }) {
                indices.append(index)
            }
            return indices
        }
    }

    private static func contains(_ haystack: UnsafePointer<UInt8>, _ count: Int, _ needle: [UInt8]) -> Bool {
        guard needle.count <= count else {
            return false
        }
        return needle.withUnsafeBufferPointer { needleBuffer in
            memmem(haystack, count, needleBuffer.baseAddress, needleBuffer.count) != nil
        }
    }

    /// `needle` must be lowercase ASCII.
    private static func containsASCIICaseInsensitive(_ haystack: UnsafePointer<UInt8>, _ count: Int, _ needle: [UInt8]) -> Bool {
        guard let first = needle.first, needle.count <= count else {
            return false
        }
        let last = count - needle.count
        var position = 0
        while position <= last {
            if lowercased(haystack[position]) == first {
                var matched = true
                for offset in 1..<needle.count where lowercased(haystack[position + offset]) != needle[offset] {
                    matched = false
                    break
                }
                if matched {
                    return true
                }
            }
            position += 1
        }
        return false
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte | 0x20 : byte
    }
}
