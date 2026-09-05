import Foundation
import XCTest

/// Real-shell coverage of the `ssh` wrapper (issue #84) for zsh and bash — bash runs twice
/// where available, system 3.2 and Homebrew 5.x. The harness lives in
/// ShellIntegrationSSHTestSupport.swift, the assertions in ShellIntegrationSSHAssertions.swift.
final class ShellIntegrationSSHPosixTests: XCTestCase {
    func test_zsh_shell_integration_defines_ssh_wrapper_only_with_ssh_feature() throws {
        try assertWrapperDefinition(shell: .zsh, probe: "whence -w ssh", wrappedMarker: "function")
    }

    func test_bash_shell_integration_defines_ssh_wrapper_only_with_ssh_feature() throws {
        for shell in SSHIntegrationShell.bashVariants {
            try assertWrapperDefinition(shell: shell, probe: "type -t ssh", wrappedMarker: "function")
        }
    }

    func test_zsh_shell_integration_ssh_env_forwards_term_and_environment() throws {
        try assertSSHEnvBehaviour(shell: .zsh)
    }

    func test_bash_shell_integration_ssh_env_forwards_term_and_environment() throws {
        for shell in SSHIntegrationShell.bashVariants { try assertSSHEnvBehaviour(shell: shell) }
    }

    func test_zsh_shell_integration_ssh_terminfo_uses_cached_host() throws {
        try assertTerminfoCacheHit(shell: .zsh)
    }

    func test_bash_shell_integration_ssh_terminfo_uses_cached_host() throws {
        for shell in SSHIntegrationShell.bashVariants { try assertTerminfoCacheHit(shell: shell) }
    }

    func test_zsh_shell_integration_ssh_terminfo_installs_and_caches_on_miss() throws {
        try assertTerminfoInstallSucceeds(shell: .zsh)
    }

    func test_bash_shell_integration_ssh_terminfo_installs_and_caches_on_miss() throws {
        for shell in SSHIntegrationShell.bashVariants { try assertTerminfoInstallSucceeds(shell: shell) }
    }

    func test_zsh_shell_integration_ssh_terminfo_falls_back_when_install_fails() throws {
        try assertTerminfoInstallFailureFallsBack(shell: .zsh)
    }

    func test_bash_shell_integration_ssh_terminfo_falls_back_when_install_fails() throws {
        for shell in SSHIntegrationShell.bashVariants { try assertTerminfoInstallFailureFallsBack(shell: shell) }
    }

    /// Regression: upstream appends its installer script after the user's args, so
    /// `ssh host 'echo marker'` ran the user's command during the install probe, used its
    /// exit status as "terminfo installed", cached the host, and then ran the command again.
    func test_zsh_shell_integration_ssh_terminfo_never_runs_user_remote_command_twice() throws {
        try assertRemoteCommandIsNotHijacked(shell: .zsh)
    }

    func test_bash_shell_integration_ssh_terminfo_never_runs_user_remote_command_twice() throws {
        for shell in SSHIntegrationShell.bashVariants { try assertRemoteCommandIsNotHijacked(shell: shell) }
    }

    func test_zsh_shell_integration_ssh_terminfo_skips_install_for_non_default_session() throws {
        try assertNonDefaultSessionSkipsInstall(shell: .zsh)
    }

    func test_bash_shell_integration_ssh_terminfo_skips_install_for_non_default_session() throws {
        for shell in SSHIntegrationShell.bashVariants { try assertNonDefaultSessionSkipsInstall(shell: shell) }
    }

    func test_zsh_shell_integration_ssh_terminfo_tears_down_control_master() throws {
        try assertControlMasterTeardown(shell: .zsh)
    }

    func test_bash_shell_integration_ssh_terminfo_tears_down_control_master() throws {
        for shell in SSHIntegrationShell.bashVariants { try assertControlMasterTeardown(shell: shell) }
    }

    /// Regression: with macOS's real per-user TMPDIR (~49 chars) the ControlPath plus
    /// OpenSSH's ~17-char bind suffix blew past the ~104-byte Unix socket limit and the
    /// install died with `unix_listener: path "..." too long for Unix domain socket`.
    func test_zsh_shell_integration_ssh_terminfo_falls_back_to_short_socket_directory() throws {
        try assertShortSocketDirectory(shell: .zsh)
    }

    func test_bash_shell_integration_ssh_terminfo_falls_back_to_short_socket_directory() throws {
        for shell in SSHIntegrationShell.bashVariants { try assertShortSocketDirectory(shell: shell) }
    }

    /// Regression: with a user ControlPath (ssh_config or `-S`), opening our own master
    /// hijacked their socket, and the teardown replayed their args — so `-S` won over our
    /// `-o ControlPath` and `-O exit` killed *their* master and every session on it.
    func test_zsh_shell_integration_ssh_terminfo_leaves_user_multiplexing_alone() throws {
        try assertUserMultiplexingUntouched(shell: .zsh)
    }

    func test_bash_shell_integration_ssh_terminfo_leaves_user_multiplexing_alone() throws {
        for shell in SSHIntegrationShell.bashVariants { try assertUserMultiplexingUntouched(shell: shell) }
    }

    func test_zsh_shell_integration_ssh_terminfo_teardown_does_not_replay_user_arguments() throws {
        try assertTeardownDoesNotReplayUserArguments(shell: .zsh)
    }

    func test_bash_shell_integration_ssh_terminfo_teardown_does_not_replay_user_arguments() throws {
        for shell in SSHIntegrationShell.bashVariants {
            try assertTeardownDoesNotReplayUserArguments(shell: shell)
        }
    }

    /// Regression: with only `ssh-terminfo` enabled `ssh_opts` stays empty, and bash 3.2
    /// aborts on `"${ssh_opts[@]}"` under `set -u`; uninitialised scalars broke bash 5 and
    /// zsh's `nounset` the same way, as did the pre-existing `_zentty_pane_root_pid_last`.
    func test_zsh_shell_integration_ssh_wrapper_survives_nounset() throws {
        try assertSurvivesUnsetGuard(shell: .zsh, prelude: "setopt nounset")
    }

    func test_bash_shell_integration_ssh_wrapper_survives_set_u() throws {
        for shell in SSHIntegrationShell.bashVariants {
            try assertSurvivesUnsetGuard(shell: shell, prelude: "set -u")
        }
    }

    /// The wrapper must not sit between a producer and ssh: with ssh-terminfo enabled the
    /// session's stdin still reaches the remote command as it is produced, not after the
    /// producer exits. (nushell is excluded: see the note on its wrapper — a custom
    /// command's pipeline input is collected by the interpreter itself.)
    func test_zsh_shell_integration_ssh_streams_piped_stdin() throws {
        try assertPipedStdinStreams(shell: .zsh)
    }

    func test_bash_shell_integration_ssh_streams_piped_stdin() throws {
        for shell in SSHIntegrationShell.bashVariants { try assertPipedStdinStreams(shell: shell) }
    }

    // MARK: - Captured output

    func test_zsh_shell_integration_ssh_session_output_is_capturable() throws {
        try assertSessionOutputIsCapturable(shell: .zsh, cached: false)
        try assertSessionOutputIsCapturable(shell: .zsh, cached: true)
    }

    func test_bash_shell_integration_ssh_session_output_is_capturable() throws {
        for shell in SSHIntegrationShell.bashVariants {
            try assertSessionOutputIsCapturable(shell: shell, cached: false)
            try assertSessionOutputIsCapturable(shell: shell, cached: true)
        }
    }

    // MARK: - Negative cache

    func test_zsh_shell_integration_ssh_terminfo_caches_permanent_failure() throws {
        try assertPermanentInstallFailureIsCachedAndWarnedOnce(shell: .zsh)
    }

    func test_bash_shell_integration_ssh_terminfo_caches_permanent_failure() throws {
        for shell in SSHIntegrationShell.bashVariants {
            try assertPermanentInstallFailureIsCachedAndWarnedOnce(shell: shell)
        }
    }

    func test_zsh_shell_integration_ssh_terminfo_does_not_cache_transient_failure() throws {
        try assertTransientInstallFailureIsNotCached(shell: .zsh)
    }

    func test_bash_shell_integration_ssh_terminfo_does_not_cache_transient_failure() throws {
        for shell in SSHIntegrationShell.bashVariants {
            try assertTransientInstallFailureIsNotCached(shell: shell)
        }
    }

    func test_zsh_shell_integration_ssh_cache_matches_whole_lines_only() throws {
        try assertCacheMatchesWholeLinesOnly(shell: .zsh)
    }

    func test_bash_shell_integration_ssh_cache_matches_whole_lines_only() throws {
        for shell in SSHIntegrationShell.bashVariants {
            try assertCacheMatchesWholeLinesOnly(shell: shell)
        }
    }

    // MARK: - COLORTERM belongs to ssh-env

    func test_zsh_shell_integration_ssh_terminfo_alone_does_not_set_colorterm() throws {
        try assertColorTermIsScopedToSSHEnv(shell: .zsh)
    }

    func test_bash_shell_integration_ssh_terminfo_alone_does_not_set_colorterm() throws {
        for shell in SSHIntegrationShell.bashVariants {
            try assertColorTermIsScopedToSSHEnv(shell: shell)
        }
    }

    // MARK: - Coverage visibility

    /// bash 3.2 (the system shell) and bash 5.x behave differently around `set -u` and
    /// empty arrays, so every bash assertion runs on both. When Homebrew's bash is not
    /// installed this records a skip rather than quietly halving the coverage.
    func test_bash5_shell_integration_coverage_is_available() throws {
        guard SSHIntegrationShell.bash5.executablePath != nil else {
            throw XCTSkip("Homebrew bash 5 not installed: the bash tests covered 3.2 only")
        }
        XCTAssertEqual(SSHIntegrationShell.bashVariants.count, 2)
    }
}
