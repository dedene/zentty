import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Zentty

final class AgentHistoryKeyRouterTests: XCTestCase {
    private let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]

    private func route(
        _ keyCode: Int,
        _ modifiers: NSEvent.ModifierFlags = [],
        _ characters: String? = nil,
        _ context: AgentHistoryKeyContext = AgentHistoryKeyContext()
    ) -> AgentHistoryKeyCommand? {
        AgentHistoryKeyRouter.command(
            keyCode: UInt16(keyCode),
            modifiers: modifiers,
            charactersIgnoringModifiers: characters,
            context: context
        )
    }

    func test_arrows_move_selection_ignoring_function_and_caps_lock_flags() {
        XCTAssertEqual(route(kVK_UpArrow, arrowFlags), .moveSelection(-1))
        XCTAssertEqual(route(kVK_DownArrow, arrowFlags.union(.capsLock)), .moveSelection(1))
        XCTAssertNil(route(kVK_DownArrow, arrowFlags.union(.shift)))
        XCTAssertNil(route(kVK_UpArrow, arrowFlags.union(.option)))
    }

    func test_return_and_keypad_enter_are_primary_and_command_return_is_secondary() {
        XCTAssertEqual(route(kVK_Return), .primary)
        XCTAssertEqual(route(kVK_ANSI_KeypadEnter, .numericPad), .primary)
        XCTAssertEqual(route(kVK_Return, .command), .secondary)
        XCTAssertEqual(route(kVK_ANSI_KeypadEnter, [.command, .numericPad]), .secondary)
        XCTAssertNil(route(kVK_Return, .option))
    }

    func test_right_arrow_toggles_transcript_only_at_end_without_selection() {
        XCTAssertEqual(route(kVK_RightArrow, arrowFlags), .toggleTranscript)
        XCTAssertNil(route(kVK_RightArrow, arrowFlags, nil, AgentHistoryKeyContext(caretAtEndOfQuery: false)))
        XCTAssertNil(route(kVK_RightArrow, arrowFlags, nil, AgentHistoryKeyContext(hasTextSelection: true)))
        XCTAssertNil(route(kVK_RightArrow, arrowFlags.union(.shift)))
    }

    func test_left_arrow_closes_transcript_only_when_shown_and_caret_at_end() {
        XCTAssertNil(route(kVK_LeftArrow, arrowFlags))
        XCTAssertEqual(
            route(kVK_LeftArrow, arrowFlags, nil, AgentHistoryKeyContext(isTranscriptShown: true)),
            .closeTranscript
        )
        XCTAssertNil(route(
            kVK_LeftArrow, arrowFlags, nil,
            AgentHistoryKeyContext(caretAtEndOfQuery: false, isTranscriptShown: true)
        ))
    }

    func test_command_y_always_toggles_transcript() {
        XCTAssertEqual(route(kVK_ANSI_Y, .command, "y"), .toggleTranscript)
        XCTAssertEqual(
            route(kVK_ANSI_Y, .command, "y", AgentHistoryKeyContext(caretAtEndOfQuery: false, hasTextSelection: true)),
            .toggleTranscript
        )
        // Layout-independent: the character decides, not the key position.
        XCTAssertEqual(route(kVK_ANSI_Z, .command, "y"), .toggleTranscript)
        XCTAssertNil(route(kVK_ANSI_Y, [], "y"))
    }

    func test_tab_and_shift_tab_toggle_scope() {
        XCTAssertEqual(route(kVK_Tab), .toggleScope)
        XCTAssertEqual(route(kVK_Tab, .shift, "\u{19}"), .toggleScope)
        XCTAssertNil(route(kVK_Tab, .control))
    }

    func test_escape_maps_to_escape_ladder() {
        XCTAssertEqual(route(kVK_Escape), .escape)
        XCTAssertEqual(route(kVK_Escape, [], nil, AgentHistoryKeyContext(isTranscriptShown: true)), .escape)
    }

    func test_command_c_copies_resume_command_only_without_text_selection() {
        XCTAssertEqual(route(kVK_ANSI_C, .command, "c"), .copyResumeCommand)
        XCTAssertNil(route(kVK_ANSI_C, .command, "c", AgentHistoryKeyContext(hasTextSelection: true)))
        XCTAssertNil(route(kVK_ANSI_C, [.command, .shift], "c"))
    }

    func test_command_w_closes_palette_in_every_body() {
        XCTAssertEqual(route(kVK_ANSI_W, .command, "w"), .closePalette)
        XCTAssertEqual(route(kVK_ANSI_W, .command, "w", AgentHistoryKeyContext(body: .consent)), .closePalette)
        XCTAssertEqual(route(kVK_ANSI_W, .command, "w", AgentHistoryKeyContext(isSheetShown: true)), .closePalette)
    }

    func test_marked_text_passes_every_key_through() {
        let composing = AgentHistoryKeyContext(hasMarkedText: true)
        for keyCode in [kVK_Return, kVK_Escape, kVK_UpArrow, kVK_DownArrow, kVK_Tab, kVK_RightArrow] {
            XCTAssertNil(route(keyCode, [], nil, composing), "keyCode \(keyCode)")
        }
        XCTAssertNil(route(kVK_ANSI_W, .command, "w", composing))
    }

    func test_sheet_maps_arrows_return_and_escape_only() {
        let sheet = AgentHistoryKeyContext(isSheetShown: true)
        XCTAssertEqual(route(kVK_UpArrow, arrowFlags, nil, sheet), .sheetMove(-1))
        XCTAssertEqual(route(kVK_DownArrow, arrowFlags, nil, sheet), .sheetMove(1))
        XCTAssertEqual(route(kVK_Return, [], nil, sheet), .sheetConfirm)
        XCTAssertEqual(route(kVK_ANSI_KeypadEnter, .numericPad, nil, sheet), .sheetConfirm)
        XCTAssertEqual(route(kVK_Escape, [], nil, sheet), .sheetCancel)
        XCTAssertNil(route(kVK_Tab, [], nil, sheet))
        XCTAssertNil(route(kVK_Return, .command, nil, sheet))
        XCTAssertNil(route(kVK_ANSI_Y, .command, "y", sheet))
    }

    func test_consent_maps_return_to_confirm_and_escape() {
        let consent = AgentHistoryKeyContext(body: .consent)
        XCTAssertEqual(route(kVK_Return, [], nil, consent), .consentConfirm)
        XCTAssertEqual(route(kVK_Escape, [], nil, consent), .escape)
        XCTAssertNil(route(kVK_DownArrow, arrowFlags, nil, consent))
        XCTAssertNil(route(kVK_Tab, [], nil, consent))
        XCTAssertNil(route(kVK_Return, .command, nil, consent))
    }

    /// The consent card has no search field: Tab, Shift-Tab and Space must reach its checkboxes
    /// and buttons, while ↩ still confirms (the default button) and esc declines.
    @MainActor
    func test_consent_leaves_tab_shift_tab_and_space_to_its_controls() {
        let consent = AgentHistoryKeyContext(body: .consent)
        XCTAssertNil(route(kVK_Tab, [], nil, consent))
        XCTAssertNil(route(kVK_Tab, .shift, nil, consent))
        XCTAssertNil(route(kVK_Space, [], " ", consent))
        for modifiers: NSEvent.ModifierFlags in [[], .shift] {
            XCTAssertFalse(
                AgentHistoryPanelController.swallowsUnroutedKey(modifiers: modifiers, context: consent),
                "the panel's key monitor lets the key through to the focused control"
            )
        }

        XCTAssertTrue(
            AgentHistoryViewModel.Body.consent.controlsTakeKeyboardFocus,
            "the consent card's source checkboxes, folder chips and buttons join the key-view loop"
        )
        XCTAssertFalse(AgentHistoryViewModel.Body.results.controlsTakeKeyboardFocus, "results keep focus in the search field")
        XCTAssertFalse(AgentHistoryViewModel.Body.loading.controlsTakeKeyboardFocus)
        XCTAssertFalse(AgentHistoryViewModel.Body.noAgents(checkedPaths: []).controlsTakeKeyboardFocus)
    }

    func test_history_off_routes_return_to_settings_and_escape_and_nothing_at_a_row() {
        let off = AgentHistoryKeyContext(body: .historyOff)
        XCTAssertEqual(route(kVK_Return, [], nil, off), .openSettings)
        XCTAssertEqual(route(kVK_ANSI_KeypadEnter, .numericPad, nil, off), .openSettings)
        XCTAssertEqual(route(kVK_Escape, [], nil, off), .escape)
        XCTAssertEqual(route(kVK_ANSI_W, .command, "w", off), .closePalette)

        XCTAssertNil(route(kVK_UpArrow, arrowFlags, nil, off))
        XCTAssertNil(route(kVK_DownArrow, arrowFlags, nil, off))
        XCTAssertNil(route(kVK_RightArrow, arrowFlags, nil, off))
        XCTAssertNil(route(kVK_LeftArrow, arrowFlags, nil, off))
        XCTAssertNil(route(kVK_Tab, [], nil, off), "Tab reaches the button with Full Keyboard Access")
        XCTAssertNil(route(kVK_Space, [], " ", off))
        XCTAssertNil(route(kVK_Return, .command, nil, off))
        XCTAssertNil(route(kVK_ANSI_C, .command, "c", off))
        XCTAssertNil(route(kVK_ANSI_Y, .command, "y", off))
    }

    @MainActor
    func test_history_off_stands_alone_and_its_button_takes_focus() {
        XCTAssertFalse(AgentHistoryViewModel.Body.historyOff.showsSearchChrome, "nothing can be searched while off")
        XCTAssertFalse(AgentHistoryViewModel.Body.consent.showsSearchChrome)
        XCTAssertTrue(AgentHistoryViewModel.Body.results.showsSearchChrome)
        XCTAssertTrue(AgentHistoryViewModel.Body.historyOff.controlsTakeKeyboardFocus)
    }

    func test_index_progress_only_routes_return_and_escape() {
        let progress = AgentHistoryKeyContext(isIndexProgressShown: true)
        XCTAssertEqual(route(kVK_Return, [], nil, progress), .primary)
        XCTAssertEqual(route(kVK_ANSI_KeypadEnter, .numericPad, nil, progress), .primary)
        XCTAssertEqual(route(kVK_Escape, [], nil, progress), .escape)
        XCTAssertEqual(route(kVK_ANSI_W, .command, "w", progress), .closePalette)

        XCTAssertNil(route(kVK_UpArrow, arrowFlags, nil, progress))
        XCTAssertNil(route(kVK_DownArrow, arrowFlags, nil, progress))
        XCTAssertNil(route(kVK_RightArrow, arrowFlags, nil, progress))
        XCTAssertNil(route(kVK_LeftArrow, arrowFlags, nil, progress))
        XCTAssertNil(route(kVK_Tab, [], nil, progress))
        XCTAssertNil(route(kVK_Tab, .shift, "\u{19}", progress))
        XCTAssertNil(route(kVK_Return, .command, nil, progress))
        XCTAssertNil(route(kVK_ANSI_C, .command, "c", progress), "⌘C copies the field's text, never a hidden row")
        XCTAssertNil(route(kVK_ANSI_Y, .command, "y", progress))
    }

    func test_unrelated_keys_and_shortcuts_pass_through() {
        XCTAssertNil(route(kVK_Space, [], " "))
        XCTAssertNil(route(kVK_ANSI_A, [], "a"))
        XCTAssertNil(route(kVK_ANSI_A, .command, "a"))
        XCTAssertNil(route(kVK_ANSI_V, .command, "v"))
        XCTAssertNil(route(kVK_ANSI_H, [.command, .shift], "h"))
        XCTAssertNil(route(kVK_Delete))
    }
}
