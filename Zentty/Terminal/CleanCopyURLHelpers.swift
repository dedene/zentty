import Foundation

extension CleanCopyPipeline {
    static func repairWrappedURL(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let schemeCount = (lowercased.components(separatedBy: "https://").count - 1)
            + (lowercased.components(separatedBy: "http://").count - 1)
        guard schemeCount == 1 else { return nil }
        guard lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") else { return nil }

        // Only repair when every line is exclusively part of the wrapped URL (no internal
        // whitespace once trimmed). Otherwise a URL followed by a prose sentence would have
        // its inter-word spaces deleted along with the wrap newlines, fusing the prose together.
        let lines = trimmed.components(separatedBy: "\n")
        guard lines.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).contains(where: \.isWhitespace) })
        else { return nil }

        let collapsed = trimmed.replacingOccurrences(
            of: #"\s+"#,
            with: "",
            options: .regularExpression
        )
        guard collapsed != trimmed else { return nil }

        let validURLPattern = #"^https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+$"#
        guard collapsed.range(of: validURLPattern, options: .regularExpression) != nil else { return nil }
        return collapsed
    }

    static func stripURLTrackingParameters(_ input: String, enabled: Bool) -> String? {
        guard enabled else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n") else { return nil }
        let lowered = trimmed.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return nil }
        guard var components = URLComponents(string: trimmed) else { return nil }
        let original = components.percentEncodedQueryItems ?? []
        guard !original.isEmpty else { return nil }

        let rule = URLQueryParamRules.rule(for: components.host ?? "", in: URLQueryParamRules.builtIn)
        let filtered = original.filter { item in
            let normalizedName = item.name.lowercased()
            let ruleStripsParam = rule?.stripParams.contains {
                $0.lowercased() == normalizedName
            } ?? false
            return !URLQueryParamRules.isKnownTrackingParam(normalizedName)
                && !ruleStripsParam
        }
        guard filtered.count < original.count else { return nil }
        components.percentEncodedQueryItems = filtered.isEmpty ? nil : filtered

        guard let stripped = components.url?.absoluteString else { return nil }
        return stripped == trimmed ? nil : stripped
    }

    static func quotePathWithSpaces(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'"))
        {
            return nil
        }
        guard let firstToken = trimmed.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: \.isWhitespace
        ).first else { return nil }
        let firstTokenText = String(firstToken)
        guard !trimmed.contains("://") else { return nil }

        let hasExplicitPathPrefix = firstTokenText.hasPrefix("/")
            || firstTokenText.hasPrefix("~/")
            || firstTokenText.hasPrefix("./")
            || firstTokenText.hasPrefix("../")
        let slashCount = firstTokenText.filter { $0 == "/" }.count
        let looksLikeRelativePath = slashCount >= 2
        guard hasExplicitPathPrefix || looksLikeRelativePath else { return nil }
        guard trimmed.contains(" ") else { return nil }

        if trimmed.range(of: #"^/[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)?\s"#, options: .regularExpression) != nil {
            return nil
        }
        if trimmed.range(of: #"\s--?[A-Za-z]"#, options: .regularExpression) != nil {
            return nil
        }

        // Reject sentence-shaped input: a trailing '.'/'?'/'!' reads as end-of-sentence
        // punctuation rather than part of a filename, unless it's a short file-extension-like
        // suffix (e.g. "report.pdf").
        if let lastCharacter = trimmed.last, ".?!".contains(lastCharacter) {
            let endsWithExtension = trimmed.range(
                of: #"\.[A-Za-z0-9]{1,5}$"#,
                options: .regularExpression
            ) != nil
            guard lastCharacter == "." && endsWithExtension else { return nil }
        }

        // Reject when the text after the last "/" is a run of 3+ plain lowercase words —
        // a real path's final segment is a filename (often with an extension or capitals),
        // while a prose sentence following a leading path reads as space-separated lowercase
        // words ("/etc/hosts is the file you want").
        if let lastSlashIndex = trimmed.lastIndex(of: "/") {
            let tail = trimmed[trimmed.index(after: lastSlashIndex)...]
            let tailWords = tail.split(separator: " ")
            let isProseTail = tailWords.count >= 3 && tailWords.allSatisfy {
                $0.range(of: #"^[a-z']+$"#, options: .regularExpression) != nil
            }
            guard !isProseTail else { return nil }
        }

        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
