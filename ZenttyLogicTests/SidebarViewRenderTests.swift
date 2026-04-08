import AppKit
import XCTest
@testable import Zentty

@MainActor
final class SidebarViewRenderTests: XCTestCase {
    func test_render_skipsWorkWhenSummariesAndThemeAreUnchanged() {
        let sidebar = makeSidebar()
        let theme = ZenttyTheme.fallback(for: nil)
        let summaries = [makeSummary(worklaneID: "main", primaryText: "demo")]

        sidebar.render(summaries: summaries, theme: theme)
        XCTAssertEqual(sidebar.renderInvocationCountForTesting, 1)

        sidebar.render(summaries: summaries, theme: theme)
        XCTAssertEqual(
            sidebar.renderInvocationCountForTesting,
            1,
            "identical inputs should not trigger a second full render pass"
        )
    }

    func test_render_runsAgainWhenSummariesChange() {
        let sidebar = makeSidebar()
        let theme = ZenttyTheme.fallback(for: nil)

        sidebar.render(
            summaries: [makeSummary(worklaneID: "main", primaryText: "demo")],
            theme: theme
        )
        XCTAssertEqual(sidebar.renderInvocationCountForTesting, 1)

        sidebar.render(
            summaries: [makeSummary(worklaneID: "main", primaryText: "demo updated")],
            theme: theme
        )
        XCTAssertEqual(sidebar.renderInvocationCountForTesting, 2)
    }

    func test_render_runsAgainWhenWorklaneListChanges() {
        let sidebar = makeSidebar()
        let theme = ZenttyTheme.fallback(for: nil)

        sidebar.render(
            summaries: [makeSummary(worklaneID: "main", primaryText: "demo")],
            theme: theme
        )
        XCTAssertEqual(sidebar.renderInvocationCountForTesting, 1)

        sidebar.render(
            summaries: [
                makeSummary(worklaneID: "main", primaryText: "demo"),
                makeSummary(worklaneID: "second", primaryText: "another"),
            ],
            theme: theme
        )
        XCTAssertEqual(sidebar.renderInvocationCountForTesting, 2)
    }

    private func makeSidebar() -> SidebarView {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        return sidebar
    }

    private func makeSummary(
        worklaneID: String,
        primaryText: String,
        isActive: Bool = false
    ) -> WorklaneSidebarSummary {
        WorklaneSidebarSummary(
            worklaneID: WorklaneID(worklaneID),
            badgeText: "1",
            topLabel: nil,
            primaryText: primaryText,
            statusText: nil,
            detailLines: [],
            attentionState: nil,
            isWorking: false,
            isActive: isActive
        )
    }
}
