import Foundation
import XCTest

// Assertions shared by ShellIntegrationSSHPosixTests and ShellIntegrationSSHModernTests.
// Each one drives a single shell through the harness in ShellIntegrationSSHTestSupport.

extension XCTestCase {


    func assertWrapperDefinition(
        shell: SSHIntegrationShell,
        probe: String,
        wrappedMarker: String
    ) throws {
        try skipUnlessSSHShellAvailable(shell)

        let enabled = try makeSSHFixture(features: "cursor:blink,path,ssh-env,title")
        let enabledOutput = try runSSHIntegration(shell: shell, command: probe, fixture: enabled).stdout
        XCTAssertTrue(
            enabledOutput.contains(wrappedMarker),
            "\(shell) should define an ssh function when ssh-env is advertised, got: \(enabledOutput)"
        )

        let disabled = try makeSSHFixture(features: "cursor:blink,path,title")
        let disabledOutput = try runSSHIntegration(shell: shell, command: probe, fixture: disabled).stdout
        XCTAssertFalse(
            disabledOutput.contains(wrappedMarker),
            "\(shell) must not define an ssh function without an ssh feature, got: \(disabledOutput)"
        )
    }

    func assertSSHEnvBehaviour(shell: SSHIntegrationShell) throws {
        try skipUnlessSSHShellAvailable(shell)
        let fixture = try makeSSHFixture(features: "cursor:blink,path,ssh-env,title")
        _ = try runSSHIntegration(shell: shell, command: "ssh example.invalid", fixture: fixture)

        let invocation = try XCTUnwrap(
            try fixture.invocations().last,
            "\(shell) never invoked the stub ssh"
        )
        XCTAssertEqual(invocation.term, "xterm-256color", "\(shell): \(invocation)")
        // Upstream ghostty PR #11518: COLORTERM travels in the local environment plus SendEnv,
        // so a user's own `SetEnv` in ssh_config is not clobbered.
        XCTAssertEqual(invocation.colorterm, "truecolor", "\(shell): \(invocation)")
        XCTAssertTrue(
            invocation.args.contains("SendEnv COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION"),
            "\(shell) should forward the terminal identity vars, got: \(invocation.args)"
        )
        XCTAssertFalse(
            invocation.args.contains(where: { $0.hasPrefix("SetEnv ") }),
            "\(shell) must not pass SetEnv (clobbers user ssh_config), got: \(invocation.args)"
        )
        XCTAssertEqual(invocation.args.last, "example.invalid", "\(shell): user args must come last")
        XCTAssertFalse(
            invocation.args.contains(where: { $0.hasPrefix("ControlMaster") }),
            "\(shell) should not open a ControlMaster without ssh-terminfo: \(invocation.args)"
        )
    }

    func assertTerminfoCacheHit(shell: SSHIntegrationShell) throws {
        try skipUnlessSSHShellAvailable(shell)
        let fixture = try makeSSHFixture(features: "ssh-env,ssh-terminfo")
        try fixture.seedCache(["bob@other.invalid", "alice@example.invalid"])

        _ = try runSSHIntegration(shell: shell, command: "ssh example.invalid", fixture: fixture)

        let invocations = try fixture.invocations()
        let invocation = try XCTUnwrap(invocations.last, "\(shell) never invoked the stub ssh")
        XCTAssertEqual(invocation.term, "xterm-ghostty", "\(shell): \(invocation)")
        XCTAssertFalse(
            invocations.contains(where: \.isTerminfoInstall),
            "\(shell) should not reinstall terminfo for a cached host: \(invocations)"
        )
        XCTAssertFalse(
            invocation.args.contains(where: { $0.hasPrefix("ControlPath=") }),
            "\(shell) should not reuse a ControlPath on a cache hit: \(invocation.args)"
        )
        try assertNoTemporaryLeftovers(fixture, shell: shell)
    }

    func assertTerminfoInstallSucceeds(shell: SSHIntegrationShell) throws {
        try skipUnlessSSHShellAvailable(shell)
        let fixture = try makeSSHFixture(features: "ssh-env,ssh-terminfo", stubInfocmp: true)

        let result = try runSSHIntegration(shell: shell, command: "ssh example.invalid", fixture: fixture)

        let invocations = try fixture.invocations()
        let install = try XCTUnwrap(
            invocations.first(where: \.isTerminfoInstall),
            "\(shell) should attempt a terminfo install on a cache miss: \(invocations)"
        )
        XCTAssertTrue(
            install.args.contains(where: { $0.hasPrefix("RemoteCommand=") }),
            "\(shell) must carry the installer in RemoteCommand, got: \(install.args)"
        )
        XCTAssertFalse(
            install.args.contains(where: { $0.contains("%") }),
            "\(shell): RemoteCommand is percent-expanded by OpenSSH and must contain no '%': \(install.args)"
        )
        XCTAssertTrue(
            install.args.contains("RequestTTY=no"),
            "\(shell) should not request a TTY for the installer: \(install.args)"
        )
        let session = try XCTUnwrap(invocations.last(where: { !$0.isTerminfoInstall && !$0.isControlExit }))
        XCTAssertEqual(session.term, "xterm-ghostty", "\(shell): \(session)")
        if shell.opensOwnControlMaster {
            XCTAssertTrue(
                session.args.contains(where: { $0.hasPrefix("ControlPath=") }),
                "\(shell) should reuse the ControlMaster socket: \(session.args)"
            )
        } else {
            XCTAssertFalse(
                invocations.contains(where: { $0.args.contains(where: { $0.hasPrefix("ControlMaster") }) }),
                "\(shell) must not open a master it cannot tear down: \(invocations)"
            )
        }
        let cacheLines = try fixture.cacheLines()
        XCTAssertTrue(
            cacheLines.contains("alice@example.invalid"),
            "\(shell) should cache the host after a successful install, cache=\(cacheLines)"
        )
        let installedTerminfo = try fixture.installedTerminfo()
        XCTAssertTrue(
            installedTerminfo.contains("xterm-ghostty"),
            "\(shell) should deliver the generated terminfo to the remote host, got: \(installedTerminfo)"
        )
        XCTAssertFalse(result.stderr.contains("Warning:"), "\(shell) warned on a successful install: \(result.stderr)")
        try assertNoTemporaryLeftovers(fixture, shell: shell)
    }

    /// A probe that dies with ssh's own 255 (auth, network) leaves the session on
    /// xterm-256color and caches nothing; the permanent-failure path is separate.
    func assertTerminfoInstallFailureFallsBack(shell: SSHIntegrationShell) throws {
        try skipUnlessSSHShellAvailable(shell)
        let fixture = try makeSSHFixture(
            features: "ssh-env,ssh-terminfo",
            stubInfocmp: true,
            installExitCode: 255
        )

        let result = try runSSHIntegration(shell: shell, command: "ssh example.invalid", fixture: fixture)

        let invocations = try fixture.invocations()
        let session = try XCTUnwrap(
            invocations.last(where: { !$0.isTerminfoInstall && !$0.isControlExit }),
            "\(shell) never invoked the stub ssh"
        )
        XCTAssertEqual(session.term, "xterm-256color", "\(shell): \(session)")
        let cacheLines = try fixture.cacheLines()
        XCTAssertTrue(cacheLines.isEmpty, "\(shell) must not cache a failed install")
        XCTAssertTrue(
            result.stderr.contains("Warning: Failed to install"),
            "\(shell) should warn when the install genuinely fails, stderr=\(result.stderr)"
        )
        try assertNoTemporaryLeftovers(fixture, shell: shell)
    }

    func assertRemoteCommandIsNotHijacked(shell: SSHIntegrationShell) throws {
        try skipUnlessSSHShellAvailable(shell)
        let fixture = try makeSSHFixture(features: "ssh-env,ssh-terminfo", stubInfocmp: true)

        let result = try runSSHIntegration(
            shell: shell,
            command: "ssh example.invalid 'echo marker'",
            fixture: fixture
        )

        let invocations = try fixture.invocations()
        let sessions = invocations.filter { !$0.isTerminfoInstall && !$0.isControlExit }
        XCTAssertEqual(
            sessions.count, 1,
            "\(shell) must run the user's remote command exactly once, got: \(invocations)"
        )
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.args.last, "echo marker", "\(shell): \(session)")
        XCTAssertEqual(session.term, "xterm-256color", "\(shell) must fall back when the install is refused")
        let cacheLines = try fixture.cacheLines()
        XCTAssertTrue(cacheLines.isEmpty, "\(shell) must not cache a host whose install never ran: \(cacheLines)")
        XCTAssertTrue(try fixture.installedTerminfo().isEmpty, "\(shell) delivered terminfo despite the refusal")
        XCTAssertFalse(
            result.stderr.contains("Warning:"),
            "\(shell) should skip a refused install silently, stderr=\(result.stderr)"
        )
        try assertNoTemporaryLeftovers(fixture, shell: shell)
    }

    func assertNonDefaultSessionSkipsInstall(shell: SSHIntegrationShell) throws {
        try skipUnlessSSHShellAvailable(shell)
        let fixture = try makeSSHFixture(features: "ssh-env,ssh-terminfo", stubInfocmp: true)

        // `-N` makes the stub report `sessiontype none`, exactly like OpenSSH >= 8.7.
        let result = try runSSHIntegration(shell: shell, command: "ssh -N example.invalid", fixture: fixture)

        let invocations = try fixture.invocations()
        XCTAssertFalse(
            invocations.contains(where: \.isTerminfoInstall),
            "\(shell) must not try to install terminfo over a session that runs no command: \(invocations)"
        )
        let session = try XCTUnwrap(invocations.last, "\(shell) never invoked the stub ssh")
        XCTAssertEqual(session.term, "xterm-256color", "\(shell): \(session)")
        XCTAssertFalse(result.stderr.contains("Warning:"), "\(shell) should skip silently, stderr=\(result.stderr)")
        XCTAssertTrue(try fixture.cacheLines().isEmpty, "\(shell) must not cache a skipped host")
        try assertNoTemporaryLeftovers(fixture, shell: shell)
    }

    func assertControlMasterTeardown(shell: SSHIntegrationShell) throws {
        try skipUnlessSSHShellAvailable(shell)
        let fixture = try makeSSHFixture(
            features: "ssh-env,ssh-terminfo",
            stubInfocmp: true,
            sessionExitCode: 42
        )

        let result = try runSSHIntegration(shell: shell, command: "ssh example.invalid", fixture: fixture)

        let invocations = try fixture.invocations()
        let teardown = try XCTUnwrap(
            invocations.last(where: \.isControlExit),
            "\(shell) should tear down the control master it created: \(invocations)"
        )
        XCTAssertTrue(
            teardown.args.contains(where: { $0.hasPrefix("ControlPath=") }),
            "\(shell): teardown must target the socket it created: \(teardown.args)"
        )
        XCTAssertEqual(
            result.status, 42,
            "\(shell) must preserve the session's exit status across cleanup, stderr=\(result.stderr)"
        )
        try assertNoTemporaryLeftovers(fixture, shell: shell)
    }

    func assertShortSocketDirectory(shell: SSHIntegrationShell) throws {
        try skipUnlessSSHShellAvailable(shell)
        let fixture = try makeSSHFixture(
            features: "ssh-env,ssh-terminfo",
            stubInfocmp: true,
            longTemporaryDirectory: true
        )
        XCTAssertGreaterThan(
            fixture.tmpDirectory.path.count, 40,
            "this test needs a TMPDIR long enough to trip the socket-length guard"
        )

        _ = try runSSHIntegration(shell: shell, command: "ssh example.invalid", fixture: fixture)

        let invocations = try fixture.invocations()
        let install = try XCTUnwrap(
            invocations.first(where: \.isTerminfoInstall),
            "\(shell) should still attempt the install: \(invocations)"
        )
        let controlPath = try XCTUnwrap(
            install.args.first(where: { $0.hasPrefix("ControlPath=") })
                .map { String($0.dropFirst("ControlPath=".count)) },
            "\(shell) passed no ControlPath: \(install.args)"
        )
        XCTAssertTrue(
            controlPath.hasPrefix("/tmp/zentty-ssh."),
            "\(shell) must fall back to /tmp when TMPDIR is long, got: \(controlPath)"
        )
        XCTAssertLessThan(
            controlPath.count + 17, 104,
            "\(shell): ControlPath plus OpenSSH's bind suffix must fit a Unix socket path: \(controlPath)"
        )

        // The wrapper never touched the (long) fixture TMPDIR here, so the only thing
        // worth checking is that the /tmp directory it fell back to is gone again.
        let socketDirectory = URL(fileURLWithPath: controlPath).deletingLastPathComponent()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: socketDirectory.path),
            "\(shell) left its socket directory behind: \(socketDirectory.path)"
        )
    }

    func assertUserMultiplexingUntouched(shell: SSHIntegrationShell) throws {
        try skipUnlessSSHShellAvailable(shell)
        let fixture = try makeSSHFixture(
            features: "ssh-env,ssh-terminfo",
            stubInfocmp: true,
            userControlPath: "/home/alice/.ssh/cm-%C"
        )

        _ = try runSSHIntegration(
            shell: shell,
            command: "ssh -S /home/alice/.ssh/cm example.invalid",
            fixture: fixture
        )

        let invocations = try fixture.invocations()
        for invocation in invocations {
            XCTAssertFalse(
                invocation.args.contains(where: { $0.hasPrefix("ControlMaster") || $0.hasPrefix("ControlPath=") }),
                "\(shell) must not add multiplexing of its own: \(invocation)"
            )
        }
        XCTAssertFalse(
            invocations.contains(where: \.isControlExit),
            "\(shell) must never send -O exit to a master it does not own: \(invocations)"
        )
        // The install still runs over the user's connection, so terminfo is installed.
        XCTAssertTrue(
            invocations.contains(where: \.isTerminfoInstall),
            "\(shell) should still install terminfo over the user's own connection: \(invocations)"
        )
        let session = try XCTUnwrap(invocations.last(where: { !$0.isTerminfoInstall }))
        XCTAssertEqual(session.term, "xterm-ghostty", "\(shell): \(session)")
        XCTAssertTrue(
            session.args.contains("/home/alice/.ssh/cm"),
            "\(shell) must keep the user's -S argument: \(session.args)"
        )
        try assertNoTemporaryLeftovers(fixture, shell: shell)
    }

    func assertTeardownDoesNotReplayUserArguments(shell: SSHIntegrationShell) throws {
        try skipUnlessSSHShellAvailable(shell)
        let fixture = try makeSSHFixture(features: "ssh-env,ssh-terminfo", stubInfocmp: true)

        _ = try runSSHIntegration(shell: shell, command: "ssh -p 2222 example.invalid", fixture: fixture)

        let invocations = try fixture.invocations()
        let teardown = try XCTUnwrap(
            invocations.last(where: \.isControlExit),
            "\(shell) should tear down its own master: \(invocations)"
        )
        XCTAssertFalse(
            teardown.args.contains("-p") || teardown.args.contains("2222"),
            "\(shell): teardown must not replay the user's arguments: \(teardown.args)"
        )
        XCTAssertEqual(
            teardown.args.last, "example.invalid",
            "\(shell): teardown addresses the host only, for config resolution: \(teardown.args)"
        )
        XCTAssertTrue(
            teardown.args.contains(where: { $0.hasPrefix("ControlPath=") }),
            "\(shell): teardown must name our socket explicitly: \(teardown.args)"
        )
        // The session itself still carries the user's own options.
        let session = try XCTUnwrap(invocations.last(where: { !$0.isTerminfoInstall && !$0.isControlExit }))
        XCTAssertTrue(session.args.contains("2222"), "\(shell): \(session)")
        try assertNoTemporaryLeftovers(fixture, shell: shell)
    }

    func assertSurvivesUnsetGuard(shell: SSHIntegrationShell, prelude: String) throws {
        try skipUnlessSSHShellAvailable(shell)
        // ssh-terminfo alone leaves `ssh_opts` empty, and a `-G` without a hostname leaves
        // the identity scalars empty — the two shapes that used to abort under set -u.
        let fixture = try makeSSHFixture(
            features: "ssh-terminfo",
            stubInfocmp: true,
            reportsHostname: false
        )

        let result = try runSSHIntegration(
            shell: shell,
            command: "ssh example.invalid",
            fixture: fixture,
            prelude: prelude
        )

        for complaint in ["unbound variable", "parameter not set"] {
            XCTAssertFalse(
                result.stderr.contains(complaint),
                "\(shell) tripped over \(prelude): \(result.stderr)"
            )
        }
        let session = try XCTUnwrap(
            try fixture.invocations().last,
            "\(shell) never reached the real ssh under \(prelude), stderr=\(result.stderr)"
        )
        XCTAssertEqual(session.term, "xterm-256color", "\(shell): \(session)")
        XCTAssertEqual(session.args, ["example.invalid"], "\(shell): \(session)")
    }

    /// nushell collects a custom command's pipeline input before the body runs (verified on
    /// 0.113 with and without binding `$in`, and for closures), so this asserts delivery
    /// rather than streaming — see the note in zentty.nu.
    func assertPipedStdinIsForwarded(shell: SSHIntegrationShell, features: String) throws {
        try skipUnlessSSHShellAvailable(shell)
        let fixture = try makeSSHFixture(features: features, stubInfocmp: true, readsStandardInput: true)
        try fixture.seedCache(["alice@example.invalid"])

        _ = try runSSHIntegration(
            shell: shell,
            command: "\"payload-marker\" | ssh example.invalid cat",
            fixture: fixture
        )

        XCTAssertEqual(
            try fixture.forwardedStandardInput().trimmingCharacters(in: .whitespacesAndNewlines),
            "payload-marker",
            "\(shell) dropped the piped payload (features=\(features))"
        )
    }

    func assertPipedStdinStreams(shell: SSHIntegrationShell) throws {
        try skipUnlessSSHShellAvailable(shell)
        let fixture = try makeSSHFixture(
            features: "ssh-env,ssh-terminfo",
            stubInfocmp: true,
            readsStandardInput: true
        )
        try fixture.seedCache(["alice@example.invalid"])

        // The producer emits one line, waits, and only then records that it finished. A
        // wrapper that buffers the pipeline can only reach the stub after PRODUCER_DONE.
        let producer = "sh -c 'echo first-line; sleep 1; echo PRODUCER_DONE >> \"$ZENTTY_TEST_SSH_ORDER\"'"
        _ = try runSSHIntegration(
            shell: shell,
            command: "\(producer) | ssh example.invalid cat",
            fixture: fixture
        )

        XCTAssertEqual(
            try fixture.stdinArrivalOrder(), ["STUB_FIRST", "PRODUCER_DONE"],
            "\(shell) buffered the pipeline instead of streaming it to ssh"
        )
        XCTAssertTrue(
            try fixture.forwardedStandardInput().contains("first-line"),
            "\(shell) did not forward the payload"
        )
    }

    func assertNoTemporaryLeftovers(_ fixture: SSHFixture, shell: SSHIntegrationShell) throws {
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: fixture.tmpDirectory.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "\(shell) left ControlMaster scratch behind: \(leftovers)")
    }
}
