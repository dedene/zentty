import Foundation
import XCTest

/// Guards the float audit: "does this pane exist / which pane is focused"
/// questions must go through the float-aware `WorklaneState` accessors
/// (`allPanes`, `pane(id:)`, `containsPane(id:)`, `focusedPaneID`). Raw strip
/// access is only allowed in files that genuinely work on the tiled layout.
///
/// Adding a file here needs a reason. Removing the last strip access from a
/// listed file fails the stale-entry check, so the list only shrinks.
final class PaneStripAccessAllowlistTests: XCTestCase {
    private static let allowlist: [String: String] = [
        // Model and store: the strip is their own state.
        "AppState/WorklaneState+Panes.swift": "defines the float-aware accessors on top of the strip",
        "AppState/WorklaneStore.swift": "strip commands, split/grid/layout, close bookkeeping (audit sweep A)",
        "AppState/WorklaneStore+DragDrop.swift": "tiled drag/drop and transfers; floats dock via dockPane",
        "AppState/WorklaneStore+Restore.swift": "closed-pane capture/reopen of strip slots",
        "AppState/WorklaneStore+Float.swift": "moves panes between the strip and floats",
        "AppState/WorklaneStore+FloatLifecycle.swift": "new-pane numbering from the strip column count",
        "AppState/Agent/DiscoveryIPCHandler.swift": "DiscoveredWorklane.columnCount is a strip column count",
        // Tiled geometry and peek (the peek shows strip thumbnails only).
        "UI/RootViewController.swift": "sidebar slide compensation and peek entry use strip geometry/focus",
        "UI/PaneCommandExecutor.swift": "keyboard resize steps and IPC column indices are strip geometry",
        "UI/WorklanePeek/WorklanePeekSelectionState.swift": "peek traversal and spatial nav are strip-only",
        "UI/WorklanePeek/WorklanePeekLaneView.swift": "renders a neighbour lane's strip",
        "UI/WorklanePeek/WorklanePeekView.swift": "hit-tests strip pane frames",
        "UI/WorklanePeek/WorklanePeekController.swift": "peek highlight starts on the strip focus",
        "UI/Sidebar/WorklaneSidebarSummaryBuilder.swift": "worklane identity follows the strip focus",
        // Bookmarks capture the tiled layout only (floats are a v1 non-goal).
        "Bookmarks/BookmarkNameSuggester.swift": "names a bookmark from the captured strip",
        "Bookmarks/WorkspaceTemplateCapture.swift": "captures the strip into a template",
        // Pending: later phase-1 tasks make these float-aware and drop them here.
        "Restore/WorkspaceRecipe.swift": "pending Task 8: recipe v5 exports floats",
        "Restore/SessionRestoreStore.swift": "pending Task 8: drafts for floated panes",
        "AppDelegate.swift": "pending Task 8: scrollback capture source",
    ]

    private static let pattern = #"paneStripState\.(panes|columns|focusedPaneID)\b"#

    func test_raw_strip_access_is_limited_to_allowlisted_files() throws {
        let hits = try Self.stripAccessHitsByFile()
        let unexpected = hits.keys.filter { Self.allowlist[$0] == nil }.sorted()

        XCTAssertTrue(
            unexpected.isEmpty,
            """
            Raw `paneStripState.panes/columns/focusedPaneID` in non-allowlisted files. \
            Use WorklaneState.allPanes / pane(id:) / containsPane(id:) / focusedPaneID, \
            or add the file to the allowlist with a reason:
            \(unexpected.map { "\($0): lines \(hits[$0] ?? [])" }.joined(separator: "\n"))
            """
        )
    }

    func test_allowlist_has_no_stale_entries() throws {
        let hits = try Self.stripAccessHitsByFile()
        let stale = Self.allowlist.keys.filter { hits[$0] == nil }.sorted()

        XCTAssertTrue(stale.isEmpty, "Allowlisted files without strip access; remove them: \(stale)")
    }

    // MARK: - Scan

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zentty", isDirectory: true)
    }

    /// Relative path (from `Zentty/`) → line numbers with a raw strip access.
    /// Comment lines are skipped.
    private static func stripAccessHitsByFile() throws -> [String: [Int]] {
        let root = sourceRoot
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("Zentty sources not found at \(root.path)")
        }
        let regex = try NSRegularExpression(pattern: pattern)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var hits: [String: [Int]] = [:]
        var scannedFiles = 0

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scannedFiles += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            let relativePath = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    hits[relativePath, default: []].append(index + 1)
                }
            }
        }

        XCTAssertGreaterThan(scannedFiles, 100, "source scan found too few files under \(root.path)")
        return hits
    }
}
