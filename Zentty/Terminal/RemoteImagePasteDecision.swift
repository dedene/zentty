enum RemoteImagePasteboardContents: Equatable, Sendable {
    case empty
    case text
    case imageData
    case fileURL
    case imageTooLarge

    var shouldUpload: Bool {
        switch self {
        case .imageData, .fileURL, .imageTooLarge:
            return true
        case .empty, .text:
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
        paneState.isRemotePane && pasteboardContents.shouldUpload
    }
}
