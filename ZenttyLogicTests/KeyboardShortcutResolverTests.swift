import Carbon.HIToolbox
import XCTest
@testable import Zentty

final class KeyboardShortcutResolverTests: XCTestCase {
    func test_registry_includes_toggle_sidebar_command_with_general_category_and_command_s_default() {
        let definition = AppCommandRegistry.definition(for: .toggleSidebar)

        XCTAssertEqual(definition.title, "Toggle Sidebar")
        XCTAssertEqual(definition.category, .general)
        XCTAssertEqual(
            definition.defaultShortcut,
            .init(key: .character("s"), modifiers: [.command])
        )
    }

    func test_registry_includes_find_commands_with_standard_shortcuts() {
        XCTAssertEqual(AppCommandRegistry.definition(for: .find).title, "Find")
        XCTAssertEqual(
            AppCommandRegistry.definition(for: .find).defaultShortcut,
            .init(key: .character("f"), modifiers: [.command])
        )
        XCTAssertEqual(
            AppCommandRegistry.definition(for: .useSelectionForFind).defaultShortcut,
            .init(key: .character("e"), modifiers: [.command])
        )
        XCTAssertEqual(
            AppCommandRegistry.definition(for: .findNext).defaultShortcut,
            .init(key: .character("g"), modifiers: [.command])
        )
        XCTAssertEqual(
            AppCommandRegistry.definition(for: .findPrevious).defaultShortcut,
            .init(key: .character("g"), modifiers: [.command, .shift])
        )
    }

    func test_resolves_default_shortcuts_from_registry() {
        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .character("t"), modifiers: [.command]),
                shortcuts: .default
            ),
            .newWorklane
        )

        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .character("s"), modifiers: [.command]),
                shortcuts: .default
            ),
            .toggleSidebar
        )
        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .character("f"), modifiers: [.command]),
                shortcuts: .default
            ),
            .find
        )
        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .character("e"), modifiers: [.command]),
                shortcuts: .default
            ),
            .useSelectionForFind
        )
        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .character("g"), modifiers: [.command]),
                shortcuts: .default
            ),
            .findNext
        )
        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .character("g"), modifiers: [.command, .shift]),
                shortcuts: .default
            ),
            .findPrevious
        )
        XCTAssertNil(
            KeyboardShortcutResolver.resolve(
                .init(key: .character("f"), modifiers: [.command, .shift]),
                shortcuts: .default
            )
        )
    }

    func test_resolves_arrange_default_shortcuts_from_registry() {
        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .character("2"), modifiers: [.command]),
                shortcuts: .default
            ),
            .pane(.arrangeHorizontally(.halfWidth))
        )

        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .character("3"), modifiers: [.command, .shift]),
                shortcuts: .default
            ),
            .pane(.arrangeVertically(.threePerColumn))
        )
    }

    func test_registry_exposes_sidebar_order_focus_commands_and_drops_first_last_column_commands() {
        let titles = Set(AppCommandRegistry.definitions.map(\.title))

        XCTAssertTrue(titles.contains("Focus Previous Pane"))
        XCTAssertTrue(titles.contains("Focus Next Pane"))
        XCTAssertFalse(titles.contains("Focus First Column"))
        XCTAssertFalse(titles.contains("Focus Last Column"))
    }

    func test_resolves_remapped_focus_and_resize_arrow_shortcuts_from_registry() {
        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .rightArrow, modifiers: [.command]),
                shortcuts: .default
            ),
            .pane(.focusRight)
        )

        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .upArrow, modifiers: [.command]),
                shortcuts: .default
            ),
            .pane(.focusUp)
        )

        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .downArrow, modifiers: [.command, .option]),
                shortcuts: .default
            ),
            .pane(.focusNextPaneBySidebarOrder)
        )

        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .leftArrow, modifiers: [.command, .option, .shift]),
                shortcuts: .default
            ),
            .pane(.resizeLeft)
        )

        XCTAssertNil(
            KeyboardShortcutResolver.resolve(
                .init(key: .leftArrow, modifiers: [.command, .control, .option]),
                shortcuts: .default
            )
        )
    }

    func test_command_availability_uses_total_pane_count_for_sidebar_order_navigation() {
        let available = CommandAvailabilityResolver.availableCommandIDs(
            worklaneCount: 2,
            activePaneCount: 1,
            totalPaneCount: 2,
            focusedPaneHasRememberedSearch: false
        )

        XCTAssertTrue(available.contains(.focusPreviousPane))
        XCTAssertTrue(available.contains(.focusNextPane))
        XCTAssertTrue(available.contains(.focusUpInColumn))
        XCTAssertTrue(available.contains(.focusDownInColumn))
        XCTAssertFalse(available.contains(.findNext))
        XCTAssertFalse(available.contains(.findPrevious))
    }

    func test_command_availability_enables_search_navigation_when_focused_pane_has_remembered_search() {
        let available = CommandAvailabilityResolver.availableCommandIDs(
            worklaneCount: 1,
            activePaneCount: 1,
            totalPaneCount: 1,
            focusedPaneHasRememberedSearch: true
        )

        XCTAssertTrue(available.contains(.find))
        XCTAssertTrue(available.contains(.useSelectionForFind))
        XCTAssertTrue(available.contains(.findNext))
        XCTAssertTrue(available.contains(.findPrevious))
    }

    func test_resolves_remapped_shortcuts_from_overrides() {
        let shortcuts = AppConfig.Shortcuts(
            bindings: [
                ShortcutBindingOverride(
                    commandID: .toggleSidebar,
                    shortcut: .init(key: .character("b"), modifiers: [.command])
                )
            ]
        )

        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .character("b"), modifiers: [.command]),
                shortcuts: shortcuts
            ),
            .toggleSidebar
        )
        XCTAssertNil(
            KeyboardShortcutResolver.resolve(
                .init(key: .character("s"), modifiers: [.command]),
                shortcuts: shortcuts
            )
        )
    }

    func test_unbound_commands_do_not_resolve() {
        let shortcuts = AppConfig.Shortcuts(
            bindings: [
                ShortcutBindingOverride(commandID: .toggleSidebar, shortcut: nil)
            ]
        )

        XCTAssertNil(
            KeyboardShortcutResolver.resolve(
                .init(key: .character("s"), modifiers: [.command]),
                shortcuts: shortcuts
            )
        )
    }

    func test_conflicting_shortcut_override_is_rejected_in_effective_bindings() {
        let manager = ShortcutManager(
            shortcuts: AppConfig.Shortcuts(
                bindings: [
                    ShortcutBindingOverride(
                        commandID: .toggleSidebar,
                        shortcut: .init(key: .character("t"), modifiers: [.command])
                    )
                ]
            )
        )

        XCTAssertEqual(manager.shortcut(for: .toggleSidebar), .init(key: .character("s"), modifiers: [.command]))
        XCTAssertEqual(manager.commandID(for: .init(key: .character("t"), modifiers: [.command])), .newWorklane)
    }

    func test_bindings_without_command_control_or_option_are_rejected() {
        let shortcuts = AppConfig.Shortcuts(
            bindings: [
                ShortcutBindingOverride(
                    commandID: .toggleSidebar,
                    shortcut: .init(key: .character("a"), modifiers: [])
                )
            ]
        )

        let manager = ShortcutManager(shortcuts: shortcuts)

        XCTAssertEqual(manager.shortcut(for: .toggleSidebar), .init(key: .character("s"), modifiers: [.command]))
        XCTAssertNil(manager.commandID(for: .init(key: .character("a"), modifiers: [])))
    }

    func test_returns_nil_for_unhandled_shortcuts() {
        let action = KeyboardShortcutResolver.resolve(
            .init(key: .character("k"), modifiers: [.command]),
            shortcuts: .default
        )

        XCTAssertNil(action)
    }

    func test_left_hand_preset_reclaims_standard_find_shortcuts_and_rehomes_colliding_commands() {
        let presetBindings = ShortcutPresetResolver(
            sourceProvider: StubKeyboardPreviewSourceProvider(
                geometry: .ansi,
                outputs: [
                    .init(keyCode: UInt16(kVK_ANSI_B), modifiers: [], value: "b"),
                    .init(keyCode: UInt16(kVK_ANSI_E), modifiers: [], value: "e"),
                    .init(keyCode: UInt16(kVK_ANSI_F), modifiers: [], value: "f"),
                    .init(keyCode: UInt16(kVK_ANSI_G), modifiers: [], value: "g"),
                    .init(keyCode: UInt16(kVK_ANSI_N), modifiers: [], value: "n"),
                    .init(keyCode: UInt16(kVK_ANSI_R), modifiers: [], value: "r"),
                    .init(keyCode: UInt16(kVK_ANSI_X), modifiers: [], value: "x"),
                    .init(keyCode: UInt16(kVK_ANSI_LeftBracket), modifiers: [], value: "["),
                    .init(keyCode: UInt16(kVK_ANSI_RightBracket), modifiers: [], value: "]"),
                ]
            )
        ).resolve(.leftHand)
        let manager = ShortcutManager(shortcuts: .init(bindings: presetBindings))

        XCTAssertEqual(manager.shortcut(for: .find), .init(key: .character("f"), modifiers: [.command]))
        XCTAssertEqual(manager.shortcut(for: .useSelectionForFind), .init(key: .character("e"), modifiers: [.command]))
        XCTAssertEqual(manager.shortcut(for: .findNext), .init(key: .character("g"), modifiers: [.command]))
        XCTAssertEqual(manager.shortcut(for: .findPrevious), .init(key: .character("g"), modifiers: [.command, .shift]))
        XCTAssertEqual(manager.shortcut(for: .showCommandPalette), .init(key: .character("x"), modifiers: [.command]))
        XCTAssertEqual(manager.shortcut(for: .toggleSidebar), .init(key: .character("b"), modifiers: [.command]))
        XCTAssertEqual(manager.shortcut(for: .splitHorizontally), .init(key: .character("r"), modifiers: [.command]))
        XCTAssertEqual(manager.shortcut(for: .splitVertically), .init(key: .character("r"), modifiers: [.command, .shift]))
        XCTAssertEqual(manager.shortcut(for: .navigateBack), .init(key: .character("["), modifiers: [.command]))
        XCTAssertEqual(manager.shortcut(for: .navigateForward), .init(key: .character("]"), modifiers: [.command]))
        XCTAssertEqual(manager.shortcut(for: .newWorklane), .init(key: .character("n"), modifiers: [.command]))
    }

    func test_right_hand_preset_keeps_standard_find_shortcuts_active() {
        let presetBindings = ShortcutPresetResolver(
            sourceProvider: StubKeyboardPreviewSourceProvider(
                geometry: .ansi,
                outputs: [
                    .init(keyCode: UInt16(kVK_ANSI_E), modifiers: [], value: "e"),
                    .init(keyCode: UInt16(kVK_ANSI_F), modifiers: [], value: "f"),
                    .init(keyCode: UInt16(kVK_ANSI_G), modifiers: [], value: "g"),
                ]
            )
        ).resolve(.rightHand)
        let manager = ShortcutManager(shortcuts: .init(bindings: presetBindings))

        XCTAssertEqual(manager.shortcut(for: .find), .init(key: .character("f"), modifiers: [.command]))
        XCTAssertEqual(manager.shortcut(for: .useSelectionForFind), .init(key: .character("e"), modifiers: [.command]))
        XCTAssertEqual(manager.shortcut(for: .findNext), .init(key: .character("g"), modifiers: [.command]))
        XCTAssertEqual(manager.shortcut(for: .findPrevious), .init(key: .character("g"), modifiers: [.command, .shift]))
    }

    func test_preview_resolver_maps_option_modified_character_to_physical_key() {
        let resolver = KeyboardLayoutPreviewResolver(
            sourceProvider: StubKeyboardPreviewSourceProvider(
                geometry: .iso,
                outputs: [
                    StubKeyboardPreviewSourceProvider.Output(
                        keyCode: UInt16(kVK_ANSI_5),
                        modifiers: [],
                        value: "5"
                    ),
                    StubKeyboardPreviewSourceProvider.Output(
                        keyCode: UInt16(kVK_ANSI_5),
                        modifiers: [.option],
                        value: "["
                    ),
                ]
            )
        )

        let model = resolver.resolve(
            shortcut: .init(key: .character("["), modifiers: [.command, .option])
        )

        XCTAssertEqual(model.geometry, .iso)
        XCTAssertEqual(model.primaryHighlightedKeyCode, UInt16(kVK_ANSI_5))
        XCTAssertEqual(
            model.highlightedModifierKeyCodes,
            [UInt16(kVK_Command), UInt16(kVK_RightCommand), UInt16(kVK_Option), UInt16(kVK_RightOption)]
        )
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_Command)), .primary)
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_RightCommand)), .secondary)
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_Option)), .primary)
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_RightOption)), .secondary)
    }

    func test_preview_resolver_maps_arrow_shortcuts_directly() {
        let resolver = KeyboardLayoutPreviewResolver(
            sourceProvider: StubKeyboardPreviewSourceProvider(geometry: .ansi, outputs: [])
        )

        let model = resolver.resolve(
            shortcut: .init(key: .rightArrow, modifiers: [.command, .option])
        )

        XCTAssertEqual(model.primaryHighlightedKeyCode, UInt16(kVK_RightArrow))
        XCTAssertEqual(
            model.highlightedModifierKeyCodes,
            [UInt16(kVK_Command), UInt16(kVK_RightCommand), UInt16(kVK_Option), UInt16(kVK_RightOption)]
        )
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_Command)), .secondary)
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_RightCommand)), .primary)
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_Option)), .secondary)
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_RightOption)), .primary)
    }

    func test_preview_resolver_leaves_primary_key_empty_when_character_cannot_be_mapped() {
        let resolver = KeyboardLayoutPreviewResolver(
            sourceProvider: StubKeyboardPreviewSourceProvider(geometry: .ansi, outputs: [])
        )

        let model = resolver.resolve(
            shortcut: .init(key: .character("["), modifiers: [.command, .option])
        )

        XCTAssertNil(model.primaryHighlightedKeyCode)
        XCTAssertEqual(
            model.highlightedModifierKeyCodes,
            [UInt16(kVK_Command), UInt16(kVK_RightCommand), UInt16(kVK_Option), UInt16(kVK_RightOption)]
        )
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_Command)), .primary)
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_RightCommand)), .primary)
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_Option)), .primary)
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_RightOption)), .primary)
    }

    func test_preview_resolver_prefers_left_command_for_left_side_character_shortcut() {
        let resolver = KeyboardLayoutPreviewResolver(
            sourceProvider: StubKeyboardPreviewSourceProvider(
                geometry: .ansi,
                outputs: [
                    .init(keyCode: UInt16(kVK_ANSI_W), modifiers: [], value: "w")
                ]
            )
        )

        let model = resolver.resolve(shortcut: .init(key: .character("w"), modifiers: [.command]))

        XCTAssertEqual(model.primaryHighlightedKeyCode, UInt16(kVK_ANSI_W))
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_Command)), .primary)
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_RightCommand)), .secondary)
    }

    func test_preview_resolver_prefers_right_side_modifiers_for_right_side_character_shortcut() {
        let resolver = KeyboardLayoutPreviewResolver(
            sourceProvider: StubKeyboardPreviewSourceProvider(
                geometry: .ansi,
                outputs: [
                    .init(keyCode: UInt16(kVK_ANSI_P), modifiers: [], value: "p")
                ]
            )
        )

        let model = resolver.resolve(shortcut: .init(key: .character("p"), modifiers: [.command, .shift]))

        XCTAssertEqual(model.primaryHighlightedKeyCode, UInt16(kVK_ANSI_P))
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_Command)), .secondary)
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_RightCommand)), .primary)
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_Shift)), .secondary)
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_RightShift)), .primary)
    }

    func test_preview_resolver_does_not_render_right_control_key() {
        let resolver = KeyboardLayoutPreviewResolver(
            sourceProvider: StubKeyboardPreviewSourceProvider(geometry: .ansi, outputs: [])
        )

        let model = resolver.resolve(shortcut: nil)

        XCTAssertFalse(
            model.rows.contains { row in
                row.slots.contains(where: { $0.keyCode == UInt16(kVK_RightControl) && $0.isSpacer == false })
            }
        )
    }

    func test_preview_resolver_highlights_control_only_on_left_side() {
        let resolver = KeyboardLayoutPreviewResolver(
            sourceProvider: StubKeyboardPreviewSourceProvider(
                geometry: .ansi,
                outputs: [
                    .init(keyCode: UInt16(kVK_ANSI_W), modifiers: [], value: "w")
                ]
            )
        )

        let model = resolver.resolve(shortcut: .init(key: .character("w"), modifiers: [.control]))

        XCTAssertEqual(model.primaryHighlightedKeyCode, UInt16(kVK_ANSI_W))
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_Control)), .primary)
        XCTAssertEqual(model.highlightStyle(for: UInt16(kVK_RightControl)), .none)
        XCTAssertEqual(model.highlightedModifierKeyCodes, [UInt16(kVK_Control)])
    }

    func test_preview_resolver_places_up_arrow_above_bottom_arrow_cluster() throws {
        let resolver = KeyboardLayoutPreviewResolver(
            sourceProvider: StubKeyboardPreviewSourceProvider(geometry: .ansi, outputs: [])
        )

        let model = resolver.resolve(shortcut: nil)

        let upRow = try XCTUnwrap(rowIndex(of: UInt16(kVK_UpArrow), in: model))
        let leftRow = try XCTUnwrap(rowIndex(of: UInt16(kVK_LeftArrow), in: model))
        let downRow = try XCTUnwrap(rowIndex(of: UInt16(kVK_DownArrow), in: model))
        let rightRow = try XCTUnwrap(rowIndex(of: UInt16(kVK_RightArrow), in: model))

        XCTAssertEqual(upRow, leftRow - 1)
        XCTAssertEqual(leftRow, downRow)
        XCTAssertEqual(leftRow, rightRow)
    }

    func test_preview_resolver_places_bottom_arrow_keys_as_rightmost_visible_cluster() throws {
        let resolver = KeyboardLayoutPreviewResolver(
            sourceProvider: StubKeyboardPreviewSourceProvider(geometry: .ansi, outputs: [])
        )

        let model = resolver.resolve(shortcut: nil)
        let bottomArrowRow = try XCTUnwrap(rowIndex(of: UInt16(kVK_RightArrow), in: model))
        let visibleKeyCodes = model.rows[bottomArrowRow].slots
            .filter { $0.label.isEmpty == false }
            .map(\.keyCode)

        XCTAssertEqual(
            Array(visibleKeyCodes.suffix(3)),
            [UInt16(kVK_LeftArrow), UInt16(kVK_DownArrow), UInt16(kVK_RightArrow)]
        )
    }

    func test_preview_resolver_uses_uniform_row_widths_for_compact_keyboard_outline() {
        let resolver = KeyboardLayoutPreviewResolver(
            sourceProvider: StubKeyboardPreviewSourceProvider(geometry: .jis, outputs: [])
        )

        let model = resolver.resolve(shortcut: nil)
        XCTAssertEqual(model.rows.prefix(4).map(\.alignment), [.trailing, .trailing, .trailing, .trailing])
        XCTAssertEqual(model.rows.suffix(2).map(\.alignment), [.center, .center])

        let mainBlockSpans = (0...4).map { rowSpanUnits(for: model.rows[$0].slots) }
        XCTAssertTrue(mainBlockSpans.dropFirst().allSatisfy { abs($0 - mainBlockSpans[0]) < 0.001 })
    }

    func test_preview_resolver_centers_up_arrow_over_down_arrow() throws {
        let resolver = KeyboardLayoutPreviewResolver(
            sourceProvider: StubKeyboardPreviewSourceProvider(geometry: .ansi, outputs: [])
        )

        let model = resolver.resolve(shortcut: nil)

        let upCenter = try XCTUnwrap(horizontalCenter(of: UInt16(kVK_UpArrow), in: model))
        let downCenter = try XCTUnwrap(horizontalCenter(of: UInt16(kVK_DownArrow), in: model))

        XCTAssertEqual(upCenter, downCenter, accuracy: 0.001)
    }

    func test_preview_resolver_aligns_main_keyboard_rows_to_shared_right_edge() {
        let resolver = KeyboardLayoutPreviewResolver(
            sourceProvider: StubKeyboardPreviewSourceProvider(geometry: .ansi, outputs: [])
        )

        let model = resolver.resolve(shortcut: nil)
        let topRowSpans = (0...3).map { rowSpanUnits(for: model.rows[$0].slots) }

        XCTAssertEqual(model.rows.prefix(4).map(\.alignment), [.trailing, .trailing, .trailing, .trailing])
        XCTAssertTrue(topRowSpans.dropFirst().allSatisfy { abs($0 - topRowSpans[0]) < 0.001 })
        XCTAssertEqual(model.rows[0].slots[0].widthUnits, 1.0, accuracy: 0.001)
        XCTAssertGreaterThan(model.rows[1].slots[0].widthUnits, 1.5)
        XCTAssertGreaterThan(model.rows[2].slots[0].widthUnits, 1.8)
        XCTAssertGreaterThan(model.rows[3].slots[0].widthUnits, 2.1)
    }

    func test_preview_resolver_aligns_main_keyboard_rows_to_shared_left_edge() {
        let resolver = KeyboardLayoutPreviewResolver(
            sourceProvider: StubKeyboardPreviewSourceProvider(geometry: .ansi, outputs: [])
        )

        let model = resolver.resolve(shortcut: nil)
        let mainBlockSpans = (0...4).map { rowSpanUnits(for: model.rows[$0].slots) }

        XCTAssertEqual(model.rows[4].alignment, .center)
        XCTAssertTrue(mainBlockSpans.dropFirst().allSatisfy { abs($0 - mainBlockSpans[0]) < 0.001 })
    }

    func test_preview_resolver_stretches_leading_keys_in_main_block() {
        let resolver = KeyboardLayoutPreviewResolver(
            sourceProvider: StubKeyboardPreviewSourceProvider(geometry: .ansi, outputs: [])
        )

        let model = resolver.resolve(shortcut: nil)

        XCTAssertGreaterThan(model.rows[1].slots[0].widthUnits, 1.5)
        XCTAssertGreaterThan(model.rows[2].slots[0].widthUnits, 1.8)
        XCTAssertGreaterThan(model.rows[3].slots[0].widthUnits, 2.1)
    }
}

private struct StubKeyboardPreviewSourceProvider: KeyboardPreviewSourceProviding {
    struct Output {
        let keyCode: UInt16
        let modifiers: Set<KeyboardModifier>
        let value: String
    }

    let geometry: KeyboardPreviewGeometry
    let outputs: [Output]

    func currentGeometry() -> KeyboardPreviewGeometry {
        geometry
    }

    func output(for keyCode: UInt16, modifiers: Set<KeyboardModifier>) -> String? {
        outputs.first(where: { $0.keyCode == keyCode && $0.modifiers == modifiers })?.value
    }

    func displayLabel(for keyCode: UInt16) -> String? {
        output(for: keyCode, modifiers: [])
    }
}

private func rowIndex(of keyCode: UInt16, in model: KeyboardShortcutPreviewModel) -> Int? {
    model.rows.firstIndex { row in
        row.slots.contains(where: { $0.keyCode == keyCode })
    }
}

private func rowSpanUnits(for row: [KeyboardPreviewKeySlot]) -> CGFloat {
    let widths = row.reduce(CGFloat.zero) { $0 + $1.widthUnits }
    let adjacencyCount = zip(row, row.dropFirst()).reduce(0) { count, pair in
        count + (pair.0.isSpacer == false && pair.1.isSpacer == false ? 1 : 0)
    }

    return widths + (CGFloat(adjacencyCount) * KeyboardPreviewLayoutMetrics.interKeySpacingUnits)
}

private func horizontalCenter(of keyCode: UInt16, in model: KeyboardShortcutPreviewModel) -> CGFloat? {
    let maxRowWidth = model.rows.map { rowSpanUnits(for: $0.slots) }.max() ?? 0

    for row in model.rows {
        let rowWidth = rowSpanUnits(for: row.slots)
        var cursor: CGFloat
        switch row.alignment {
        case .center:
            cursor = (maxRowWidth - rowWidth) / 2
        case .trailing:
            cursor = maxRowWidth - rowWidth
        }

        for (index, slot) in row.slots.enumerated() {
            if slot.keyCode == keyCode {
                return cursor + (slot.widthUnits / 2)
            }

            cursor += slot.widthUnits
            if index < row.slots.count - 1, slot.isSpacer == false, row.slots[index + 1].isSpacer == false {
                cursor += KeyboardPreviewLayoutMetrics.interKeySpacingUnits
            }
        }
    }

    return nil
}

private func visibleRightEdge(ofRowAt index: Int, in model: KeyboardShortcutPreviewModel) -> CGFloat? {
    guard model.rows.indices.contains(index) else {
        return nil
    }

    let row = model.rows[index].slots
    var cursor = CGFloat.zero
    var rightEdge: CGFloat?
    for (slotIndex, slot) in row.enumerated() {
        let slotStart = cursor
        let slotEnd = slotStart + slot.widthUnits
        if slot.isSpacer == false, slot.label.isEmpty == false {
            rightEdge = slotEnd
        }

        cursor = slotEnd
        if slotIndex < row.count - 1, slot.isSpacer == false, row[slotIndex + 1].isSpacer == false {
            cursor += KeyboardPreviewLayoutMetrics.interKeySpacingUnits
        }
    }

    return rightEdge
}

private func renderedVisibleRightEdge(ofRowAt index: Int, in model: KeyboardShortcutPreviewModel) -> CGFloat? {
    guard let localRightEdge = visibleRightEdge(ofRowAt: index, in: model) else {
        return nil
    }

    let maxRowWidth = model.rows.map { rowSpanUnits(for: $0.slots) }.max() ?? 0
    let row = model.rows[index]
    let rowWidth = rowSpanUnits(for: row.slots)
    let startX: CGFloat
    switch row.alignment {
    case .center:
        startX = (maxRowWidth - rowWidth) / 2
    case .trailing:
        startX = maxRowWidth - rowWidth
    }
    return startX + localRightEdge
}

private func renderedVisibleLeftEdge(ofRowAt index: Int, in model: KeyboardShortcutPreviewModel) -> CGFloat? {
    guard model.rows.indices.contains(index) else {
        return nil
    }

    let maxRowWidth = model.rows.map { rowSpanUnits(for: $0.slots) }.max() ?? 0
    let row = model.rows[index]
    let rowWidth = rowSpanUnits(for: row.slots)
    let startX: CGFloat
    switch row.alignment {
    case .center:
        startX = (maxRowWidth - rowWidth) / 2
    case .trailing:
        startX = maxRowWidth - rowWidth
    }

    var cursor = startX
    for (slotIndex, slot) in row.slots.enumerated() {
        if slot.isSpacer == false, slot.label.isEmpty == false {
            return cursor
        }

        cursor += slot.widthUnits
        if slotIndex < row.slots.count - 1, slot.isSpacer == false, row.slots[slotIndex + 1].isSpacer == false {
            cursor += KeyboardPreviewLayoutMetrics.interKeySpacingUnits
        }
    }

    return nil
}
