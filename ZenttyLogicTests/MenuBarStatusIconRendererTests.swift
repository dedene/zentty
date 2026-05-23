import XCTest
@testable import Zentty

final class MenuBarStatusIconRendererTests: XCTestCase {
    func test_zenttyMarkImage_loads_when_zentty_app_bundle_is_present() throws {
        guard let image = MenuBarStatusIconRenderer.zenttyMarkImage() else {
            throw XCTSkip("MenuBarAgentIdle is only in Zentty.app; logic tests without the app bundle skip mark loading.")
        }
        XCTAssertTrue(image.isTemplate)
    }

    func test_status_item_image_is_template_so_macos_adapts_it_to_appearance() {
        let image = MenuBarStatusIconRenderer.statusImage(fleetState: .idle, hasAgentPanes: false)

        XCTAssertNotNil(image)
        XCTAssertEqual(image?.isTemplate, true)
        XCTAssertEqual(image?.size.width, MenuBarStatusIconRenderer.statusItemCanvasSide)
        XCTAssertEqual(image?.size.height, MenuBarStatusIconRenderer.statusItemCanvasSide)
    }

    func test_status_item_with_agent_panes_remains_template_so_macos_tints_menu_bar_mark() {
        let image = MenuBarStatusIconRenderer.statusImage(fleetState: .active, hasAgentPanes: true)

        XCTAssertNotNil(image)
        XCTAssertEqual(image?.isTemplate, true)
        XCTAssertEqual(image?.size.width, MenuBarStatusIconRenderer.statusItemCanvasSide)
        XCTAssertEqual(image?.size.height, MenuBarStatusIconRenderer.statusItemCanvasSide)
    }

    func test_status_item_with_agent_panes_clears_space_for_overlay_dot() throws {
        let image = try XCTUnwrap(MenuBarStatusIconRenderer.statusImage(fleetState: .active, hasAgentPanes: true))
        let rep = try XCTUnwrap(bitmapRepresentation(for: image))

        XCTAssertLessThan(alpha(at: NSPoint(x: 14, y: 4), in: rep), 0.1)
    }

    func test_status_badge_frame_places_dot_at_bottom_right_of_flipped_status_button() {
        let frame = MenuBarStatusController.statusBadgeFrameForTesting(
            in: NSRect(x: 0, y: 0, width: 28, height: 22)
        )

        XCTAssertEqual(frame.origin.x, 14)
        XCTAssertEqual(frame.origin.y, 11)
        XCTAssertEqual(frame.size.width, MenuBarStatusIconRenderer.insetDotSide)
        XCTAssertEqual(frame.size.height, MenuBarStatusIconRenderer.insetDotSide)
    }

    func test_shows_status_dot_only_for_non_idle_fleet_with_panes() {
        for state in [MenuBarFleetState.waiting, .stopped, .compacting, .active] {
            XCTAssertTrue(
                MenuBarStatusIconRenderer.showsStatusDot(fleetState: state, hasAgentPanes: true),
                "\(state) with panes should surface a menu bar dot"
            )
        }
        XCTAssertFalse(MenuBarStatusIconRenderer.showsStatusDot(fleetState: .idle, hasAgentPanes: true))
    }

    func test_shows_status_dot_is_false_without_agent_panes() {
        XCTAssertFalse(MenuBarStatusIconRenderer.showsStatusDot(fleetState: .idle, hasAgentPanes: false))
        XCTAssertFalse(MenuBarStatusIconRenderer.showsStatusDot(fleetState: .active, hasAgentPanes: false))
    }

    func test_all_idle_fleet_keeps_dot_cutout_filled_so_menu_bar_shows_no_dot() throws {
        let active = try XCTUnwrap(MenuBarStatusIconRenderer.statusImage(fleetState: .active, hasAgentPanes: true))
        let idle = try XCTUnwrap(MenuBarStatusIconRenderer.statusImage(fleetState: .idle, hasAgentPanes: true))
        let activeRep = try XCTUnwrap(bitmapRepresentation(for: active))
        let idleRep = try XCTUnwrap(bitmapRepresentation(for: idle))

        // The active icon punches a transparent cutout for the overlay dot; the
        // idle icon must not, so the same point is at least as opaque when idle.
        let dotPoint = NSPoint(x: 14, y: 4)
        XCTAssertLessThan(alpha(at: dotPoint, in: activeRep), 0.1)
        XCTAssertGreaterThanOrEqual(
            alpha(at: dotPoint, in: idleRep),
            alpha(at: dotPoint, in: activeRep)
        )
    }

    func test_agent_icon_badged_image_is_composited_and_row_sized() {
        let image = MenuBarStatusIconRenderer.agentIconImage(for: .claudeCode, fleetState: .active)

        XCTAssertNotNil(image)
        XCTAssertEqual(image?.isTemplate, false)
        XCTAssertEqual(image?.size.width, MenuBarStatusIconRenderer.agentIconSide)
        XCTAssertEqual(image?.size.height, MenuBarStatusIconRenderer.agentIconSide)
    }

    func test_badged_image_clears_cutout_around_status_dot() throws {
        let base = NSImage(size: NSSize(width: 20, height: 20))
        base.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 20, height: 20)).fill()
        base.unlockFocus()

        let image = MenuBarStatusIconRenderer.badgedImageForTesting(
            baseImage: base,
            canvasSide: 20,
            dotSide: 6,
            dotOrigin: NSPoint(x: 12, y: 2),
            cutoutPadding: 2,
            fleetState: .active
        )
        let rep = try XCTUnwrap(bitmapRepresentation(for: image))

        XCTAssertLessThan(alpha(at: NSPoint(x: 15, y: 9), in: rep), 0.1)
        XCTAssertGreaterThan(alpha(at: NSPoint(x: 15, y: 5), in: rep), 0.95)
    }

    func test_empty_fleet_and_idle_fleet_keep_same_canvas_size() {
        let empty = MenuBarStatusIconRenderer.statusImage(fleetState: .idle, hasAgentPanes: false)
        let idle = MenuBarStatusIconRenderer.statusImage(fleetState: .idle, hasAgentPanes: true)
        let waiting = MenuBarStatusIconRenderer.statusImage(fleetState: .waiting, hasAgentPanes: true)

        XCTAssertEqual(empty?.size.width, MenuBarStatusIconRenderer.statusItemCanvasSide)
        XCTAssertEqual(idle?.size.width, MenuBarStatusIconRenderer.statusItemCanvasSide)
        XCTAssertEqual(waiting?.size.width, MenuBarStatusIconRenderer.statusItemCanvasSide)
    }

    func test_mark_side_is_smaller_than_canvas() {
        XCTAssertLessThan(MenuBarStatusIconRenderer.markSide, MenuBarStatusIconRenderer.statusItemCanvasSide)
    }

    func test_agent_icon_template_image_is_row_icon_sized() {
        let rowImage = MenuBarStatusIconRenderer.agentIconTemplateImage(for: .claudeCode)
        XCTAssertEqual(rowImage?.size.width, MenuBarStatusIconRenderer.agentIconSide)
        XCTAssertEqual(rowImage?.isTemplate, true)
        XCTAssertLessThan(MenuBarStatusIconRenderer.agentIconSide, MenuBarStatusIconRenderer.statusItemCanvasSide + 10)
    }

    func test_builtin_agent_icons_resolve_to_bundled_assets() {
        let builtInTools: [AgentTool] = [
            .zentty,
            .amp,
            .claudeCode,
            .codex,
            .copilot,
            .cursor,
            .droid,
            .gemini,
            .kimi,
            .openCode,
            .pi,
            .grok,
        ]

        for tool in builtInTools {
            XCTAssertEqual(
                MenuBarStatusIconRenderer.agentIconSource(for: tool),
                .bundledAsset,
                "\(tool.displayName) should use a bundled SVG asset, not a generated fallback"
            )
        }
    }

    func test_custom_agent_icon_uses_generated_fallback() {
        XCTAssertEqual(
            MenuBarStatusIconRenderer.agentIconSource(for: .custom("local-agent")),
            .generatedFallback
        )
    }

    func test_antigravity_agent_icon_uses_generated_fallback() {
        XCTAssertEqual(
            MenuBarStatusIconRenderer.agentIconSource(for: .agy),
            .generatedFallback
        )
        XCTAssertNotNil(MenuBarStatusIconRenderer.agentIconTemplateImage(for: .agy))
    }

    func test_required_menu_bar_asset_names_are_present_in_bundle_or_source_catalog() {
        let requiredAssetNames = [
            "MenuBarAgentIdle",
            "AgentIconZentty",
            "AgentIconAmp",
            "AgentIconClaudeCode",
            "AgentIconCodex",
            "AgentIconCopilot",
            "AgentIconCursor",
            "AgentIconDroid",
            "AgentIconGemini",
            "AgentIconKimi",
            "AgentIconOpenCode",
            "AgentIconPi",
            "AgentIconGrok",
        ]

        for assetName in requiredAssetNames {
            XCTAssertTrue(
                MenuBarStatusIconRenderer.hasBundledOrSourceCatalogAsset(named: assetName),
                "\(assetName) should exist in the app bundle or source asset catalog"
            )
        }
    }

    func test_status_item_renderer_does_not_accept_waiting_count_mode() {
        let image = MenuBarStatusIconRenderer.statusImage(fleetState: .waiting, hasAgentPanes: true)

        XCTAssertEqual(image?.size.width, MenuBarStatusIconRenderer.statusItemCanvasSide)
        XCTAssertNotNil(image)
    }

    private func bitmapRepresentation(for image: NSImage) -> NSBitmapImageRep? {
        let target = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width),
            pixelsHigh: Int(image.size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let target else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return target
    }

    private func alpha(at point: NSPoint, in rep: NSBitmapImageRep) -> CGFloat {
        let pixel = rep.colorAt(
            x: Int(point.x),
            y: rep.pixelsHigh - 1 - Int(point.y)
        )
        return pixel?.alphaComponent ?? 0
    }
}
