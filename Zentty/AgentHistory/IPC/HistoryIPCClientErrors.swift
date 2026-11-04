import Foundation

enum HistoryIPCClientOutcome: Equatable {
    case result(HistoryIPCResult)
    case failure(message: String)
}

/// What went wrong talking to the app, reduced to values this shared file can see.
/// `AgentIPCClientError` lives only in the CLI target, so the CLI translates it into this.
enum HistoryIPCClientFailure: Equatable, Sendable {
    /// The app closed the connection without answering. An app that predates Agent History
    /// can't decode a `history` request and does exactly this.
    case connectionClosed
    /// A socket error, by `errno`.
    case posix(Int32)
    /// The app answered with an error.
    case response(code: String, message: String)
    /// Anything else, already described.
    case other(String)
}

/// Turns client-side failures into the one-line message `zentty history` prints.
enum HistoryIPCClientErrorMapper {
    static func message(for failure: HistoryIPCClientFailure) -> String {
        switch failure {
        case .connectionClosed:
            return HistoryIPC.versionSkewMessage
        case .posix(let code) where timeoutCodes.contains(code):
            return HistoryIPC.timeoutMessage
        case .posix(let code):
            return String(cString: strerror(code))
        case .response(let code, let message):
            // A build that knows the `history` kind but has no handler for it yet.
            return code == "unsupported_subcommand" ? HistoryIPC.versionSkewMessage : message
        case .other(let description):
            return description
        }
    }

    /// Maps the errors this file can recognize; the CLI handles its own client errors first.
    static func map(_ error: Error) -> String {
        if let error = error as? HistoryIPCError {
            return error.localizedDescription
        }
        if let error = error as? POSIXError {
            return message(for: .posix(error.code.rawValue))
        }
        return message(for: .other(error.localizedDescription))
    }

    /// A successful response without a `history` payload came from an app that doesn't know it.
    static func outcome(_ response: AgentIPCResponseResult?) -> HistoryIPCClientOutcome {
        guard let history = response?.history, history.search != nil || history.show != nil else {
            return .failure(message: HistoryIPC.versionSkewMessage)
        }
        return .result(history)
    }

    private static let timeoutCodes: Set<Int32> = [EAGAIN, EWOULDBLOCK, ETIMEDOUT]
}
