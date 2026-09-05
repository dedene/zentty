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

enum RemoteImagePasteDecision {
    static func shouldUploadRemotely(
        paneState: RemoteImagePastePaneState,
        pasteboardContents: RemoteImagePasteboardContents
    ) -> Bool {
        paneState.isRemotePane && pasteboardContents.shouldUpload
    }
}
