import AppKit
import os
import UniformTypeIdentifiers

enum TerminalClipboard {
    enum PastedContent {
        case text(String)
        case filePath(String)
    }

    struct PastedImage {
        let data: Data
        let fileExtension: String
    }

    enum ImageUploadContent {
        case image(PastedImage)
        case imageTooLarge
        case failedToReadImage
        case noImage
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "be.zenjoy.zentty",
        category: "TerminalClipboard"
    )

    // MARK: - Public

    static func pastedString(from pasteboard: NSPasteboard) -> String? {
        if !fileURLs(from: pasteboard).isEmpty {
            return nil
        }

        return pasteboard.string(forType: .string)
    }

    static func pastedContent(from pasteboard: NSPasteboard) -> PastedContent? {
        // 1. File URLs — escape paths
        let fileURLs = fileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
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

    static func imageUploadContent(from pasteboard: NSPasteboard) -> ImageUploadContent {
        if !fileURLs(from: pasteboard).isEmpty {
            return .noImage
        }

        guard hasImageData(in: pasteboard) else {
            return .noImage
        }

        guard let pastedImage = pastedImageData(from: pasteboard) else {
            return .noImage
        }

        guard pastedImage.data.count <= TerminalClipboardImagePolicy.maxImageByteCount else {
            logger.warning("Clipboard image too large: \(pastedImage.data.count) bytes")
            return .imageTooLarge
        }

        return .image(pastedImage)
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let fileURLReadOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        return pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: fileURLReadOptions
        ) as? [URL] ?? []
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
                  imageData.isEmpty == false else { continue }
            let fileExtension = TerminalClipboardImagePolicy.fileExtension(for: utType)
            return (imageData, fileExtension)
        }

        return nil
    }

    private static func saveClipboardImagePath(from pasteboard: NSPasteboard) -> String? {
        guard hasImageData(in: pasteboard) else { return nil }

        guard let pastedImage = pastedImageData(from: pasteboard) else {
            return nil
        }

        guard pastedImage.data.count <= TerminalClipboardImagePolicy.maxImageByteCount else {
            logger.warning("Clipboard image too large: \(pastedImage.data.count) bytes")
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = formatter.string(from: Date())
        let filename = "clipboard-\(timestamp)-\(UUID().uuidString.prefix(8)).\(pastedImage.fileExtension)"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try pastedImage.data.write(to: fileURL)
        } catch {
            logger.error("Failed to save clipboard image: \(error.localizedDescription)")
            return nil
        }

        return ShellEscaping.escapePath(fileURL.path)
    }

    private static func pastedImageData(from pasteboard: NSPasteboard) -> PastedImage? {
        if let direct = directImageData(from: pasteboard) {
            return PastedImage(data: direct.data, fileExtension: direct.fileExtension)
        }

        if let image = NSImage(pasteboard: pasteboard),
           let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            return PastedImage(data: pngData, fileExtension: "png")
        }

        return nil
    }

}
