import XCTest
@testable import Zentty

final class PaneCopyTargetResolverTests: XCTestCase {
    func test_local_pane_copies_working_directory() {
        let shellContext = PaneShellContext(
            scope: .local,
            path: "/Users/peter/Development/zentty",
            home: "/Users/peter",
            user: "peter",
            host: "mbp"
        )
        let auxiliaryState = makeAuxiliaryState(raw: PaneRawState(shellContext: shellContext), title: "zsh")

        XCTAssertEqual(
            PaneCopyTargetResolver.target(for: auxiliaryState),
            .path("/Users/peter/Development/zentty")
        )
    }

    func test_local_pane_without_path_has_nothing_to_copy() {
        let auxiliaryState = makeAuxiliaryState(raw: PaneRawState(), title: "zsh")

        XCTAssertNil(PaneCopyTargetResolver.target(for: auxiliaryState))
    }

    func test_remote_shell_context_copies_ssh_command_instead_of_remote_path() {
        let shellContext = PaneShellContext(
            scope: .remote,
            path: "/srv/app",
            home: "/home/peter",
            user: "peter",
            host: "prod-box"
        )
        let auxiliaryState = makeAuxiliaryState(raw: PaneRawState(shellContext: shellContext), title: "zsh")

        XCTAssertEqual(
            PaneCopyTargetResolver.target(for: auxiliaryState),
            .sshConnection("ssh peter@prod-box")
        )
    }

    func test_foreground_ssh_process_wins_and_keeps_port() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(title: "ssh stale@example.test", processName: "ssh"),
            shellContext: PaneShellContext(
                scope: .local,
                path: "/Users/peter",
                home: "/Users/peter",
                user: "peter",
                host: "mbp"
            ),
            foregroundSSHDestination: SSHDestination(
                target: "peter@live.example.test",
                user: "peter",
                host: "live.example.test",
                port: 2222
            )
        )
        let auxiliaryState = makeAuxiliaryState(raw: raw, title: "ssh stale@example.test")

        XCTAssertEqual(
            PaneCopyTargetResolver.target(for: auxiliaryState),
            .sshConnection("ssh -p 2222 peter@live.example.test")
        )
    }

    func test_ssh_command_title_without_probe_copies_parsed_destination() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(title: "ssh -p 2200 deploy@example.test", processName: "ssh"),
            foregroundSSHDestination: nil
        )
        let auxiliaryState = makeAuxiliaryState(raw: raw, title: "ssh -p 2200 deploy@example.test")

        XCTAssertEqual(
            PaneCopyTargetResolver.target(for: auxiliaryState),
            .sshConnection("ssh -p 2200 deploy@example.test")
        )
    }

    func test_copy_target_presentation_strings() {
        XCTAssertEqual(PaneCopyTarget.path("/tmp").pasteboardString, "/tmp")
        XCTAssertEqual(PaneCopyTarget.path("/tmp").copiedToastMessage, "Path copied")
        XCTAssertEqual(PaneCopyTarget.path("/tmp").commandPaletteSubtitle, "Copy Path — /tmp")

        let connection = PaneCopyTarget.sshConnection("ssh peter@prod-box")
        XCTAssertEqual(connection.pasteboardString, "ssh peter@prod-box")
        XCTAssertEqual(connection.copiedToastMessage, "Connection copied")
        XCTAssertEqual(connection.commandPaletteSubtitle, "Copy Connection — ssh peter@prod-box")
    }

    func test_command_palette_subtitle_uses_copy_target_over_path() throws {
        let items = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [.copyFocusedPanePath],
            shortcutManager: ShortcutManager(shortcuts: .default),
            focusedPanePath: "/srv/app",
            focusedPaneCopyTarget: .sshConnection("ssh peter@prod-box")
        )
        let item = try XCTUnwrap(items.first { $0.id == .command(.copyFocusedPanePath) })

        XCTAssertEqual(item.subtitle, "Copy Connection — ssh peter@prod-box")
    }

    private func makeAuxiliaryState(raw: PaneRawState, title: String) -> PaneAuxiliaryState {
        PaneAuxiliaryState(
            raw: raw,
            presentation: PanePresentationNormalizer.normalize(paneTitle: title, raw: raw, previous: nil)
        )
    }
}
