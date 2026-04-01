import AppKit

enum TerminalClipboard {
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
}
