import Foundation

enum RemoteImageUploadPath {
    static func generate(
        fileExtension: String,
        date: Date = Date(),
        uuid: UUID = UUID()
    ) -> String {
        let timestamp = Int(date.timeIntervalSince1970)
        let uuidPrefix = uuid.uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .lowercased()
        let ext = TerminalClipboardImagePolicy.normalizedFileExtension(fileExtension)
        return "/tmp/zentty-paste-\(timestamp)-\(uuidPrefix).\(ext)"
    }

    static func path(
        forOriginalFilename originalFilename: String,
        date: Date = Date(),
        uuid: UUID = UUID()
    ) -> String {
        let timestamp = Int(date.timeIntervalSince1970)
        let uuidPrefix = uuid.uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .lowercased()
        let sanitizedFilename = sanitizedOriginalFilename(originalFilename)
        return "/tmp/zentty-paste-\(timestamp)-\(uuidPrefix)-\(sanitizedFilename)"
    }

    static func isSafeRemotePath(_ path: String) -> Bool {
        path.range(
            of: #"^/tmp/zentty-paste-[A-Za-z0-9._-]+$"#,
            options: .regularExpression
        ) != nil
    }

    private static func sanitizedOriginalFilename(_ originalFilename: String) -> String {
        let filename = originalFilename.isEmpty ? "file" : originalFilename
        let split = splitFilename(filename)
        let sanitizedStem = sanitizedFilenameComponent(split.stem)
        let sanitizedExtension = split.extension.map(sanitizedFilenameComponent)

        let stem = sanitizedStem.isEmpty ? "file" : sanitizedStem
        guard let ext = sanitizedExtension, !ext.isEmpty else {
            return capped(stem, limit: 128)
        }

        let extensionWithDot = ".\(capped(ext, limit: 64))"
        let stemLimit = max(1, 128 - extensionWithDot.count)
        return "\(capped(stem, limit: stemLimit))\(extensionWithDot)"
    }

    private static func splitFilename(_ filename: String) -> (stem: String, extension: String?) {
        let scalars = Array(filename.unicodeScalars)
        if scalars.first?.value == 46,
           scalars.dropFirst().allSatisfy({ $0.value != 46 }) {
            return (filename, nil)
        }

        guard let dotIndex = filename.lastIndex(of: "."),
              dotIndex != filename.startIndex,
              dotIndex < filename.index(before: filename.endIndex)
        else {
            return (filename, nil)
        }

        return (
            String(filename[..<dotIndex]),
            String(filename[filename.index(after: dotIndex)...])
        )
    }

    private static func sanitizedFilenameComponent(_ component: String) -> String {
        var result = ""
        var previousWasDash = false
        for scalar in component.unicodeScalars {
            if scalar.value == 45 {
                if !previousWasDash {
                    result.append("-")
                }
                previousWasDash = true
            } else if isAllowedFilenameScalar(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash {
                result.append("-")
                previousWasDash = true
            }
        }

        return result.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    }

    private static func isAllowedFilenameScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        case 45, 46, 95:
            return true
        default:
            return false
        }
    }

    private static func capped(_ value: String, limit: Int) -> String {
        guard value.count > limit else {
            return value
        }

        return String(value.prefix(limit))
    }
}
