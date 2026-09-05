import Foundation

/// What "Copy Path" puts on the pasteboard for a pane.
///
/// A local pane copies its working directory. A remote pane copies the SSH
/// command that reaches it instead, because the remote path is rarely useful
/// on the local machine while `ssh user@host` is exactly what you want to
/// paste into another terminal.
enum PaneCopyTarget: Equatable, Sendable {
    case path(String)
    case sshConnection(String)

    var pasteboardString: String {
        switch self {
        case .path(let value), .sshConnection(let value):
            return value
        }
    }

    var copiedToastMessage: String {
        switch self {
        case .path:
            return "Path copied"
        case .sshConnection:
            return "Connection copied"
        }
    }

    var commandPaletteSubtitle: String {
        switch self {
        case .path(let path):
            return "Copy Path — \(path)"
        case .sshConnection(let command):
            return "Copy Connection — \(command)"
        }
    }
}

enum PaneCopyTargetResolver {
    static func target(for auxiliaryState: PaneAuxiliaryState) -> PaneCopyTarget? {
        if auxiliaryState.presentation.isRemotePane,
           let destination = PaneSSHDestinationResolver.destination(from: auxiliaryState) {
            return .sshConnection(destination.sshCommand)
        }

        guard let path = WorklaneContextFormatter.trimmed(auxiliaryState.shellContext?.path) else {
            return nil
        }

        return .path(path)
    }
}

extension SSHDestination {
    /// The shortest `ssh` invocation that reconnects to this destination.
    var sshCommand: String {
        var parts = ["ssh"]
        if let port {
            parts += ["-p", String(port)]
        }
        parts.append(target)
        return parts.joined(separator: " ")
    }
}
