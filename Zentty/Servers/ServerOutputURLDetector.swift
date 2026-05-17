import Foundation

enum ServerOutputURLDetector {
    static func detect(in text: String) -> [ServerURLCandidate] {
        let matches = urlMatches(in: text)
            .compactMap { rawURL -> ServerURLCandidate? in
                try? ServerURLNormalizer.normalize(rawURL)
            }

        var seenOrigins: Set<String> = []
        let unique = matches.filter { candidate in
            seenOrigins.insert(candidate.origin).inserted
        }

        return unique.sorted(by: preferredCandidateAscending)
    }

    private static func urlMatches(in text: String) -> [String] {
        let pattern = #"https?://[^\s<>"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else {
                return nil
            }
            return trimTrailingPunctuation(String(text[matchRange]))
        }
    }

    private static func trimTrailingPunctuation(_ rawURL: String) -> String {
        var value = rawURL
        while let last = value.last, trailingPunctuation.contains(last) {
            value.removeLast()
        }
        return value
    }

    private static func preferredCandidateAscending(_ lhs: ServerURLCandidate, _ rhs: ServerURLCandidate) -> Bool {
        if lhs.port != rhs.port {
            return lhs.port < rhs.port
        }

        let lhsRank = hostPreferenceRank(lhs.url.host)
        let rhsRank = hostPreferenceRank(rhs.url.host)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }

        return lhs.origin < rhs.origin
    }

    private static func hostPreferenceRank(_ host: String?) -> Int {
        guard let host = host?.lowercased() else {
            return 3
        }

        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return 0
        }
        if host.hasPrefix("127.") {
            return 1
        }
        return 2
    }

    private static let trailingPunctuation = Set<Character>([".", ",", ";", ":", ")", "]", "}"])
}
