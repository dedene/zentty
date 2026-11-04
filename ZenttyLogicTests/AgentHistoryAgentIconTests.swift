import AppKit
import XCTest
@testable import Zentty

@MainActor
final class AgentHistoryAgentIconTests: XCTestCase {
    func test_falls_back_when_renderer_returns_nil() {
        let image = AgentHistoryAgentIcon.image(for: .grok) { _ in nil }
        XCTAssertTrue(image.isTemplate)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertEqual(image.accessibilityDescription, "Grok")
    }

    func test_uses_renderer_image_for_the_agents_tool() {
        var requested: [AgentTool] = []
        let rendered = NSImage(size: NSSize(width: 18, height: 18))
        let image = AgentHistoryAgentIcon.image(for: .opencode) { tool in
            requested.append(tool)
            return rendered
        }
        XCTAssertTrue(image === rendered)
        XCTAssertEqual(requested, [.openCode])
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.accessibilityDescription, "OpenCode")
    }

    func test_cached_image_is_reused_for_every_agent() {
        for agent in AgentHistoryAgent.allCases {
            XCTAssertTrue(AgentHistoryAgentIcon.image(for: agent) === AgentHistoryAgentIcon.image(for: agent))
        }
    }

    func test_filter_alias_is_the_operator_value_the_parser_accepts() {
        for agent in AgentHistoryAgent.allCases {
            XCTAssertEqual(HistoryQueryParser.parse("agent:\(agent.filterAlias)").filters.agents, [agent])
        }
    }
}
