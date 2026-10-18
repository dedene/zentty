import AppKit
import Foundation

/// App side of `zentty pane send`, `pane send-key`, and `pane read`.
///
/// The routed target (from selectors or the caller's environment) has
/// already been authenticated by the IPC server. A `--target` reference is
/// then resolved inside that target's worklane, exactly like `pane close`.
enum PaneControlIPCHandler {
    /// Pause between typed text and the Enter that submits it. Programs
    /// that read text and CR in one chunk tend to treat it as a paste and
    /// insert a newline instead of submitting.
    static let submitDelay: TimeInterval = 0.1

    struct ResolvedPane {
        let windowController: MainWindowController
        let windowID: WindowID?
        let worklaneID: WorklaneID
        let paneID: PaneID
    }

    // MARK: - send

    /// Runs off the main thread when called from the IPC server, so the
    /// submit delay never blocks the UI.
    static func handleSend(request: AgentIPCRequest, target: AgentIPCTarget) throws -> AgentIPCResponseResult {
        let options = try PaneSendIPCOptions.parse(arguments: request.arguments)
        let text = request.standardInput ?? ""
        let byteCount = text.utf8.count
        guard byteCount <= PaneControlIPC.maxSendTextBytes else {
            throw PaneControlIPCError.textTooLarge(bytes: byteCount, limit: PaneControlIPC.maxSendTextBytes)
        }
        // Never a bare Enter: an empty variable would otherwise submit
        // whatever the user had half-typed in that pane.
        guard !text.isEmpty else {
            throw PaneControlIPCError.missingText
        }

        let paneID: PaneID = try onMain {
            let pane = try resolve(reference: options.target, target: target)
            let activity = PaneInputService.agentActivity(
                of: pane.paneID,
                in: pane.worklaneID,
                controller: pane.windowController
            )
            if let refusal = PaneSendGuard.decision(for: activity, force: options.force).refusalError {
                throw refusal
            }
            let delivered = switch PaneSendDelivery.mode(for: text, pasteRequested: options.paste) {
            case .paste:
                PaneInputService.pasteText(text, to: pane.paneID, in: pane.windowController)
            case .type:
                PaneInputService.typeText(text, to: pane.paneID, in: pane.windowController)
            }
            guard delivered else {
                throw PaneControlIPCError.paneUnavailable(pane.paneID.rawValue)
            }
            return pane.paneID
        }

        guard options.submit else {
            return AgentIPCResponseResult()
        }
        if !Thread.isMainThread {
            Thread.sleep(forTimeInterval: submitDelay)
        }
        try onMain {
            guard let appDelegate = NSApp.delegate as? AppDelegate,
                  let controller = appDelegate.windowController(containingPane: paneID),
                  PaneInputService.sendKeyStrokes([.key(.enter, shift: false)], to: paneID, in: controller)
            else {
                throw PaneControlIPCError.paneUnavailable(paneID.rawValue)
            }
        }
        return AgentIPCResponseResult()
    }

    // MARK: - send-key

    @MainActor
    static func handleSendKey(request: AgentIPCRequest, target: AgentIPCTarget) throws -> AgentIPCResponseResult {
        let options = try PaneSendKeyIPCOptions.parse(arguments: request.arguments)
        let strokes = try PaneKeyNames.strokes(for: options.keys)
        let pane = try resolve(reference: options.target, target: target)
        let activity = PaneInputService.agentActivity(
            of: pane.paneID,
            in: pane.worklaneID,
            controller: pane.windowController
        )
        if let refusal = PaneSendGuard.decision(forKeys: strokes, activity: activity, force: options.force).refusalError {
            throw refusal
        }
        guard PaneInputService.sendKeyStrokes(strokes, to: pane.paneID, in: pane.windowController) else {
            throw PaneControlIPCError.paneUnavailable(pane.paneID.rawValue)
        }
        return AgentIPCResponseResult()
    }

    // MARK: - read

    @MainActor
    static func handleRead(request: AgentIPCRequest, target: AgentIPCTarget) throws -> AgentIPCResponseResult {
        let options = try PaneReadIPCOptions.parse(arguments: request.arguments)
        let pane = try resolve(reference: options.target, target: target)
        guard let text = PaneInputService.readText(
            from: pane.paneID,
            in: pane.windowController,
            includeScrollback: options.includeScrollback,
            lineLimit: options.lineLimit
        ) else {
            throw PaneControlIPCError.paneUnavailable(pane.paneID.rawValue)
        }
        let grid = PaneInputService.gridSize(of: pane.paneID, in: pane.windowController)
        return AgentIPCResponseResult(paneRead: PaneReadResult(
            paneID: pane.paneID.rawValue,
            worklaneID: pane.worklaneID.rawValue,
            windowID: pane.windowID?.rawValue,
            columns: grid?.columns,
            rows: grid?.rows,
            includesScrollback: options.includeScrollback,
            lineLimit: options.lineLimit,
            text: text
        ))
    }

    // MARK: - helpers

    @MainActor
    static func resolve(reference: String?, target: AgentIPCTarget) throws -> ResolvedPane {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let routed = PaneIPCHandler.resolveTarget(target, appDelegate: appDelegate)
        else {
            throw PaneRoutingError.paneNotFound
        }
        let controller = routed.windowController
        let worklaneID = routed.target.worklaneID
        let paneID: PaneID
        if let reference {
            let normalized = reference.hasPrefix("%") ? String(reference.dropFirst()) : reference
            guard let resolved = controller.resolvePaneID(normalized, in: worklaneID) else {
                throw PaneRoutingError.paneNotFound
            }
            paneID = resolved
        } else {
            paneID = routed.target.paneID
        }
        guard controller.containsPane(worklaneID: worklaneID, paneID: paneID) else {
            throw PaneRoutingError.paneNotFound
        }
        return ResolvedPane(
            windowController: controller,
            windowID: routed.target.windowID,
            worklaneID: worklaneID,
            paneID: paneID
        )
    }

    private static func onMain<T: Sendable>(_ operation: @MainActor () throws -> T) throws -> T {
        if Thread.isMainThread {
            return try MainActorShim.assumeIsolated(operation)
        }
        var result: Result<T, Error>!
        DispatchQueue.main.sync {
            result = MainActorShim.assumeIsolated {
                Result { try operation() }
            }
        }
        return try result.get()
    }
}
