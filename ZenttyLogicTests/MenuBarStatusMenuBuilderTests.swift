import XCTest
@testable import Zentty

@MainActor
final class MenuBarStatusMenuBuilderTests: XCTestCase {
    private let windowID = WindowID("win-test")
    private let worklaneID = WorklaneID("wl-test")
    private let paneID = PaneID("pn-test")

    func test_custom_rows_use_compact_width_for_310pt_status_menu() {
        let menu = NSMenu()
        let idle = MenuBarPaneSnapshot(
            windowID: windowID,
            windowTitle: "W",
            worklaneID: worklaneID,
            paneID: paneID,
            agentTool: .claudeCode,
            primaryText: "Improve dev server port detection",
            contextText: "dev-server-ignore-ports",
            statusLabel: "Idle",
            attentionState: nil,
            fleetState: .idle,
            updatedAt: Date(),
            taskProgress: nil,
            sortPriority: 5
        )

        MenuBarStatusMenuBuilder.rebuild(
            menu: menu,
            snapshots: [idle],
            fleetSummary: MenuBarFleetSummary.from(snapshots: [idle]),
            target: nil,
            rowAction: #selector(NSObject.description),
            settingsAction: #selector(NSObject.description)
        )

        let row = try! XCTUnwrap(menu.items[1].view)
        XCTAssertEqual(row.intrinsicContentSize.width, 250)
    }

    func test_status_label_shows_full_text_after_narrow_layout_pass() {
        let menu = NSMenu()
        let idle = MenuBarPaneSnapshot(
            windowID: windowID, windowTitle: "W", worklaneID: worklaneID, paneID: paneID,
            agentTool: .claudeCode, primaryText: "Improve dev server port detection",
            contextText: "dev-server-ignore-ports", statusLabel: "Idle", attentionState: nil, fleetState: .idle,
            updatedAt: Date(), taskProgress: nil, sortPriority: 5
        )
        MenuBarStatusMenuBuilder.rebuild(
            menu: menu, snapshots: [idle], fleetSummary: MenuBarFleetSummary.from(snapshots: [idle]),
            target: nil, rowAction: #selector(NSObject.description), settingsAction: #selector(NSObject.description)
        )
        let row = try! XCTUnwrap(menu.items[1].view)
        // The menu lays a custom row out at a narrow width before its final pass;
        // the status text must still be given enough width to render in full.
        for width in [310.0, 60.0, 310.0] {
            row.frame = NSRect(x: 0, y: 0, width: width, height: 44)
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
        }

        let labels = textFields(in: row)
        let statusLabel = try! XCTUnwrap(labels.first { $0.stringValue == "Idle" })
        XCTAssertGreaterThanOrEqual(
            statusLabel.frame.width,
            fittingTextWidth(of: statusLabel),
            "Status label must be wide enough to show its text without truncation"
        )
        let ageLabel = try! XCTUnwrap(labels.first { $0.stringValue == "just now" })
        XCTAssertGreaterThanOrEqual(
            ageLabel.frame.width,
            fittingTextWidth(of: ageLabel),
            "Age label must be wide enough to show its text without truncation"
        )
    }

    func test_status_pill_uses_palette_color_for_waiting_rows() {
        let row = buildRow(for: paneSnapshot(fleetState: .waiting, statusLabel: "Needs decision"))
        let statusLabel = try! XCTUnwrap(textFields(in: row).first { $0.stringValue == "Needs decision" })
        assertPillLabelColor(statusLabel.textColor, kind: .needsInput)
    }

    func test_status_pill_uses_palette_color_for_running_rows() {
        let row = buildRow(for: paneSnapshot(fleetState: .active, statusLabel: "Running"))
        let statusLabel = try! XCTUnwrap(textFields(in: row).first { $0.stringValue == "Running" })
        assertPillLabelColor(statusLabel.textColor, kind: .running)
    }

    func test_status_pill_uses_palette_color_for_idle_rows() {
        let row = buildRow(for: paneSnapshot(fleetState: .idle, statusLabel: "Idle"))
        let statusLabel = try! XCTUnwrap(textFields(in: row).first { $0.stringValue == "Idle" })
        assertPillLabelColor(statusLabel.textColor, kind: .idle)
    }

    func test_status_pill_uses_ready_color_for_agent_ready_rows() {
        // 'Agent ready' is fleetState .idle + attentionState .ready, and must
        // read as the blue ready pill rather than plain idle gray.
        let row = buildRow(for: paneSnapshot(
            fleetState: .idle,
            statusLabel: "Agent ready",
            attentionState: .ready
        ))
        let statusLabel = try! XCTUnwrap(textFields(in: row).first { $0.stringValue == "Agent ready" })
        assertPillLabelColor(statusLabel.textColor, kind: .ready)
    }

    func test_custom_rows_claim_cursor_updates_for_arrow_cursor() {
        let menu = NSMenu()
        let running = paneSnapshot(fleetState: .active, statusLabel: "Running")

        MenuBarStatusMenuBuilder.rebuild(
            menu: menu,
            snapshots: [running],
            fleetSummary: MenuBarFleetSummary.from(snapshots: [running]),
            target: nil,
            rowAction: #selector(NSObject.description),
            settingsAction: #selector(NSObject.description)
        )

        let row = try! XCTUnwrap(menu.items[1].view)
        row.updateTrackingAreas()
        row.resetCursorRects()

        XCTAssertTrue(
            row.trackingAreas.contains { $0.options.contains(.cursorUpdate) },
            "Custom status menu rows must claim cursor updates so stale cursors from underlying windows do not leak into the menu."
        )
        let cursorDebugging = try! XCTUnwrap(row as? MenuBarAgentRowCursorDebugging)
        XCTAssertTrue(cursorDebugging.debugUsesArrowCursorForTesting)
    }

    func test_agent_icon_stays_light_when_dark_menu_row_appearance_changes_after_rebuild() {
        let menu = NSMenu()
        menu.appearance = NSAppearance(named: .darkAqua)
        let running = paneSnapshot(fleetState: .active, statusLabel: "Running")

        MenuBarStatusMenuBuilder.rebuild(
            menu: menu,
            snapshots: [running],
            fleetSummary: MenuBarFleetSummary.from(snapshots: [running]),
            target: nil,
            rowAction: #selector(NSObject.description),
            settingsAction: #selector(NSObject.description)
        )

        let row = try! XCTUnwrap(menu.items[1].view)
        row.appearance = NSAppearance(named: .aqua)
        row.viewDidChangeEffectiveAppearance()

        let iconImageView = try! XCTUnwrap(imageViews(in: row).first)
        let iconImage = try! XCTUnwrap(iconImageView.image)
        XCTAssertGreaterThan(
            averageOpaqueLuminance(of: iconImage),
            0.65,
            "Agent icon should keep the dark menu's light glyph color after a live row appearance refresh"
        )
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.reduce(into: (view as? NSTextField).map { [$0] } ?? []) { result, subview in
            result.append(contentsOf: textFields(in: subview))
        }
    }

    private func imageViews(in view: NSView) -> [NSImageView] {
        view.subviews.reduce(into: (view as? NSImageView).map { [$0] } ?? []) { result, subview in
            result.append(contentsOf: imageViews(in: subview))
        }
    }

    private func averageOpaqueLuminance(of image: NSImage) -> CGFloat {
        guard let rep = bitmapRepresentation(for: image) else { return 0 }
        var luminanceSum: CGFloat = 0
        var sampleCount: CGFloat = 0

        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.srgbClamped,
                      color.alphaComponent > 0.5 else {
                    continue
                }
                luminanceSum += color.perceivedLuminance
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return 0 }
        return luminanceSum / sampleCount
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

    private func fittingTextWidth(of label: NSTextField) -> CGFloat {
        ceil(label.fittingSize.width)
    }

    private func buildRow(
        for snapshot: MenuBarPaneSnapshot,
        appearance: NSAppearance? = NSAppearance(named: .aqua)
    ) -> NSView {
        let menu = NSMenu()
        menu.appearance = appearance
        MenuBarStatusMenuBuilder.rebuild(
            menu: menu,
            snapshots: [snapshot],
            fleetSummary: MenuBarFleetSummary.from(snapshots: [snapshot]),
            target: nil,
            rowAction: #selector(NSObject.description),
            settingsAction: #selector(NSObject.description)
        )
        return menu.items[1].view!
    }

    private func assertPillLabelColor(
        _ color: NSColor?,
        kind: MenuBarStatusKind,
        isDark: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = try! XCTUnwrap(color, file: file, line: line).srgbClamped
        let expected = MenuBarStatusPalette.labelColor(for: kind, isDark: isDark).srgbClamped
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001, file: file, line: line)
    }

    func test_itemTitle_uses_accessibility_summary() {
        let snapshot = paneSnapshot(fleetState: .active, statusLabel: "Running")

        XCTAssertEqual(
            MenuBarStatusMenuBuilder.itemTitle(for: snapshot),
            "Claude Code, Running"
        )
    }

    func test_rebuild_empty_snapshots_adds_empty_row_and_settings_action() {
        let menu = NSMenu()
        let settingsShortcut = ShortcutManager(shortcuts: .default).shortcut(for: .openSettings)

        MenuBarStatusMenuBuilder.rebuild(
            menu: menu,
            snapshots: [],
            fleetSummary: MenuBarFleetSummary.from(snapshots: []),
            target: nil,
            rowAction: #selector(NSObject.description),
            settingsAction: #selector(NSObject.description),
            settingsShortcut: settingsShortcut
        )

        XCTAssertEqual(menu.items.count, 4)
        XCTAssertEqual(menu.items[0].title, "No agent panes")
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertTrue(menu.items[1].isSeparatorItem)

        XCTAssertEqual(menu.items[2].title, "Settings…")
        XCTAssertNotNil(menu.items[2].image)
        XCTAssertEqual(menu.items[2].keyEquivalent, settingsShortcut?.menuKeyEquivalent ?? "")
        XCTAssertEqual(menu.items[2].keyEquivalentModifierMask, settingsShortcut?.menuModifierFlags ?? [])

        XCTAssertEqual(menu.items[3].title, "Quit")
        XCTAssertEqual(menu.items[3].action, #selector(NSApplication.terminate(_:)))
        XCTAssertNotNil(menu.items[3].image)
        XCTAssertEqual(menu.items[3].keyEquivalent, "q")
        XCTAssertEqual(menu.items[3].keyEquivalentModifierMask, [.command])
    }

    func test_rebuild_groups_by_state_sections_with_counts_and_custom_row_views() {
        let menu = NSMenu()
        let waiting = paneSnapshot(
            fleetState: .waiting,
            statusLabel: "Waiting",
            windowTitle: "B Window",
            primaryText: "waiting-agent"
        )
        let running = paneSnapshot(
            fleetState: .active,
            statusLabel: "Running",
            windowTitle: "A Window",
            primaryText: "running-agent"
        )

        MenuBarStatusMenuBuilder.rebuild(
            menu: menu,
            snapshots: [waiting, running],
            fleetSummary: MenuBarFleetSummary.from(snapshots: [waiting, running]),
            target: nil,
            rowAction: #selector(NSObject.description),
            settingsAction: #selector(NSObject.description)
        )

        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles[0], "Waiting (1)")
        XCTAssertEqual(titles[1], "waiting-agent, Waiting")
        XCTAssertEqual(titles[2], "")
        XCTAssertEqual(titles[3], "Running (1)")
        XCTAssertEqual(titles[4], "running-agent, Running")
        XCTAssertEqual(titles[5], "")
        XCTAssertEqual(titles[6], "Settings…")

        XCTAssertNotNil(menu.items[1].view)
        XCTAssertNotNil(menu.items[4].view)
        XCTAssertFalse(titles.contains("A Window"))
        XCTAssertFalse(titles.contains("B Window"))

        let payload = menu.items[1].representedObject as? MenuBarPaneMenuItemPayload
        XCTAssertEqual(payload?.paneID, paneID)
    }

    func test_rebuild_omits_invalid_epoch_age_text() {
        let menu = NSMenu()
        let idle = paneSnapshot(
            fleetState: .idle,
            statusLabel: "Idle",
            primaryText: "idle-agent"
        )

        MenuBarStatusMenuBuilder.rebuild(
            menu: menu,
            snapshots: [idle],
            fleetSummary: MenuBarFleetSummary.from(snapshots: [idle]),
            target: nil,
            rowAction: #selector(NSObject.description),
            settingsAction: #selector(NSObject.description)
        )

        let rowText = textFieldValues(in: menu.items[1].view)
        XCTAssertTrue(rowText.contains("idle-agent"))
        XCTAssertTrue(rowText.contains("Idle"))
        XCTAssertFalse(rowText.contains { $0.hasSuffix("ago") || $0 == "just now" })
    }

    func test_status_controller_uses_native_status_item_menu() throws {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.MenuBarStatusController.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }

        let configStore = AppConfigStore(fileURL: temporaryDirectoryURL.appendingPathComponent("config.toml"))
        let controller = MenuBarStatusController(
            configStore: configStore,
            focusPaneHandler: { _, _, _ in },
            openSettingsHandler: {}
        )

        controller.start()
        defer { controller.stop() }

        XCTAssertTrue(controller.usesNativeMenuForTesting)
    }

    func test_status_controller_refreshes_native_menu_from_live_sources_when_menu_updates() throws {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.MenuBarStatusController.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }

        let paneID = PaneID("pn-claude")
        let worklaneID = WorklaneID("wl-main")
        let configStore = AppConfigStore(fileURL: temporaryDirectoryURL.appendingPathComponent("config.toml"))
        let controller = MenuBarStatusController(
            configStore: configStore,
            focusPaneHandler: { _, _, _ in },
            openSettingsHandler: {}
        )
        let store = WorklaneStore(
            windowID: windowID,
            worklanes: [
                WorklaneState(
                    id: worklaneID,
                    title: nil,
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: paneID, title: "Claude Code")],
                        focusedPaneID: paneID
                    ),
                    agentStatusByPaneID: [
                        paneID: PaneAgentStatus(
                            tool: .claudeCode,
                            state: .running,
                            text: nil,
                            artifactLink: nil,
                            updatedAt: Date(timeIntervalSince1970: 10)
                        )
                    ]
                )
            ]
        )

        controller.start()
        defer { controller.stop() }
        controller.syncSources([
            MenuBarWorklaneSource(
                windowID: windowID,
                windowTitle: "Zentty",
                worklaneStore: store
            )
        ])
        XCTAssertTrue(controller.menuItemTitlesForTesting().contains("Running (1)"))

        var worklane = store.worklanes[0]
        var auxiliary = try XCTUnwrap(worklane.auxiliaryStateByPaneID[paneID])
        auxiliary.agentStatus = PaneAgentStatus(
            tool: .claudeCode,
            state: .idle,
            text: nil,
            artifactLink: nil,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        auxiliary.presentation = PanePresentationNormalizer.normalize(
            paneTitle: "Claude Code",
            raw: auxiliary.raw,
            previous: auxiliary.presentation,
            sessionRequestWorkingDirectory: nil
        )
        worklane.auxiliaryStateByPaneID[paneID] = auxiliary
        store.worklanes[0] = worklane

        controller.forceNativeMenuUpdateForTesting()

        XCTAssertFalse(controller.menuItemTitlesForTesting().contains("Running (1)"))
        XCTAssertTrue(controller.menuItemTitlesForTesting().contains("Idle (1)"))
    }

    func test_status_controller_does_not_rebuild_menu_for_volatile_agent_title_updates() {
        XCTAssertFalse(MenuBarStatusController.isMenuRelevantForTesting(
            .volatileAgentTitleUpdated(worklaneID: worklaneID, paneID: paneID)
        ))

        XCTAssertTrue(MenuBarStatusController.isMenuRelevantForTesting(.paneStructure(worklaneID)))
        XCTAssertTrue(MenuBarStatusController.isMenuRelevantForTesting(.activeWorklaneChanged))
        XCTAssertTrue(MenuBarStatusController.isMenuRelevantForTesting(.worklaneListChanged))
        XCTAssertTrue(MenuBarStatusController.isMenuRelevantForTesting(
            .auxiliaryStateUpdated(worklaneID, paneID, .sidebar)
        ))
    }

    func test_status_controller_closes_menu_after_row_selection() {
        var focusedPayload: (WindowID, WorklaneID, PaneID)?
        let controller = MenuBarStatusController(
            configStore: AppConfigStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ZenttyTests.MenuBarStatusController.\(UUID().uuidString).toml")
            ),
            focusPaneHandler: { windowID, worklaneID, paneID in
                focusedPayload = (windowID, worklaneID, paneID)
            },
            openSettingsHandler: {}
        )

        controller.performMenuSelectionForTesting(windowID: windowID, worklaneID: worklaneID, paneID: paneID)

        XCTAssertEqual(focusedPayload?.0, windowID)
        XCTAssertEqual(focusedPayload?.1, worklaneID)
        XCTAssertEqual(focusedPayload?.2, paneID)
        XCTAssertEqual(controller.menuCloseRequestCountForTesting, 1)
    }

    private func paneSnapshot(
        fleetState: MenuBarFleetState,
        statusLabel: String,
        attentionState: WorklaneAttentionState? = nil,
        windowTitle: String = "Window 1",
        primaryText: String = "Claude Code"
    ) -> MenuBarPaneSnapshot {
        MenuBarPaneSnapshot(
            windowID: windowID,
            windowTitle: windowTitle,
            worklaneID: worklaneID,
            paneID: paneID,
            agentTool: .claudeCode,
            primaryText: primaryText,
            contextText: "zentty · main",
            statusLabel: statusLabel,
            attentionState: attentionState ?? fleetState.menuAttentionState,
            fleetState: fleetState,
            updatedAt: Date(timeIntervalSince1970: 0),
            taskProgress: nil,
            sortPriority: fleetState.priority
        )
    }

    private func textFieldValues(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let current = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return current + view.subviews.flatMap(textFieldValues(in:))
    }
}
