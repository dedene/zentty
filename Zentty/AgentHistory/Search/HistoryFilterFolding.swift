import Foundation

/// The one case folding behind the case-insensitive `repo:` (basename) and `branch:` filters.
///
/// Both search tiers go through it: the metadata tier in Swift, the content tier through the
/// SQL functions `AgentHistorySQLFunctions` registers on every index connection. SQLite's own
/// `lower()` and `LIKE` fold ASCII only, so `branch:féature` would miss `FÉATURE` there while
/// the metadata tier matched it.
///
/// Folded text is Unicode-lowercased, then put in canonical composition (NFC), so canonically
/// equivalent spellings (`é` vs `e` + U+0301) fold to the same bytes. Equality and `contains`
/// over folded text are then plain byte comparisons, exactly what SQL `=` and `instr` do.
enum HistoryFilterFolding {
    static func fold(_ value: String) -> String {
        // ASCII stays ASCII under both steps; skip the Foundation round trip for it (the SQL
        // function runs this once per candidate row).
        if value.utf8.allSatisfy({ $0 < 0x80 }) {
            return value.lowercased()
        }
        return value.lowercased().precomposedStringWithCanonicalMapping
    }

    /// The folded last path component of `path`; nil for nil, empty or `/`.
    static func foldedBasename(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : fold(name)
    }

    /// Whether folded `haystack` contains folded `needle`, byte for byte (like SQL `instr`).
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        if needle.isEmpty { return true }
        var haystack = haystack
        var needle = needle
        return haystack.withUTF8 { hay in
            needle.withUTF8 { pin in
                guard pin.count <= hay.count else { return false }
                let first = pin[0]
                var start = 0
                let last = hay.count - pin.count
                while start <= last {
                    if hay[start] == first, memcmp(hay.baseAddress! + start, pin.baseAddress!, pin.count) == 0 {
                        return true
                    }
                    start += 1
                }
                return false
            }
        }
    }
}
