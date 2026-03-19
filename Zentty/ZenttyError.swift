import Foundation

enum ZenttyError: Error, Sendable {
    case terminalSessionFailed(paneID: PaneID, reason: String)
    case agentPayloadMalformed(detail: String)
    case subprocessFailed(command: String, exitCode: Int32, stderr: String)
    case themeResolutionFailed(path: String, reason: String)
}
