enum RemoteImagePasteboardContents: Equatable, Sendable {
    case empty
    case text
    case imageData
    case imageFileURL
    case imageTooLarge
    case nonImageFileURL

    var containsImage: Bool {
        switch self {
        case .imageData, .imageFileURL, .imageTooLarge:
            return true
        case .empty, .text, .nonImageFileURL:
            return false
        }
    }
}

struct RemoteImagePastePaneState: Equatable, Sendable {
    let isRemotePane: Bool
    let destination: SSHDestination?
}

enum RemoteImagePasteDestination {
    static func destination(from auxiliaryState: PaneAuxiliaryState) -> SSHDestination? {
        if let destination = auxiliaryState.raw.foregroundSSHDestination {
            return destination
        }

        if let title = WorklaneContextFormatter.trimmed(auxiliaryState.raw.metadata?.title),
           let destination = WorklaneContextFormatter.sshDestination(fromCommandTitle: title) {
            return destination
        }

        if let label = WorklaneContextFormatter.trimmed(auxiliaryState.presentation.sshConnectionLabel) {
            return SSHDestination(target: label)
        }

        if let shellContext = auxiliaryState.raw.shellContext,
           shellContext.scope == .remote,
           let host = WorklaneContextFormatter.trimmed(shellContext.host) {
            let user = WorklaneContextFormatter.trimmed(shellContext.user)
            return SSHDestination(
                target: user.map { "\($0)@\(host)" } ?? host,
                user: user,
                host: host
            )
        }

        return nil
    }
}

enum RemoteImagePasteDecision {
    static func shouldUploadRemotely(
        paneState: RemoteImagePastePaneState,
        pasteboardContents: RemoteImagePasteboardContents
    ) -> Bool {
        paneState.isRemotePane && pasteboardContents.containsImage
    }
}
