import Foundation
import UniformTypeIdentifiers

enum TerminalClipboardImagePolicy {
    static let maxImageByteCount = 10 * 1024 * 1024

    static func fileExtension(forUTIIdentifier identifier: String?) -> String {
        guard let identifier,
              let type = UTType(identifier) else {
            return "png"
        }

        return fileExtension(for: type)
    }

    static func fileExtension(for type: UTType?) -> String {
        guard let type else {
            return "png"
        }

        if type.conforms(to: .png) {
            return "png"
        }

        if type.conforms(to: .jpeg) {
            return "jpeg"
        }

        if type.conforms(to: .tiff) {
            return "tiff"
        }

        if type.conforms(to: .gif) {
            return "gif"
        }

        let identifier = type.identifier.lowercased()
        let preferredExtension = type.preferredFilenameExtension?.lowercased()
        if identifier.contains("webp") || preferredExtension == "webp" {
            return "webp"
        }

        if let safeExtension = safeFilenameExtension(preferredExtension) {
            return safeExtension
        }

        return "png"
    }

    static func normalizedFileExtension(_ fileExtension: String) -> String {
        let normalized = fileExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
            .lowercased()
        switch normalized {
        case "png", "jpeg", "jpg", "tiff", "tif", "gif", "webp":
            return normalized == "jpg" ? "jpeg" : normalized == "tif" ? "tiff" : normalized
        default:
            return safeFilenameExtension(normalized) ?? "png"
        }
    }

    private static func safeFilenameExtension(_ fileExtension: String?) -> String? {
        guard let fileExtension else {
            return nil
        }

        let normalized = fileExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
            .lowercased()
        guard !normalized.isEmpty,
              normalized.range(of: #"^[a-z0-9]+$"#, options: .regularExpression) != nil else {
            return nil
        }

        return normalized
    }
}
