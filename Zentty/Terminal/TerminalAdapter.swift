import AppKit

struct TerminalSessionRequest: Equatable, Sendable {
    var workingDirectory: String?

    init(workingDirectory: String? = nil) {
        self.workingDirectory = workingDirectory
    }
}

@MainActor
protocol TerminalAdapter: AnyObject {
    func makeTerminalView() -> NSView
    func startSession(using request: TerminalSessionRequest) throws
    var metadataDidChange: ((TerminalMetadata) -> Void)? { get set }
}

@MainActor
protocol TerminalFocusReporting: AnyObject {
    var onFocusDidChange: ((Bool) -> Void)? { get set }
}
