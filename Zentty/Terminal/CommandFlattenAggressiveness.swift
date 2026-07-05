import Foundation

enum CommandFlattenAggressiveness: String, CaseIterable, Equatable, Sendable, Codable {
    case low, normal, high

    var scoreThreshold: Int {
        switch self {
        case .low: 3
        case .normal: 2
        case .high: 1
        }
    }

    var settingsTitle: String {
        switch self {
        case .low: "Low (safer)"
        case .normal: "Normal"
        case .high: "High (more eager)"
        }
    }

    var settingsBlurb: String {
        switch self {
        case .low:
            "Only flatten multi-line commands with strong signals (continuations, pipes, paths)."
        case .normal:
            "Balanced default for terminal snippets: backslash continuations, pipelines, and wrapped commands."
        case .high:
            "Flatten more loosely wrapped command blocks; may affect some prose or lists."
        }
    }
}