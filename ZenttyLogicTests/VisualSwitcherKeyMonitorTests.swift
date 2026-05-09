import XCTest
@testable import Zentty

@MainActor
final class VisualSwitcherKeyMonitorTests: XCTestCase {

    private func makeInstalledMonitor() -> VisualSwitcherKeyMonitor {
        let monitor = VisualSwitcherKeyMonitor()
        monitor.install()
        return monitor
    }

    func test_processFlagsChanged_emits_release_only_on_down_to_up_transition() {
        let monitor = makeInstalledMonitor()
        defer { monitor.uninstall() }

        // Right after install, Ctrl is presumed down. Letting it go fires.
        let release = monitor.processFlagsChanged(.init(containsControl: false))
        XCTAssertEqual(release, .ctrlReleased)

        // Subsequent flagsChanged events without Ctrl re-down don't refire.
        XCTAssertNil(monitor.processFlagsChanged(.init(containsControl: false)))
    }

    func test_processFlagsChanged_does_not_fire_for_other_modifier_changes_while_ctrl_held() {
        let monitor = makeInstalledMonitor()
        defer { monitor.uninstall() }

        // Shift goes up/down with Ctrl still held — no release should fire.
        XCTAssertNil(monitor.processFlagsChanged(.init(containsControl: true)))
        XCTAssertNil(monitor.processFlagsChanged(.init(containsControl: true)))
    }

    func test_processFlagsChanged_redown_then_release_fires_again() {
        let monitor = makeInstalledMonitor()
        defer { monitor.uninstall() }

        XCTAssertEqual(
            monitor.processFlagsChanged(.init(containsControl: false)),
            .ctrlReleased
        )
        // Ctrl pressed again
        XCTAssertNil(monitor.processFlagsChanged(.init(containsControl: true)))
        // ...and released again
        XCTAssertEqual(
            monitor.processFlagsChanged(.init(containsControl: false)),
            .ctrlReleased
        )
    }

    func test_install_seeds_ctrl_down_so_first_release_fires() {
        let monitor = VisualSwitcherKeyMonitor()
        monitor.install()
        defer { monitor.uninstall() }

        // No prior call — first flagsChanged with no Ctrl should fire.
        XCTAssertEqual(
            monitor.processFlagsChanged(.init(containsControl: false)),
            .ctrlReleased
        )
    }

    func test_uninstall_then_reinstall_resets_state() {
        let monitor = VisualSwitcherKeyMonitor()
        monitor.install()
        _ = monitor.processFlagsChanged(.init(containsControl: false))
        monitor.uninstall()

        // Re-install for a fresh gesture.
        monitor.install()
        defer { monitor.uninstall() }
        XCTAssertEqual(
            monitor.processFlagsChanged(.init(containsControl: false)),
            .ctrlReleased
        )
    }
}
