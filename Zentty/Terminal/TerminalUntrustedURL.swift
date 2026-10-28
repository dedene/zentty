import Foundation
import UniformTypeIdentifiers

/// A link target that terminal output controls, so it must not reach Launch Services unchecked.
/// Web and mail links open directly, custom schemes need confirmation, and local files open only
/// when they cannot execute code.
struct TerminalUntrustedURL: Equatable {
    enum DenialReason: Equatable {
        case malformedURL
        case unsafeCharacters
        case invalidWebURL
        case inaccessibleFile
        case unsafeFile

        var message: String {
            switch self {
            case .malformedURL:
                "The target is not an absolute URL with a scheme."
            case .unsafeCharacters:
                "The target contains invisible or line-breaking characters."
            case .invalidWebURL:
                "The web target does not contain a valid host."
            case .inaccessibleFile:
                "The local target does not exist or is not a regular file or directory."
            case .unsafeFile:
                "Opening this local target could execute code."
            }
        }
    }

    enum Decision: Equatable {
        /// Schemes with well-understood, non-executing behavior.
        case allow(URL)
        /// A custom scheme dispatches to whatever app registered it, so the user decides.
        case confirm(URL)
        case deny(DenialReason)
    }

    let string: String

    init(_ string: String) {
        self.string = string
    }

    var decision: Decision {
        guard !string.isEmpty else {
            return .deny(.malformedURL)
        }

        // Check before parsing: URL(string:) percent-encodes these, which would hide them
        // from the user while the handler still receives them.
        guard !Self.containsUnsafeCharacters(string) else {
            return .deny(.unsafeCharacters)
        }

        // Require an explicit scheme so a relative reference cannot be reinterpreted as a
        // local path further down.
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              !scheme.isEmpty else {
            return .deny(.malformedURL)
        }

        switch scheme {
        case "http", "https":
            // "https:relative" has a scheme but no authority; consumers resolve it differently.
            guard let host = url.host, !host.isEmpty else {
                return .deny(.invalidWebURL)
            }
            return .allow(url)
        case "mailto":
            // A bare "mailto:" would hand the mail app an empty request.
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  !components.path.isEmpty else {
                return .deny(.malformedURL)
            }
            return .allow(url)
        case "file":
            return fileDecision(for: url)
        default:
            return .confirm(url)
        }
    }

    /// Whether `value` contains control, invisible, or text-reversing characters.
    static func containsUnsafeCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: isUnsafeCharacter)
    }

    /// The effective target on a single line, for the confirmation and block alerts. File paths are
    /// standardized and symlink-resolved exactly as they are before opening, so the shown and opened
    /// targets cannot differ; other URLs stay byte-for-byte because handlers may care about separators.
    var displayString: String {
        let normalized: String
        if let url = URL(string: string), url.scheme != nil {
            normalized = url.isFileURL
                ? url.standardizedFileURL.resolvingSymlinksInPath().path
                : string
        } else {
            normalized = URL(filePath: string).standardizedFileURL.path
        }

        // Escape after normalizing so a remaining unsafe scalar shows as text, never as a new line.
        var result = String()
        result.reserveCapacity(normalized.count)
        for scalar in normalized.unicodeScalars {
            if Self.isUnsafeCharacter(scalar) {
                result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

private extension TerminalUntrustedURL {
    func fileDecision(for url: URL) -> Decision {
        // Queries and fragments do not name part of a file and handlers interpret them inconsistently.
        guard url.isFileURL, url.query == nil, url.fragment == nil else {
            return .deny(.malformedURL)
        }

        // Only this machine: a remote host could trigger network access.
        if let host = url.host,
           !host.isEmpty,
           host.caseInsensitiveCompare("localhost") != .orderedSame {
            return .deny(.malformedURL)
        }

        // Classify the effective object, so dot traversal or a harmless-looking symlink name
        // cannot hide an executable target. Reading the keys also proves the target exists.
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let resourceValues: URLResourceValues
        do {
            resourceValues = try canonicalURL.resourceValues(forKeys: [
                .contentTypeKey,
                .isDirectoryKey,
                .isExecutableKey,
                .isRegularFileKey,
            ])
        } catch {
            return .deny(.inaccessibleFile)
        }

        // Devices, sockets and other special files are out; a directory reveals in Finder.
        guard resourceValues.isDirectory == true || resourceValues.isRegularFile == true else {
            return .deny(.inaccessibleFile)
        }
        guard !Self.isUnsafeFile(canonicalURL, resourceValues: resourceValues) else {
            return .deny(.unsafeFile)
        }

        return .allow(canonicalURL)
    }

    static func isUnsafeFile(_ url: URL, resourceValues: URLResourceValues) -> Bool {
        // Launch Services picks a handler by extension, so block executable containers even
        // when their POSIX executable bit is clear.
        if unsafePathExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }

        // UTIs catch a missing or misleading extension; the broad types cover shell scripts
        // and application bundles through conformance.
        if let contentType = resourceValues.contentType,
           unsafeContentTypes.contains(where: { contentType.conforms(to: $0) }) {
            return true
        }

        return resourceValues.isDirectory != true && resourceValues.isExecutable == true
    }

    static func isUnsafeCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // C0/C1 controls, including CR, LF and NEL.
        case 0x00...0x1F, 0x7F...0x9F:
            return true
        // Directional marks and zero-width characters can reorder or conceal parts of the target.
        case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        // Line and paragraph separators render as extra lines in AppKit text.
        case 0x2028...0x2029:
            return true
        // Word joiner and BOM: invisible padding that can disguise lookalike targets.
        case 0x2060, 0xFEFF:
            return true
        default:
            return false
        }
    }

    static let unsafePathExtensions: Set<String> = [
        "action",
        "app",
        "applescript",
        "class",
        "command",
        "desktop",
        "inetloc",
        "jar",
        "mobileconfig",
        "mpkg",
        "pkg",
        "scpt",
        "terminal",
        "tool",
        "url",
        "webloc",
        "workflow",
    ]

    static let unsafeContentTypes: [UTType] = [
        .application,
        .executable,
        .script,
    ]
}
