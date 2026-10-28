import Foundation
import GhosttyKit

/// What a program, or a risky paste, is asking libghostty to do with the clipboard
/// (ghostty_clipboard_request_e). libghostty only asks when policy says so: `clipboard-read = ask`
/// for reads, `clipboard-write = ask` for writes, and `clipboard-paste-protection` for pastes.
enum TerminalClipboardRequestKind: Equatable {
    case paste
    case read
    case write
    case list

    init?(_ request: ghostty_clipboard_request_e) {
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
            self = .paste
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ:
            self = .read
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE, GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE:
            self = .write
        case GHOSTTY_CLIPBOARD_REQUEST_LIST:
            self = .list
        default:
            return nil
        }
    }

    var messageText: String {
        switch self {
        case .paste:
            "Paste Potentially Unsafe Text?"
        case .read, .list:
            "Allow Clipboard Access?"
        case .write:
            "Allow Clipboard Change?"
        }
    }

    /// The Kitty protocol's program-supplied name is deliberately never shown: it is
    /// attacker-controlled text inside a trusted prompt.
    var informativeText: String {
        switch self {
        case .paste:
            "This text looks like it may run commands as soon as it is pasted."
        case .read:
            "A program in this pane wants to read your clipboard. Its current contents are shown below."
        case .list:
            "A program in this pane wants to see which kinds of data are on your clipboard."
        case .write:
            "A program in this pane wants to replace your clipboard with the content below."
        }
    }

    var denyButtonTitle: String {
        self == .paste ? "Cancel" : "Deny"
    }

    var allowButtonTitle: String {
        self == .paste ? "Paste" : "Allow"
    }
}

/// One representation of clipboard contents as libghostty hands it over.
struct LibghosttyClipboardContent: Equatable {
    let mime: String
    let data: Data
}

/// The prompt contents for a clipboard confirmation, built from what libghostty would hand over.
struct TerminalClipboardConfirmation: Equatable {
    static let previewCharacterLimit = 20_000

    let kind: TerminalClipboardRequestKind
    let previewText: String
    /// Raw data of the first image representation, previewed in place of text when present.
    let imageData: Data?
    let canRemember: Bool

    init(
        kind: TerminalClipboardRequestKind,
        contents: [LibghosttyClipboardContent],
        available: [String],
        canRemember: Bool
    ) {
        self.kind = kind
        self.canRemember = canRemember
        self.imageData = contents.first { $0.mime.hasPrefix("image/") }?.data
        self.previewText = Self.previewText(kind: kind, contents: contents, available: available)
    }

    private static func previewText(
        kind: TerminalClipboardRequestKind,
        contents: [LibghosttyClipboardContent],
        available: [String]
    ) -> String {
        if kind == .list {
            return available.isEmpty ? "The clipboard is empty." : available.joined(separator: "\n")
        }
        if let text = contents.first(where: { $0.mime == "text/plain" }) {
            return visibleText(String(decoding: text.data, as: UTF8.self))
        }
        guard !contents.isEmpty else {
            return "The clipboard is empty."
        }
        let formatter = ByteCountFormatter()
        return contents
            .map { "\($0.mime) (\(formatter.string(fromByteCount: Int64($0.data.count))))" }
            .joined(separator: "\n")
    }

    /// Shows control characters as Unicode control pictures so an escape sequence or carriage return
    /// in the preview can't hide or rewrite what is actually being pasted or read.
    static func visibleText(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars {
            if count == previewCharacterLimit {
                result.append(contentsOf: "\n\u{2026}".unicodeScalars)
                break
            }
            count += 1
            switch scalar.value {
            case 0x0A, 0x09:
                result.append(scalar)
            case 0x00..<0x20:
                result.append(Unicode.Scalar(0x2400 + scalar.value)!)
            case 0x7F:
                result.append("\u{2421}")
            case 0x80..<0xA0:
                result.append("\u{FFFD}")
            default:
                result.append(scalar)
            }
        }
        return String(result)
    }
}
