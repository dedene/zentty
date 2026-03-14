import AppKit

@MainActor
protocol TerminalAdapter: AnyObject {
    func makeTerminalView() -> NSView
    func startSession() throws
    var metadataDidChange: ((TerminalMetadata) -> Void)? { get set }
}
