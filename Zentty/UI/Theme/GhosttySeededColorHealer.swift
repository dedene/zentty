import Foundation

/// Removes the explicit color block that historic Zentty builds copied verbatim into a
/// user's shared Ghostty config when seeding `~/.config/ghostty/config.ghostty`.
///
/// Ghostty resolves `theme = <name>` by loading the theme's colors first, then letting any
/// explicit color keys in the config override them — regardless of line order. So a config
/// that still carries the seeded `background`, `foreground`, `cursor-color`, selection, and
/// `palette` lines has its colors permanently frozen: switching `theme` silently does
/// nothing because the explicit keys always win (see ghostty issue #50). Zentty's own theme
/// rewrites only touch the `theme` line, so the poison persists across theme changes.
///
/// Healing is gated on block-wide evidence: it acts only when *all 21* lines of the one
/// seeded block Zentty ever shipped are present (keys exact, hex values case-insensitive).
/// The complete block is the safe fingerprint of leftover Zentty seeding — a partial match
/// could be colors the user authored themselves that merely share a value, so a single
/// missing line means "not our block, do nothing". Once the full block is confirmed, only
/// the exact-matching lines are stripped; user-added color lines with different values stay.
/// `background-opacity` is never a color key and is never removed.
enum GhosttySeededColorHealer {
    /// The one explicit color block ever seeded by Zentty, verbatim. Keys are matched
    /// exactly; hex values are matched case-insensitively so a re-cased copy still heals.
    private static let historicSeededColorLines: [String] = [
        "background = #0A0C10",
        "foreground = #F0F3F6",
        "cursor-color = #71B7FF",
        "selection-background = #F0F3F6",
        "selection-foreground = #0A0C10",
        "palette = 0=#7A828E",
        "palette = 1=#FF9492",
        "palette = 2=#26CD4D",
        "palette = 3=#FFE073",
        "palette = 4=#71B7FF",
        "palette = 5=#CB9EFF",
        "palette = 6=#24EAF7",
        "palette = 7=#D9DEE3",
        "palette = 8=#9EA7B3",
        "palette = 9=#FFB1AF",
        "palette = 10=#4AE168",
        "palette = 11=#FFE073",
        "palette = 12=#91CBFF",
        "palette = 13=#DBB7FF",
        "palette = 14=#56D4DD",
        "palette = 15=#FFFFFF",
    ]

    /// Normalized `key\u{0}lowercased-value` set of the historic block for O(1) matching.
    private static let historicSeededEntries: Set<String> = Set(
        historicSeededColorLines.compactMap(normalizedEntry(for:))
    )

    /// Returns the config with the seeded color block removed, or `nil` when there is
    /// nothing to heal.
    ///
    /// Heals only when the config both declares a theme (a non-comment `theme =` line) and
    /// carries the *entire* historic seeded block — every one of the 21 normalized entries
    /// must appear. If even one is missing the block is treated as user-authored (values may
    /// coincide) and `nil` is returned so the caller skips rewriting. When the full block is
    /// confirmed, only the exact-matching lines are stripped; every other line — comments,
    /// other settings, user-authored colors with different values, ordering, and trailing-
    /// newline behavior — is preserved byte-for-byte.
    static func strippingSeededColors(from content: String) -> String? {
        guard containsThemeLine(content) else {
            return nil
        }

        let lines = content.components(separatedBy: "\n")

        // Require the complete block: every historic entry must be present before we remove
        // anything, so a coincidental single-value match never costs the user a color line.
        let presentEntries = Set(lines.compactMap(normalizedEntry(for:)))
        guard historicSeededEntries.isSubset(of: presentEntries) else {
            return nil
        }

        let healedLines = lines.filter { !matchesHistoricSeededLine($0) }
        return healedLines.joined(separator: "\n")
    }

    private static func containsThemeLine(_ content: String) -> Bool {
        content.components(separatedBy: "\n").contains { line in
            guard let (key, _) = keyValue(for: line) else {
                return false
            }
            return key == "theme"
        }
    }

    private static func matchesHistoricSeededLine(_ line: String) -> Bool {
        guard let entry = normalizedEntry(for: line) else {
            return false
        }
        return historicSeededEntries.contains(entry)
    }

    /// Splits a config line into its trimmed key/value, skipping comments and non-assignments.
    private static func keyValue(for line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//") else {
            return nil
        }

        let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return nil
        }

        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            return nil
        }
        return (key, value)
    }

    /// Normalizes a line to `key\u{0}lowercased-value`; key stays case-sensitive, value is
    /// lowercased so hex casing does not defeat the match.
    private static func normalizedEntry(for line: String) -> String? {
        guard let (key, value) = keyValue(for: line) else {
            return nil
        }
        return "\(key)\u{0}\(value.lowercased())"
    }
}
