import AppKit
import os
import UniformTypeIdentifiers

enum TerminalClipboard {
    enum PastedContent {
        case text(String)
        case filePath(String)
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "be.zenjoy.zentty",
        category: "TerminalClipboard"
    )

    private static let maxClipboardImageSize = 10 * 1024 * 1024 // 10 MB

    // MARK: - Public

    static func pastedString(from pasteboard: NSPasteboard) -> String? {
        let fileURLReadOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        if let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: fileURLReadOptions
        ) as? [URL], fileURLs.isEmpty == false {
            return nil
        }

        return pasteboard.string(forType: .string)
    }

    static func pastedContent(from pasteboard: NSPasteboard) -> PastedContent? {
        // 1. File URLs — escape paths
        let fileURLReadOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        if let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: fileURLReadOptions
        ) as? [URL], !fileURLs.isEmpty {
            let escaped = fileURLs
                .map { ShellEscaping.escapePath($0.path) }
                .joined(separator: " ")
            return .filePath(escaped)
        }

        // 2. Plain text
        if let string = pasteboard.string(forType: .string) {
            return .text(string)
        }

        // 3. Image data — save to temp file, return escaped path
        if let imagePath = saveClipboardImagePath(from: pasteboard) {
            return .filePath(imagePath)
        }

        return nil
    }

    // MARK: - Image helpers

    private static func hasImageData(in pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if types.contains(.tiff) || types.contains(.png) {
            return true
        }
        return types.contains { type in
            guard let utType = UTType(type.rawValue) else { return false }
            return utType.conforms(to: .image)
        }
    }

    private static func directImageData(
        from pasteboard: NSPasteboard
    ) -> (data: Data, fileExtension: String)? {
        if let pngData = pasteboard.data(forType: .png) {
            return (pngData, "png")
        }

        for type in pasteboard.types ?? [] {
            guard type != .png,
                  type != .tiff,
                  let utType = UTType(type.rawValue),
                  utType.conforms(to: .image),
                  let imageData = pasteboard.data(forType: type),
                  let fileExtension = utType.preferredFilenameExtension,
                  !fileExtension.isEmpty else { continue }
            return (imageData, fileExtension)
        }

        return nil
    }

    private static func saveClipboardImagePath(from pasteboard: NSPasteboard) -> String? {
        guard hasImageData(in: pasteboard) else { return nil }

        let imageData: Data
        let fileExtension: String

        if let direct = directImageData(from: pasteboard) {
            imageData = direct.data
            fileExtension = direct.fileExtension
        } else if let image = NSImage(pasteboard: pasteboard),
                  let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) {
            imageData = pngData
            fileExtension = "png"
        } else {
            return nil
        }

        guard imageData.count <= maxClipboardImageSize else {
            logger.warning("Clipboard image too large: \(imageData.count) bytes")
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = formatter.string(from: Date())
        let filename = "clipboard-\(timestamp)-\(UUID().uuidString.prefix(8)).\(fileExtension)"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try imageData.write(to: fileURL)
        } catch {
            logger.error("Failed to save clipboard image: \(error.localizedDescription)")
            return nil
        }

        return ShellEscaping.escapePath(fileURL.path)
    }
}
