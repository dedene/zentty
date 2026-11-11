import Foundation

enum TerminalOpenURLResolver {
    static let trailingPunctuation: Set<Character> = [".", ",", ";", ":"]

    /// Resolves the string libghostty hands us for an open-URL action into something NSWorkspace can open.
    /// Scheme URLs pass through untouched. Paths are expanded (~, ..), resolved against the pane's working
    /// directory when relative, and trailing sentence punctuation is stripped when the literal path does not exist.
    /// When no local file matches, a scheme-less web address such as `example.com/path` opens as https.
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

        if let webURL = bareWebURL(rawString) {
            return webURL
        }

        return URL(filePath: expandedPath(rawString, workingDirectory: workingDirectory))
    }

    /// Ghostty's link regex matches scheme-less web addresses as relative paths. Treat the target as
    /// https when its first segment is a dotted hostname with an alphabetic TLD and either a path,
    /// query or fragment follows or the host starts with `www.`. A bare `name.ext` stays a path,
    /// since file names and TLDs overlap (`README.md`).
    private static func bareWebURL(_ rawString: String) -> URL? {
        guard !rawString.contains(where: \.isWhitespace) else {
            return nil
        }

        let authorityEnd = rawString.firstIndex(where: { "/?#".contains($0) }) ?? rawString.endIndex
        let authority = rawString[..<authorityEnd]
        guard authorityEnd != rawString.endIndex || authority.lowercased().hasPrefix("www.") else {
            return nil
        }

        let labels = authority.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy(isHostLabel),
              let tld = labels.last,
              tld.count >= 2,
              tld.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return nil
        }

        guard let url = URL(string: "https://" + rawString), url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private static func isHostLabel(_ label: Substring) -> Bool {
        guard (1...63).contains(label.count), label.first != "-", label.last != "-" else {
            return false
        }
        return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
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
