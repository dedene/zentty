import Foundation

/// Lines of config.toml that this build reads past but does not model:
/// keys a newer Zentty added to a known section, whole sections it doesn't
/// know, and keys above the first header. The encoder writes them back out so
/// a save never strips what another build (or another Mac sharing the file)
/// put there. Keys inside `[[array]]` entries we do model are not kept.
struct AppConfigPreservedTOML: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        /// The header line exactly as written, e.g. `[future]` or `[[future.items]]`.
        var header: String
        var lines: [String]
    }

    /// Unknown keys keyed by the header of the known section they appeared
    /// in; `""` holds keys above the first header.
    var extraLinesBySectionHeader: [String: [String]] = [:]
    /// Sections this build has no model for, in file order.
    var unknownSections: [Section] = []

    static let empty = AppConfigPreservedTOML()

    var isEmpty: Bool {
        extraLinesBySectionHeader.isEmpty && unknownSections.isEmpty
    }

    mutating func appendExtraLine(_ line: String, toSectionHeader header: String) {
        extraLinesBySectionHeader[header, default: []].append(line)
    }

    mutating func beginUnknownSection(header: String) {
        unknownSections.append(Section(header: header, lines: []))
    }

    mutating func appendLineToLastUnknownSection(_ line: String) {
        guard !unknownSections.isEmpty else { return }
        unknownSections[unknownSections.count - 1].lines.append(line)
    }

    /// Merges the preserved lines into freshly encoded config lines. Extras
    /// go at the end of their section; a known section the encoder skipped
    /// (e.g. an empty `[agent_integrations.states]`) is added back to hold
    /// them; unknown sections follow at the end, in their original order.
    func merged(into encodedLines: [String]) -> [String] {
        guard !isEmpty else { return encodedLines }

        var pendingExtras = extraLinesBySectionHeader
        var blocks: [[String]] = []
        if let rootLines = pendingExtras.removeValue(forKey: ""), !rootLines.isEmpty {
            blocks.append(rootLines)
        }

        for var block in Self.blocks(of: encodedLines) {
            if let header = block.first, let extras = pendingExtras.removeValue(forKey: header) {
                // A key this build now writes itself (e.g. an agent state set
                // after an unknown value was read) wins over the preserved line.
                let encodedKeys = Set(block.dropFirst().compactMap(Self.key(of:)))
                block.append(contentsOf: extras.filter { Self.key(of: $0).map { !encodedKeys.contains($0) } ?? true })
            }
            blocks.append(block)
        }
        for header in pendingExtras.keys.sorted() {
            blocks.append([header] + (pendingExtras[header] ?? []))
        }
        for section in unknownSections {
            blocks.append([section.header] + section.lines)
        }

        var merged: [String] = []
        for (index, block) in blocks.enumerated() {
            if index > 0 { merged.append("") }
            merged.append(contentsOf: block)
        }
        return merged
    }

    private static func key(of line: String) -> String? {
        guard let separatorIndex = line.firstIndex(of: "=") else { return nil }
        return line[..<separatorIndex].trimmingCharacters(in: .whitespaces)
    }

    /// Splits encoded lines into blocks that each start at a header, with
    /// blank separator lines dropped.
    private static func blocks(of lines: [String]) -> [[String]] {
        var blocks: [[String]] = []
        for line in lines {
            if line.isEmpty { continue }
            if line.hasPrefix("[") || blocks.isEmpty {
                blocks.append([line])
            } else {
                blocks[blocks.count - 1].append(line)
            }
        }
        return blocks
    }
}
