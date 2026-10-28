import Foundation

enum TerminalOpenURLResolver {
    static let trailingPunctuation: Set<Character> = [".", ",", ";", ":"]

    /// Resolves the string libghostty hands us for an open-URL action into something NSWorkspace can open.
    /// Scheme URLs pass through untouched. Paths are expanded (~, ..), resolved against the pane's working
    /// directory when relative, and trailing sentence punctuation is stripped when the literal path does not exist.
    /// This only resolves; TerminalOpenURLPolicy decides whether the result may open.
    static func resolve(
        _ rawString: String,
        workingDirectory: String?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        if let url = URL(string: rawString), url.scheme != nil {
            return url
        }

        let candidates = pathCandidates(rawString)
        for candidate in candidates {
            let expanded = expandedPath(candidate, workingDirectory: workingDirectory)
            if fileExists(expanded) {
                return URL(filePath: expanded)
            }
        }

        return URL(filePath: expandedPath(rawString, workingDirectory: workingDirectory))
    }

    /// The raw string first, then variants with one trailing punctuation character stripped at a time.
    private static func pathCandidates(_ rawString: String) -> [String] {
        var candidates = [rawString]
        var current = rawString
        while let last = current.last, trailingPunctuation.contains(last) {
            current.removeLast()
            if current.isEmpty {
                break
            }
            candidates.append(current)
        }
        return candidates
    }

    private static func expandedPath(_ candidate: String, workingDirectory: String?) -> String {
        let expanded = NSString(string: candidate).standardizingPath
        if !expanded.hasPrefix("/"), let workingDirectory, !workingDirectory.isEmpty {
            let joined = NSString(string: workingDirectory).appendingPathComponent(candidate)
            return NSString(string: joined).standardizingPath
        }
        return expanded
    }
}
