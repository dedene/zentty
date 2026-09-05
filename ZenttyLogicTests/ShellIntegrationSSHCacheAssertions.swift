import Foundation
import XCTest

// Assertions about the terminfo cache (positive and negative entries), COLORTERM
// scoping, captured session output, and nushell's no-ControlMaster contract. Split out
// of ShellIntegrationSSHAssertions.swift to keep both files readable.

extension XCTestCase {
    /// The cache matches whole lines: `xalice@example.invalid` must not satisfy a lookup
    /// for `alice@example.invalid`, or a stray line would silently poison a host.
    func assertCacheMatchesWholeLinesOnly(shell: SSHIntegrationShell) throws {
        try skipUnlessSSHShellAvailable(shell)
        let fixture = try makeSSHFixture(features: "ssh-env,ssh-terminfo", stubInfocmp: true)
        try fixture.seedCache(["xalice@example.invalid", "alice@example.invalid.extra"])

        _ = try runSSHIntegration(shell: shell, command: "ssh example.invalid", fixture: fixture)

        let invocations = try fixture.invocations()
        XCTAssertTrue(
            invocations.contains(where: \.isTerminfoInstall),
            "\(shell) treated a lookalike cache line as a hit: \(invocations)"
        )
    }

    /// The wrapper's value must be capturable — `x=$(ssh host ls)` has to yield the remote
    /// output, on a cache hit and on a miss (where the probe and any cleanup run too).
    func assertSessionOutputIsCapturable(shell: SSHIntegrationShell, cached: Bool) throws {
        try skipUnlessSSHShellAvailable(shell)
        let fixture = try makeSSHFixture(features: "ssh-env,ssh-terminfo", stubInfocmp: true)
        if cached {
            try fixture.seedCache(["alice@example.invalid"])
        }

        let result = try runSSHIntegration(
            shell: shell,
            command: shell.captureCommand(assigning: "ssh example.invalid"),
            fixture: fixture
        )

        XCTAssertTrue(
            result.stdout.contains("captured=[\(SSHFixture.remoteOutputMarker)]"),
            "\(shell) did not return the session's output as a value (cached=\(cached)): "
                + "stdout=\(result.stdout) stderr=\(result.stderr)"
        )
    }

    /// A probe that fails with a status other than 255 means the remote ran our installer
    /// and it did not work (no tic, no base64). Remember that, warn once, then stay quiet.
    func assertPermanentInstallFailureIsCachedAndWarnedOnce(shell: SSHIntegrationShell) throws {
        try skipUnlessSSHShellAvailable(shell)
        let fixture = try makeSSHFixture(
            features: "ssh-env,ssh-terminfo",
            stubInfocmp: true,
            installExitCode: 1
        )

        let first = try runSSHIntegration(shell: shell, command: "ssh example.invalid", fixture: fixture)

        XCTAssertEqual(
            try fixture.cacheLines(), ["!alice@example.invalid"],
            "\(shell) should record the host as unable to take the terminfo"
        )
        XCTAssertTrue(
            first.stderr.contains("Could not install xterm-ghostty terminfo on example.invalid"),
            "\(shell) should say what happened once: \(first.stderr)"
        )
        XCTAssertTrue(
            first.stderr.contains("!alice@example.invalid") && first.stderr.contains("to retry"),
            "\(shell) should name the line to delete to retry: \(first.stderr)"
        )
        let firstSession = try XCTUnwrap(
            try fixture.invocations().last(where: { !$0.isTerminfoInstall && !$0.isControlExit })
        )
        XCTAssertEqual(firstSession.term, "xterm-256color", "\(shell): \(firstSession)")

        fixture.resetLog()
        let second = try runSSHIntegration(shell: shell, command: "ssh example.invalid", fixture: fixture)

        let repeatInvocations = try fixture.invocations()
        XCTAssertFalse(
            repeatInvocations.contains(where: \.isTerminfoInstall),
            "\(shell) should not spend another connection on a known-bad host: \(repeatInvocations)"
        )
        XCTAssertEqual(second.stderr, "", "\(shell) should warn only once: \(second.stderr)")
        let secondSession = try XCTUnwrap(repeatInvocations.last)
        XCTAssertEqual(secondSession.term, "xterm-256color", "\(shell): \(secondSession)")
        XCTAssertEqual(
            try fixture.cacheLines(), ["!alice@example.invalid"],
            "\(shell) should not duplicate the negative entry"
        )
    }

    /// Status 255 is ssh itself failing (auth, network, refusal): transient, so nothing is
    /// cached and the warning repeats — the next attempt may well succeed.
    func assertTransientInstallFailureIsNotCached(shell: SSHIntegrationShell) throws {
        try skipUnlessSSHShellAvailable(shell)
        let fixture = try makeSSHFixture(
            features: "ssh-env,ssh-terminfo",
            stubInfocmp: true,
            installExitCode: 255
        )

        let first = try runSSHIntegration(shell: shell, command: "ssh example.invalid", fixture: fixture)
        XCTAssertTrue(try fixture.cacheLines().isEmpty, "\(shell) must not cache a transient failure")
        XCTAssertTrue(
            first.stderr.contains("Failed to install xterm-ghostty terminfo"),
            "\(shell): \(first.stderr)"
        )

        fixture.resetLog()
        let second = try runSSHIntegration(shell: shell, command: "ssh example.invalid", fixture: fixture)
        XCTAssertTrue(
            try fixture.invocations().contains(where: \.isTerminfoInstall),
            "\(shell) should retry after a transient failure"
        )
        XCTAssertTrue(
            second.stderr.contains("Failed to install xterm-ghostty terminfo"),
            "\(shell) should keep warning while the failure is transient: \(second.stderr)"
        )
    }

    /// COLORTERM belongs to ssh-env; with ssh-terminfo alone the session must not get it.
    func assertColorTermIsScopedToSSHEnv(shell: SSHIntegrationShell) throws {
        try skipUnlessSSHShellAvailable(shell)
        let fixture = try makeSSHFixture(features: "ssh-terminfo", stubInfocmp: true)
        try fixture.seedCache(["alice@example.invalid"])

        _ = try runSSHIntegration(shell: shell, command: "ssh example.invalid", fixture: fixture)

        let session = try XCTUnwrap(try fixture.invocations().last)
        XCTAssertEqual(session.term, "xterm-ghostty", "\(shell): \(session)")
        XCTAssertEqual(session.colorterm, "", "\(shell) set COLORTERM without ssh-env: \(session)")
        XCTAssertFalse(
            session.args.contains(where: { $0.hasPrefix("SendEnv") }),
            "\(shell) forwarded ssh-env options without the feature: \(session.args)"
        )
    }

    /// nushell must never open a ControlMaster: its session is the command's final
    /// expression, so there is no place to tear one down (and a stray master would
    /// outlive the shell). The probe and the session are two plain connections.
    func assertNeverOpensControlMaster(shell: SSHIntegrationShell) throws {
        try skipUnlessSSHShellAvailable(shell)
        let fixture = try makeSSHFixture(features: "ssh-env,ssh-terminfo", stubInfocmp: true)

        _ = try runSSHIntegration(shell: shell, command: "ssh example.invalid", fixture: fixture)

        let invocations = try fixture.invocations()
        XCTAssertTrue(invocations.contains(where: \.isTerminfoInstall), "\(shell): \(invocations)")
        for invocation in invocations {
            XCTAssertFalse(
                invocation.args.contains(where: {
                    $0.hasPrefix("ControlMaster") || $0.hasPrefix("ControlPath=") || $0.hasPrefix("ControlPersist")
                }),
                "\(shell) opened multiplexing it cannot clean up: \(invocation)"
            )
        }
        XCTAssertFalse(
            invocations.contains(where: \.isControlExit),
            "\(shell) should have no master to close: \(invocations)"
        )
        let session = try XCTUnwrap(invocations.last)
        XCTAssertEqual(session.term, "xterm-ghostty", "\(shell): \(session)")
        try assertNoTemporaryLeftovers(fixture, shell: shell)
    }
}
