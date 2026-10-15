import AppKit
import XCTest
@testable import Zentty

final class PaneOverlayIPCOptionsTests: XCTestCase {
    func test_parser_reports_specific_edge_case_errors() {
        let cases: [([String], PaneOverlayIPCOptions.ParseError)] = [
            (["--bogus"], .unexpectedArgument("--bogus")),
            (["--cwd", ""], .invalidValue("--cwd")),
            (["--cwd"], .missingValue("--cwd")),
            (["--placement", "bogus"], .invalidValue("--placement")),
            (["--command-json", "not json"], .invalidValue("--command-json")),
            (["--command-json", "{}"], .invalidValue("--command-json")),
            (["--command-json", "[]"], .missingCommand),
        ]
        for (arguments, expected) in cases {
            XCTAssertThrowsError(try PaneOverlayIPCOptions.parse(arguments: arguments)) {
                XCTAssertEqual($0 as? PaneOverlayIPCOptions.ParseError, expected, "\(arguments)")
            }
        }
    }

    func test_size_percent_bounds() throws {
        for size in [29, 30, 100, 101] {
            let arguments = ["--size-percent", "\(size)", "--command-json", "[\"git\"]"]
            if (30...100).contains(size) {
                XCTAssertEqual(try PaneOverlayIPCOptions.parse(arguments: arguments).sizePercent, size)
            } else {
                XCTAssertThrowsError(try PaneOverlayIPCOptions.parse(arguments: arguments)) {
                    XCTAssertEqual($0 as? PaneOverlayIPCOptions.ParseError, .invalidValue("--size-percent"))
                }
            }
        }
    }

    func test_flags_combine() throws {
        let options = try PaneOverlayIPCOptions.parse(arguments: [
            "--wait", "--follow", "--notify", "--command-json", "[\"git\"]",
        ])
        XCTAssertTrue(options.wait)
        XCTAssertTrue(options.follow)
        XCTAssertTrue(options.notify)
    }

    func test_command_arguments_survive_builder_and_shell_wrapping() throws {
        let values = ["two words", "single'quote", "double\"quote", "--", "--wait", "", "$HOME; echo unsafe"]
        let tokens = ["/usr/bin/printf", "%s\\0"] + values
        let json = String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self)
        let options = try PaneOverlayIPCOptions.parse(arguments: ["--command-json", json])
        XCTAssertEqual(options.command, TmuxCompatIPCHandler.shellWrappedGhosttyCommand(
            try GridLaunchCommandBuilder.command(from: tokens)))
        // Execute the same wrapping pipeline without reading the user's shell startup files.
        let command = try XCTUnwrap(TmuxCompatIPCHandler.shellWrappedGhosttyCommand(
            try GridLaunchCommandBuilder.command(from: tokens), loginShellPath: nil))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(data, Data((values.joined(separator: "\0") + "\0").utf8))
    }

    func test_routing_strips_selectors_before_overlay_options_are_parsed() throws {
        let selectors = try ParsedPaneSelectors.parse(arguments: [
            "--pane-id", "pn_target", "--wait", "--pane-token", "test-token",
            "--command-json", "[\"git\",\"--\",\"--pane-id\"]",
        ])
        XCTAssertEqual(selectors.paneID, PaneID("pn_target"))
        XCTAssertEqual(selectors.paneToken, "test-token")
        XCTAssertEqual(selectors.arguments, ["--wait", "--command-json", "[\"git\",\"--\",\"--pane-id\"]"])
        XCTAssertTrue(try PaneOverlayIPCOptions.parse(arguments: selectors.arguments).wait)
    }

    func test_overlay_subcommand_raw_values() {
        let cases: [(String, PaneIPCSubcommand)] = [
            ("overlay-open", .overlayOpen), ("overlay-list", .overlayList),
            ("overlay-show", .overlayShow), ("overlay-close", .overlayClose),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(PaneIPCSubcommand(rawValue: raw), expected)
        }
    }

    func test_parse_preserves_command_arguments_and_background_default() throws {
        let options = try PaneOverlayIPCOptions.parse(arguments: [
            "--wait", "--notify", "--size-percent", "70",
            "--command-json", "[\"git\",\"log\",\"--oneline\",\"a b\"]",
        ])

        XCTAssertTrue(options.command.contains("git log --oneline"))
        XCTAssertTrue(options.command.contains("a b"))
        XCTAssertTrue(options.command.contains(" -lic ") || options.command.contains("sh -c "))
        XCTAssertTrue(options.wait)
        XCTAssertTrue(options.notify)
        XCTAssertFalse(options.follow)
        XCTAssertEqual(options.sizePercent, 70)
        XCTAssertEqual(options.placement, .worklane)
    }

    func test_parse_supports_pane_placement_and_defaults_to_full_content_size() throws {
        let options = try PaneOverlayIPCOptions.parse(arguments: [
            "--placement", "pane", "--command-json", "[\"git\",\"diff\"]",
        ])
        XCTAssertEqual(options.placement, .pane)
        XCTAssertEqual(options.sizePercent, 100)
        XCTAssertThrowsError(try PaneOverlayIPCOptions.parse(arguments: [
            "--placement", "window", "--command-json", "[\"git\"]",
        ]))
    }

    func test_parse_rejects_invalid_size_and_missing_command() {
        XCTAssertThrowsError(try PaneOverlayIPCOptions.parse(arguments: [
            "--size-percent", "10", "--command-json", "[\"git\"]",
        ]))
        XCTAssertThrowsError(try PaneOverlayIPCOptions.parse(arguments: ["--wait"]))
    }
}

@MainActor
final class TerminalOverlayLayoutTests: AppKitTestCase {
    func test_overlay_fills_inset_anchor_and_tracks_resizing() {
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let overlay = makeOverlay(placement: .worklane)
        overlay.setVisible(true, anchor: anchor)
        XCTAssertEqual(overlay.view.frame, NSRect(x: 16, y: 16, width: 568, height: 368))

        anchor.setFrameSize(NSSize(width: 800, height: 500))
        anchor.layoutSubtreeIfNeeded()
        XCTAssertEqual(overlay.view.frame, NSRect(x: 16, y: 16, width: 768, height: 468))
        overlay.close()
        XCTAssertNil(overlay.view.superview)
    }

    func test_pane_overlay_reanchors_without_changing_its_session() {
        let background = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let overlay = makeOverlay(placement: .pane)
        overlay.setVisible(false, anchor: background)
        XCTAssertTrue(overlay.view.isHidden)
        overlay.setVisible(true, anchor: pane)
        XCTAssertTrue(overlay.view.superview === pane)
        XCTAssertFalse(overlay.view.isHidden)
        XCTAssertEqual(overlay.view.frame, NSRect(x: 16, y: 16, width: 368, height: 268))
        overlay.close()
    }

    func test_worklane_overlay_excludes_sidebar_area_and_passes_through_empty_space() {
        let canvas = AppCanvasView(runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }))
        canvas.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        canvas.leadingVisibleInset = 200
        canvas.layoutSubtreeIfNeeded()
        XCTAssertEqual(canvas.quickActionOverlayContainer.frame, NSRect(x: 200, y: 0, width: 800, height: 600))
        XCTAssertNil(canvas.quickActionOverlayContainer.hitTest(NSPoint(x: 300, y: 100)))
        canvas.leadingVisibleInset = 0
        XCTAssertEqual(canvas.quickActionOverlayContainer.frame, canvas.bounds)
    }

    private func makeOverlay(placement: PaneOverlayIPCOptions.Placement) -> TerminalOverlaySession {
        TerminalOverlaySession(paneID: PaneID("p_test"), worklaneID: WorklaneID("w_test"),
                               command: "git log", workingDirectory: nil, wait: true,
                               sizePercent: 100, placement: placement,
                               adapterFactory: { _ in MockTerminalAdapter() })
    }
}
