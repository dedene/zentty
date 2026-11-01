import AppKit
import Carbon.HIToolbox

/// What a key press means in the palette. The panel's key monitor turns every keyDown into one
/// of these, or lets it through to the search field when there is none.
enum AgentHistoryKeyCommand: Equatable {
    case moveSelection(Int)
    case primary
    case secondary
    case toggleTranscript
    case closeTranscript
    case toggleScope
    /// Close transcript, then clear the query, then close the palette (the view model decides).
    case escape
    case copyResumeCommand
    case closePalette
    case sheetMove(Int)
    case sheetConfirm
    case sheetCancel
    case consentConfirm
}

/// The palette state a key's meaning depends on, read from the field editor and the model.
struct AgentHistoryKeyContext: Equatable {
    var caretAtEndOfQuery = true
    var hasTextSelection = false
    /// An input method is composing; every key belongs to it.
    var hasMarkedText = false
    var isTranscriptShown = false
    var isSheetShown = false
    /// False while the consent card (or another non-results body) is shown.
    var bodyIsResults = true
}

/// Maps a keyDown to a palette command. Pure; see the spec's keyboard table (§4.3). Space is
/// never a command: the field keeps focus and Space types a space.
enum AgentHistoryKeyRouter {
    static func command(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        context: AgentHistoryKeyContext
    ) -> AgentHistoryKeyCommand? {
        if context.hasMarkedText {
            return nil
        }
        // Arrow keys carry .numericPad/.function and Caps Lock may be on: only these four count.
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        let key = Key(keyCode: Int(keyCode))
        let character = charactersIgnoringModifiers?.lowercased()

        if mods == .command, character == "w" {
            return .closePalette
        }
        if context.isSheetShown {
            return sheetCommand(key, mods: mods)
        }
        if !context.bodyIsResults {
            return consentCommand(key, mods: mods)
        }
        return resultsCommand(key, mods: mods, character: character, context: context)
    }

    private static func sheetCommand(_ key: Key, mods: NSEvent.ModifierFlags) -> AgentHistoryKeyCommand? {
        guard mods.isEmpty else {
            return nil
        }
        switch key {
        case .up: return .sheetMove(-1)
        case .down: return .sheetMove(1)
        case .return: return .sheetConfirm
        case .escape: return .sheetCancel
        default: return nil
        }
    }

    private static func consentCommand(_ key: Key, mods: NSEvent.ModifierFlags) -> AgentHistoryKeyCommand? {
        guard mods.isEmpty else {
            return nil
        }
        switch key {
        case .return: return .consentConfirm
        case .escape: return .escape
        default: return nil
        }
    }

    private static func resultsCommand(
        _ key: Key,
        mods: NSEvent.ModifierFlags,
        character: String?,
        context: AgentHistoryKeyContext
    ) -> AgentHistoryKeyCommand? {
        switch (key, mods) {
        case (.up, []):
            return .moveSelection(-1)
        case (.down, []):
            return .moveSelection(1)
        case (.return, []):
            return .primary
        case (.return, .command):
            return .secondary
        case (.tab, []), (.tab, .shift):
            return .toggleScope
        case (.escape, []):
            return .escape
        case (.right, []):
            return context.caretAtEndOfQuery && !context.hasTextSelection ? .toggleTranscript : nil
        case (.left, []):
            return context.isTranscriptShown && context.caretAtEndOfQuery ? .closeTranscript : nil
        default:
            break
        }
        guard mods == .command else {
            return nil
        }
        switch character {
        case "y":
            return .toggleTranscript
        case "c":
            return context.hasTextSelection ? nil : .copyResumeCommand
        default:
            return nil
        }
    }

    private enum Key {
        case up, down, left, right, `return`, tab, escape, other

        init(keyCode: Int) {
            switch keyCode {
            case kVK_UpArrow: self = .up
            case kVK_DownArrow: self = .down
            case kVK_LeftArrow: self = .left
            case kVK_RightArrow: self = .right
            case kVK_Return, kVK_ANSI_KeypadEnter: self = .return
            case kVK_Tab: self = .tab
            case kVK_Escape: self = .escape
            default: self = .other
            }
        }
    }
}
