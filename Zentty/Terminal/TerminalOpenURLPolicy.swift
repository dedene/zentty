import Foundation

/// Where libghostty says an open-URL target came from (ghostty_action_open_url_kind_e).
enum TerminalOpenURLKind: Equatable {
    /// A `link` match in terminal output, such as the default URL regex. Untrusted, and may be a
    /// plain path like `~/notes.txt` instead of a URL.
    case unknown
    case text
    case html
    /// An OSC 8 hyperlink target exactly as the program sent it. Untrusted; the visible link text
    /// need not match it.
    case osc8

    /// `text` and `html` come from libghostty itself; the others are program-controlled output.
    var isTrusted: Bool {
        switch self {
        case .text, .html:
            true
        case .unknown, .osc8:
            false
        }
    }
}

enum TerminalOpenURLDecision: Equatable {
    case open(URL)
    case confirm(URL, displayString: String)
    case block(TerminalUntrustedURL.DenialReason, displayString: String)
}

/// Decides what a Cmd-click on a terminal link may do. Trusted kinds open as before; untrusted kinds
/// go through TerminalUntrustedURL so terminal output cannot launch apps or executables directly.
enum TerminalOpenURLPolicy {
    static func decision(
        for rawString: String,
        kind: TerminalOpenURLKind,
        workingDirectory: String?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> TerminalOpenURLDecision {
        if kind.isTrusted {
            return .open(
                TerminalOpenURLResolver.resolve(rawString, workingDirectory: workingDirectory, fileExists: fileExists)
            )
        }

        let target = TerminalUntrustedURL(untrustedTarget(
            for: rawString,
            kind: kind,
            workingDirectory: workingDirectory,
            fileExists: fileExists
        ))
        switch target.decision {
        case .allow(let url):
            return .open(url)
        case .confirm(let url):
            return .confirm(url, displayString: target.displayString)
        case .deny(let reason):
            return .block(reason, displayString: target.displayString)
        }
    }

    /// OSC 8 targets are checked verbatim. A `link` match may be a plain path, which
    /// TerminalUntrustedURL rejects, so it is resolved to a file URL first and that URL is checked.
    /// Values with unsafe characters stay raw so they are rejected before percent-encoding hides them.
    private static func untrustedTarget(
        for rawString: String,
        kind: TerminalOpenURLKind,
        workingDirectory: String?,
        fileExists: (String) -> Bool
    ) -> String {
        guard kind == .unknown,
              !rawString.isEmpty,
              URL(string: rawString)?.scheme == nil,
              !TerminalUntrustedURL.containsUnsafeCharacters(rawString) else {
            return rawString
        }
        return TerminalOpenURLResolver
            .resolve(rawString, workingDirectory: workingDirectory, fileExists: fileExists)
            .absoluteString
    }
}
