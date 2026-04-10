import XCTest
@testable import Zentty

final class SidebarStatusResolverTests: XCTestCase {
    // MARK: - shouldPreferInteractionPresentation

    func test_prefer_interaction_is_true_only_for_needs_input_with_specific_interaction() {
        XCTAssertTrue(SidebarStatusResolver.shouldPreferInteractionPresentation(
            attentionState: .needsInput,
            interactionKind: .approval
        ))
        XCTAssertTrue(SidebarStatusResolver.shouldPreferInteractionPresentation(
            attentionState: .needsInput,
            interactionKind: .question
        ))
    }

    func test_prefer_interaction_is_false_when_attention_is_not_needs_input() {
        XCTAssertFalse(SidebarStatusResolver.shouldPreferInteractionPresentation(
            attentionState: .running,
            interactionKind: .approval
        ))
        XCTAssertFalse(SidebarStatusResolver.shouldPreferInteractionPresentation(
            attentionState: nil,
            interactionKind: .approval
        ))
    }

    func test_prefer_interaction_is_false_when_interaction_kind_is_generic() {
        XCTAssertFalse(SidebarStatusResolver.shouldPreferInteractionPresentation(
            attentionState: .needsInput,
            interactionKind: .genericInput
        ))
    }

    func test_prefer_interaction_is_false_when_interaction_kind_is_nil() {
        XCTAssertFalse(SidebarStatusResolver.shouldPreferInteractionPresentation(
            attentionState: .needsInput,
            interactionKind: nil
        ))
    }

    // MARK: - resolveDisplayStatusText

    func test_display_text_passthrough_when_not_preferring_interaction() {
        let result = SidebarStatusResolver.resolveDisplayStatusText(
            statusText: "Running",
            attentionState: .running,
            interactionKind: nil,
            interactionLabel: nil
        )
        XCTAssertEqual(result, "Running")
    }

    func test_display_text_falls_through_to_interaction_label_when_status_is_nil() {
        let result = SidebarStatusResolver.resolveDisplayStatusText(
            statusText: nil,
            attentionState: nil,
            interactionKind: .approval,
            interactionLabel: "Needs approval"
        )
        XCTAssertEqual(result, "Needs approval")
    }

    func test_display_text_falls_through_to_default_label_when_label_is_nil() {
        let result = SidebarStatusResolver.resolveDisplayStatusText(
            statusText: nil,
            attentionState: nil,
            interactionKind: .approval,
            interactionLabel: nil
        )
        XCTAssertEqual(result, PaneInteractionKind.approval.defaultLabel)
    }

    func test_display_text_returns_empty_when_all_inputs_nil() {
        let result = SidebarStatusResolver.resolveDisplayStatusText(
            statusText: nil,
            attentionState: nil,
            interactionKind: nil,
            interactionLabel: nil
        )
        XCTAssertEqual(result, "")
    }

    func test_display_text_substitutes_generic_input_inside_status_text() {
        // When an explicit interaction (e.g. .approval) is active and the
        // raw status text contains the generic-input default label as a
        // substring, the display resolver should replace THAT SUBSTRING
        // with the interaction-specific label while preserving surrounding
        // prose (prefix like "╰ " and any trailing context).
        let generic = PaneInteractionKind.genericInput.defaultLabel
        let raw = "╰ \(generic) from Peter"

        let result = SidebarStatusResolver.resolveDisplayStatusText(
            statusText: raw,
            attentionState: .needsInput,
            interactionKind: .approval,
            interactionLabel: "Needs approval"
        )

        XCTAssertEqual(result, "╰ Needs approval from Peter")
    }

    func test_display_text_uses_preferred_label_when_status_does_not_contain_generic_label() {
        let result = SidebarStatusResolver.resolveDisplayStatusText(
            statusText: "Something unrelated",
            attentionState: .needsInput,
            interactionKind: .approval,
            interactionLabel: "Needs approval"
        )

        XCTAssertEqual(result, "Needs approval")
    }

    func test_display_text_uses_preferred_label_when_status_is_nil_and_interaction_active() {
        let result = SidebarStatusResolver.resolveDisplayStatusText(
            statusText: nil,
            attentionState: .needsInput,
            interactionKind: .approval,
            interactionLabel: "Needs approval"
        )

        XCTAssertEqual(result, "Needs approval")
    }

    // MARK: - resolveMeasurementStatusText

    func test_measurement_text_returns_nil_when_all_inputs_nil() {
        let result = SidebarStatusResolver.resolveMeasurementStatusText(
            statusText: nil,
            attentionState: nil,
            interactionKind: nil,
            interactionLabel: nil
        )
        XCTAssertNil(result)
    }

    func test_measurement_text_passthrough_when_not_preferring_interaction() {
        let result = SidebarStatusResolver.resolveMeasurementStatusText(
            statusText: "Running",
            attentionState: .running,
            interactionKind: nil,
            interactionLabel: nil
        )
        XCTAssertEqual(result, "Running")
    }

    func test_measurement_text_does_not_substitute_generic_label() {
        // Measurement must return the raw selection without substituting
        // anything into the status string, to preserve the legacy layout
        // behavior. Display does substitution; measurement does not.
        let generic = PaneInteractionKind.genericInput.defaultLabel
        let raw = "╰ \(generic) from Peter"

        let result = SidebarStatusResolver.resolveMeasurementStatusText(
            statusText: raw,
            attentionState: .needsInput,
            interactionKind: .approval,
            interactionLabel: "Needs approval"
        )

        // Interaction-preferred branch: returns interactionLabel directly.
        XCTAssertEqual(result, "Needs approval")
    }

    func test_measurement_text_prefers_interaction_label_over_raw_text() {
        let result = SidebarStatusResolver.resolveMeasurementStatusText(
            statusText: "Something else",
            attentionState: .needsInput,
            interactionKind: .approval,
            interactionLabel: "Needs approval"
        )
        XCTAssertEqual(result, "Needs approval")
    }

    func test_measurement_text_falls_back_to_default_label_when_interaction_label_is_nil() {
        let result = SidebarStatusResolver.resolveMeasurementStatusText(
            statusText: "Raw status",
            attentionState: .needsInput,
            interactionKind: .approval,
            interactionLabel: nil
        )
        XCTAssertEqual(result, PaneInteractionKind.approval.defaultLabel)
    }

    // MARK: - resolveStatusSymbolName

    func test_symbol_name_returns_empty_when_all_inputs_nil() {
        let result = SidebarStatusResolver.resolveStatusSymbolName(
            statusSymbolName: nil,
            attentionState: nil,
            interactionKind: nil,
            interactionSymbolName: nil
        )
        XCTAssertEqual(result, "")
    }

    func test_symbol_name_passthrough_when_not_preferring_interaction() {
        let result = SidebarStatusResolver.resolveStatusSymbolName(
            statusSymbolName: "bolt.fill",
            attentionState: .running,
            interactionKind: nil,
            interactionSymbolName: nil
        )
        XCTAssertEqual(result, "bolt.fill")
    }

    func test_symbol_name_prefers_interaction_symbol_when_interaction_active() {
        let result = SidebarStatusResolver.resolveStatusSymbolName(
            statusSymbolName: "clock.fill",
            attentionState: .needsInput,
            interactionKind: .approval,
            interactionSymbolName: "checkmark.shield"
        )
        XCTAssertEqual(result, "checkmark.shield")
    }

    func test_symbol_name_falls_back_to_default_symbol_when_interaction_symbol_nil() {
        let result = SidebarStatusResolver.resolveStatusSymbolName(
            statusSymbolName: nil,
            attentionState: .needsInput,
            interactionKind: .approval,
            interactionSymbolName: nil
        )
        XCTAssertEqual(result, PaneInteractionKind.approval.defaultSymbolName ?? "")
    }
}
