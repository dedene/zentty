import AppKit

/// What Settings › Agent History asks before acting.
enum AgentHistorySettingsConfirmation: Equatable {
    /// Turning Agent History on for the first time (spec §4.5 copy), with what the probe found.
    case enable(detected: [AgentHistoryDetectedSource])
    case deleteIndex
}

/// A Settings switch that writes `state.json`: Agent History itself or one source.
enum AgentHistorySettingsStateChange: Equatable {
    case history(on: Bool)
    case source(AgentHistoryAgent, on: Bool)
}

typealias AgentHistoryConfirmationPresenter = @MainActor (NSWindow?, AgentHistorySettingsConfirmation, @escaping (Bool) -> Void) -> Void
typealias AgentHistoryFolderPicker = @MainActor (NSWindow?, @escaping ([URL]) -> Void) -> Void
typealias AgentHistoryErrorPresenter = @MainActor (NSWindow?, _ title: String, _ message: String) -> Void

/// The real sheets behind the Settings section's injected presenters. Without a window there
/// is nothing to attach a sheet to: confirmations complete `false`, the picker with no folders.
@MainActor
enum AgentHistorySettingsAlerts {
    static func presentConfirmation(
        window: NSWindow?,
        confirmation: AgentHistorySettingsConfirmation,
        completion: @escaping (Bool) -> Void
    ) {
        guard let window else {
            completion(false)
            return
        }
        let copy = Self.copy(for: confirmation)
        let alert = NSAlert()
        alert.alertStyle = copy.isDestructive ? .critical : .informational
        alert.messageText = copy.title
        alert.informativeText = copy.message
        let confirm = alert.addButton(withTitle: copy.confirmTitle)
        confirm.hasDestructiveAction = copy.isDestructive
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

    static func pickFolders(window: NSWindow?, completion: @escaping ([URL]) -> Void) {
        guard let window else {
            completion([])
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Exclude"
        panel.message = "Sessions that ran inside these folders are never indexed."
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.urls : [])
        }
    }

    static func presentError(window: NSWindow?, title: String, message: String) {
        guard let window else {
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    /// What to tell the user when "Delete Index and Turn Off" didn't delete; nil when it did.
    static func deleteFailureMessage(_ outcome: AgentHistoryDisableOutcome) -> String? {
        switch outcome {
        case .deleted, .turnedOff:
            return nil
        case .refusedAnotherInstance:
            return "Another running copy of Zentty is using Agent History, so nothing was deleted. Quit it, or turn Agent History off there, then try again."
        case .failed:
            return "Zentty couldn't remove the index from this Mac. Try again."
        }
    }

    /// What to tell the user when a switch change didn't reach `state.json`; nil when it did.
    static func stateChangeFailure(
        _ outcome: AgentHistoryStateChangeOutcome,
        _ change: AgentHistorySettingsStateChange
    ) -> (title: String, message: String)? {
        let title = "Couldn't save this change"
        switch outcome {
        case .saved:
            return nil
        case .appliedButNotSaved:
            let subject: String
            switch change {
            case .history:
                subject = "Agent History is off"
            case .source(let agent, _):
                subject = "\(agent.displayName) is off in Agent History"
            }
            return (title, "\(subject) for now, but Zentty couldn't save that. It may turn back on the next time Zentty starts.")
        case .notSaved:
            return (title, "Zentty couldn't save Agent History's settings, so nothing changed. Check that your disk has free space, then try again.")
        case .refusedConfigUnreadable:
            return ("Fix config.toml first", AgentHistoryConsentModel.configUnreadableError)
        }
    }

    struct Copy: Equatable {
        let title: String
        let message: String
        let confirmTitle: String
        let isDestructive: Bool
    }

    static func copy(
        for confirmation: AgentHistorySettingsConfirmation,
        formatting: AgentHistoryFormatting = AgentHistoryFormatting()
    ) -> Copy {
        switch confirmation {
        case .enable(let detected):
            // The consent card's own text, so both surfaces count (and name the uncounted
            // database sources) the same way.
            let body = AgentHistoryConsentModel.make(detected: detected, excluded: [], retention: nil)
                .bodyText(formatting: formatting)
            return Copy(
                title: AgentHistoryConsentModel.title,
                message: body + "\n\n" + AgentHistoryConsentModel.footnote,
                confirmTitle: "Turn On",
                isDestructive: false
            )
        case .deleteIndex:
            return Copy(
                title: "Delete the Agent History index?",
                message: "This removes the index, the removed-sessions list and usage data from this Mac, and turns Agent History off. Your agents' own transcripts aren't touched.",
                confirmTitle: "Delete Index and Turn Off",
                isDestructive: true
            )
        }
    }
}
