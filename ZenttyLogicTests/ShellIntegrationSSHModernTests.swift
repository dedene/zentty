import Foundation
import XCTest

/// Real-shell coverage of the `ssh` wrapper (issue #84) for fish and nushell. The harness
/// lives in ShellIntegrationSSHTestSupport.swift, the assertions in
/// ShellIntegrationSSHAssertions.swift.
final class ShellIntegrationSSHModernTests: XCTestCase {
    func test_fish_shell_integration_defines_ssh_wrapper_only_with_ssh_feature() throws {
        try assertWrapperDefinition(
            shell: .fish,
            probe: "if functions -q ssh; echo function; else; echo file; end",
            wrappedMarker: "function"
        )
    }

    /// nushell cannot define a command conditionally: `def` inside an `if` is block-scoped and
    /// `hide` is parse-time, so the wrapper is always defined (as upstream ghostty.nu does) and
    /// degrades to a transparent pass-through when no ssh feature is enabled.
    func test_nu_shell_integration_ssh_wrapper_passes_through_without_ssh_feature() throws {
        try skipUnlessSSHShellAvailable(.nu)
        let fixture = try makeSSHFixture(features: "cursor:blink,path,title")
        _ = try runSSHIntegration(shell: .nu, command: "ssh example.invalid", fixture: fixture)

        let invocation = try XCTUnwrap(try fixture.invocations().last)
        XCTAssertEqual(invocation.args, ["example.invalid"])
        XCTAssertEqual(invocation.term, "xterm-ghostty", "pass-through must not rewrite TERM")
        XCTAssertEqual(invocation.colorterm, "")
    }

    func test_fish_shell_integration_ssh_env_forwards_term_and_environment() throws {
        try assertSSHEnvBehaviour(shell: .fish)
    }

    func test_nu_shell_integration_ssh_env_forwards_term_and_environment() throws {
        try assertSSHEnvBehaviour(shell: .nu)
    }

    func test_fish_shell_integration_ssh_terminfo_uses_cached_host() throws {
        try assertTerminfoCacheHit(shell: .fish)
    }

    func test_nu_shell_integration_ssh_terminfo_uses_cached_host() throws {
        try assertTerminfoCacheHit(shell: .nu)
    }

    func test_fish_shell_integration_ssh_terminfo_installs_and_caches_on_miss() throws {
        try assertTerminfoInstallSucceeds(shell: .fish)
    }

    func test_nu_shell_integration_ssh_terminfo_installs_and_caches_on_miss() throws {
        try assertTerminfoInstallSucceeds(shell: .nu)
    }

    func test_fish_shell_integration_ssh_terminfo_never_runs_user_remote_command_twice() throws {
        try assertRemoteCommandIsNotHijacked(shell: .fish)
    }

    func test_nu_shell_integration_ssh_terminfo_never_runs_user_remote_command_twice() throws {
        try assertRemoteCommandIsNotHijacked(shell: .nu)
    }

    func test_fish_shell_integration_ssh_terminfo_skips_install_for_non_default_session() throws {
        try assertNonDefaultSessionSkipsInstall(shell: .fish)
    }

    func test_nu_shell_integration_ssh_terminfo_skips_install_for_non_default_session() throws {
        try assertNonDefaultSessionSkipsInstall(shell: .nu)
    }

    func test_fish_shell_integration_ssh_terminfo_tears_down_control_master() throws {
        try assertControlMasterTeardown(shell: .fish)
    }


    func test_fish_shell_integration_ssh_terminfo_falls_back_to_short_socket_directory() throws {
        try assertShortSocketDirectory(shell: .fish)
    }


    func test_fish_shell_integration_ssh_terminfo_leaves_user_multiplexing_alone() throws {
        try assertUserMultiplexingUntouched(shell: .fish)
    }

    func test_nu_shell_integration_ssh_terminfo_leaves_user_multiplexing_alone() throws {
        try assertUserMultiplexingUntouched(shell: .nu)
    }

    func test_fish_shell_integration_ssh_terminfo_teardown_does_not_replay_user_arguments() throws {
        try assertTeardownDoesNotReplayUserArguments(shell: .fish)
    }


    func test_fish_shell_integration_ssh_streams_piped_stdin() throws {
        try assertPipedStdinStreams(shell: .fish)
    }

    /// Regression: the nushell wrapper swallowed the incoming pipeline, so
    /// `"payload" | ssh host cat` delivered nothing to the remote command.
    func test_nu_shell_integration_ssh_forwards_piped_stdin_with_ssh_features() throws {
        try assertPipedStdinIsForwarded(shell: .nu, features: "ssh-env,ssh-terminfo")
    }

    func test_nu_shell_integration_ssh_forwards_piped_stdin_without_ssh_features() throws {
        try assertPipedStdinIsForwarded(shell: .nu, features: "cursor:blink,path,title")
    }

    // MARK: - Captured output

    func test_fish_shell_integration_ssh_session_output_is_capturable() throws {
        try assertSessionOutputIsCapturable(shell: .fish, cached: false)
        try assertSessionOutputIsCapturable(shell: .fish, cached: true)
    }

    func test_nu_shell_integration_ssh_session_output_is_capturable() throws {
        try assertSessionOutputIsCapturable(shell: .nu, cached: false)
        try assertSessionOutputIsCapturable(shell: .nu, cached: true)
    }

    // MARK: - Negative cache

    func test_fish_shell_integration_ssh_terminfo_caches_permanent_failure() throws {
        try assertPermanentInstallFailureIsCachedAndWarnedOnce(shell: .fish)
    }

    func test_nu_shell_integration_ssh_terminfo_caches_permanent_failure() throws {
        try assertPermanentInstallFailureIsCachedAndWarnedOnce(shell: .nu)
    }

    func test_fish_shell_integration_ssh_terminfo_does_not_cache_transient_failure() throws {
        try assertTransientInstallFailureIsNotCached(shell: .fish)
    }

    func test_nu_shell_integration_ssh_terminfo_does_not_cache_transient_failure() throws {
        try assertTransientInstallFailureIsNotCached(shell: .nu)
    }

    func test_fish_shell_integration_ssh_cache_matches_whole_lines_only() throws {
        try assertCacheMatchesWholeLinesOnly(shell: .fish)
    }

    func test_nu_shell_integration_ssh_cache_matches_whole_lines_only() throws {
        try assertCacheMatchesWholeLinesOnly(shell: .nu)
    }

    // MARK: - COLORTERM belongs to ssh-env

    func test_fish_shell_integration_ssh_terminfo_alone_does_not_set_colorterm() throws {
        try assertColorTermIsScopedToSSHEnv(shell: .fish)
    }

    func test_nu_shell_integration_ssh_terminfo_alone_does_not_set_colorterm() throws {
        try assertColorTermIsScopedToSSHEnv(shell: .nu)
    }

    // MARK: - Install failure fallback (T2: was zsh/bash only)

    func test_fish_shell_integration_ssh_terminfo_falls_back_when_install_fails() throws {
        try assertTerminfoInstallFailureFallsBack(shell: .fish)
    }

    func test_nu_shell_integration_ssh_terminfo_falls_back_when_install_fails() throws {
        try assertTerminfoInstallFailureFallsBack(shell: .nu)
    }

    func test_fish_shell_integration_ssh_wrapper_survives_terminfo_only_features() throws {
        try assertSurvivesUnsetGuard(shell: .fish, prelude: "")
    }

    func test_nu_shell_integration_ssh_wrapper_survives_terminfo_only_features() throws {
        try assertSurvivesUnsetGuard(shell: .nu, prelude: "")
    }

    /// nushell trades multiplexing for a correct session: no master, so the first
    /// connection to a host pays one extra authentication (documented in zentty.nu).
    func test_nu_shell_integration_ssh_terminfo_never_opens_control_master() throws {
        try assertNeverOpensControlMaster(shell: .nu)
    }
}
