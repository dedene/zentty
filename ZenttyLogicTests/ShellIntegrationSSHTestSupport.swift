import Foundation
import XCTest

// Shared harness for the ssh-wrapper tests in ShellIntegrationSSHPosixTests and
// ShellIntegrationSSHModernTests: the stub `ssh`/`infocmp` scripts, the fixture that
// isolates HOME/XDG_STATE_HOME/TMPDIR, the shell launchers, and the log parsing.
// Assertions live in ShellIntegrationSSHAssertions.swift.

struct SSHInvocation: CustomStringConvertible {
    let term: String
    let colorterm: String
    let isTerminfoInstall: Bool
    let isControlExit: Bool
    let args: [String]

    var description: String {
        "SSHInvocation(TERM=\(term), COLORTERM=\(colorterm), install=\(isTerminfoInstall), "
            + "controlExit=\(isControlExit), args=\(args))"
    }
}

struct SSHFixture {
    let root: URL
    let tmpDirectory: URL
    let environment: [String: String]
    let logURL: URL
    let stdinURL: URL
    let terminfoURL: URL
    let orderURL: URL
    let cacheURL: URL

    /// What the stub prints on stdout for a real session, so a test can prove the
    /// wrapper's value is captured (`x=$(ssh …)`) and not merely printed.
    static let remoteOutputMarker = "zentty-remote-output"

    /// Forget the invocations recorded so far, so a second run can be inspected alone.
    func resetLog() {
        try? FileManager.default.removeItem(at: logURL)
    }

    /// Markers in arrival order: `STUB_FIRST` when the stub read the payload's first
    /// line, `PRODUCER_DONE` when the producer finished writing.
    func stdinArrivalOrder() throws -> [String] {
        guard let raw = try? String(contentsOf: orderURL, encoding: .utf8) else { return [] }
        return raw.split(whereSeparator: \.isNewline).map(String.init)
    }

    func seedCache(_ targets: [String]) throws {
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (targets.joined(separator: "\n") + "\n").write(to: cacheURL, atomically: true, encoding: .utf8)
    }

    func cacheLines() throws -> [String] {
        guard let raw = try? String(contentsOf: cacheURL, encoding: .utf8) else { return [] }
        return raw.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// The terminfo the wrapper delivered to the remote host (base64-decoded by the stub).
    func installedTerminfo() throws -> String {
        (try? String(contentsOf: terminfoURL, encoding: .utf8)) ?? ""
    }

    func forwardedStandardInput() throws -> String {
        (try? String(contentsOf: stdinURL, encoding: .utf8)) ?? ""
    }

    func invocations() throws -> [SSHInvocation] {
        guard let raw = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return raw
            .components(separatedBy: "--INVOCATION--")
            .dropFirst()
            .map { block -> SSHInvocation in
                var term = ""
                var colorterm = ""
                var install = false
                var controlExit = false
                var args: [String] = []
                for line in block.split(whereSeparator: \.isNewline).map(String.init) {
                    if line.hasPrefix("TERM=") {
                        term = String(line.dropFirst("TERM=".count))
                    } else if line.hasPrefix("COLORTERM=") {
                        colorterm = String(line.dropFirst("COLORTERM=".count))
                    } else if line == "INSTALL=1" {
                        install = true
                    } else if line == "CONTROLEXIT=1" {
                        controlExit = true
                    } else if line.hasPrefix("ARG=") {
                        args.append(String(line.dropFirst("ARG=".count)))
                    }
                }
                return SSHInvocation(
                    term: term,
                    colorterm: colorterm,
                    isTerminfoInstall: install,
                    isControlExit: controlExit,
                    args: args
                )
            }
    }
}

struct ShellRunResult {
    let stdout: String
    let stderr: String
    let status: Int32
}


/// The scripts the fixture drops on PATH in place of the real `ssh` and `infocmp`.
enum SSHStubScripts {
    /// Stand-in for OpenSSH. `-G` answers with a fixed identity plus the session type implied
    /// by `-N`/`-s`; an invocation carrying `-o RemoteCommand=` is the terminfo installer and is
    /// refused (exit 255, OpenSSH's own message) when the user also passed a remote command;
    /// `-O exit` is the control-master teardown. Everything else is a real session.
    static let ssh = #"""
    #!/bin/sh
    if [ "$1" = "-G" ]; then
        sessiontype=default
        for arg in "$@"; do
            case "$arg" in
                -N) sessiontype=none ;;
                -s) sessiontype=subsystem ;;
            esac
        done
        hostname=${ZENTTY_TEST_SSH_HOSTNAME-example.invalid}
        if [ -n "$hostname" ]; then
            printf 'user alice\nhostname %s\n' "$hostname"
        fi
        printf 'sessiontype %s\ncontrolpath %s\n' "$sessiontype" "${ZENTTY_TEST_SSH_CONTROLPATH:-none}"
        # Padding that mirrors a real `ssh -G`: keys we ignore, and multi-word values
        # that pin how each shell splits a line (first token, then the whole rest).
        printf 'port 22\naddressfamily any\nbatchmode no\ncanonicalizehostname false\n'
        printf 'proxycommand ssh -W a:b bastion\nlocalcommand echo one two three\n'
        printf 'identityfile ~/.ssh/id_ed25519\nloglevel INFO\nserveraliveinterval 0\n'
        printf 'stricthostkeychecking ask\nuserknownhostsfile ~/.ssh/known_hosts ~/.ssh/known_hosts2\n'
        exit 0
    fi
    {
        echo "--INVOCATION--"
        echo "TERM=${TERM-}"
        echo "COLORTERM=${COLORTERM-}"
        for arg in "$@"; do echo "ARG=$arg"; done
    } >> "$ZENTTY_TEST_SSH_LOG"
    install=0
    control_exit=0
    remote_command=""
    positional=0
    while [ $# -gt 0 ]; do
        case "$1" in
            -O) control_exit=1; shift 2 || shift ;;
            -o)
                case "$2" in
                    RemoteCommand=*) install=1; remote_command=${2#RemoteCommand=} ;;
                esac
                shift 2 || shift ;;
            --) shift ;;
            -b|-c|-D|-E|-e|-F|-I|-i|-J|-L|-l|-m|-p|-Q|-R|-S|-W|-w) shift 2 || shift ;;
            -*) shift ;;
            *) positional=$((positional + 1)); shift ;;
        esac
    done
    {
        echo "INSTALL=$install"
        echo "CONTROLEXIT=$control_exit"
    } >> "$ZENTTY_TEST_SSH_LOG"
    if [ "$install" = "1" ]; then
        if [ "$positional" -ge 2 ]; then
            echo "Cannot execute command-line and remote command." >&2
            exit 255
        fi
        printf '%s' "$remote_command" \
            | sed -n "s/.*echo '\([A-Za-z0-9+/=]*\)'.*/\1/p" \
            | base64 -d >> "$ZENTTY_TEST_SSH_TERMINFO" 2>/dev/null
        exit "${ZENTTY_TEST_SSH_INSTALL_EXIT:-0}"
    fi
    if [ "$control_exit" = "1" ]; then
        exit 0
    fi
    if [ -n "${ZENTTY_TEST_SSH_STDOUT-}" ]; then
        printf '%s\n' "$ZENTTY_TEST_SSH_STDOUT"
    fi
    if [ "${ZENTTY_TEST_SSH_READ_STDIN:-0}" = "1" ]; then
        # Note the arrival of the first line so a test can tell streaming from buffering.
        IFS= read -r first_line
        echo "STUB_FIRST" >> "$ZENTTY_TEST_SSH_ORDER"
        printf '%s\n' "$first_line" >> "$ZENTTY_TEST_SSH_STDIN"
        cat >> "$ZENTTY_TEST_SSH_STDIN"
    fi
    exit "${ZENTTY_TEST_SSH_EXIT:-0}"
    """#

    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

extension XCTestCase {


    func makeSSHFixture(
        features: String,
        stubInfocmp: Bool = false,
        installExitCode: Int = 0,
        sessionExitCode: Int = 0,
        readsStandardInput: Bool = false,
        longTemporaryDirectory: Bool = false,
        userControlPath: String = "none",
        reportsHostname: Bool = true
    ) throws -> SSHFixture {
        let root = try makeSSHTemporaryDirectory(named: "shell-ssh-fixture")
        let stubBin = root.appendingPathComponent("bin", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        // The default TMPDIR must stay short: the wrapper puts its ControlMaster socket
        // there, and a Unix domain socket path (plus OpenSSH's ~17-char bind suffix) has to
        // fit in ~104 bytes. The system temporary directory is already ~49 chars on macOS,
        // which is exactly the case `longTemporaryDirectory` exercises.
        let tmp = longTemporaryDirectory
            ? root.appendingPathComponent("tmp", isDirectory: true)
            : try makeShortSSHTemporaryDirectory()
        for directory in [stubBin, home, state, tmp] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let logURL = root.appendingPathComponent("ssh.log", isDirectory: false)
        let stdinURL = root.appendingPathComponent("ssh-stdin.log", isDirectory: false)
        let terminfoURL = root.appendingPathComponent("installed-terminfo.txt", isDirectory: false)
        let orderURL = root.appendingPathComponent("stdin-order.log", isDirectory: false)

        try writeSSHStubExecutable(SSHStubScripts.ssh, to: stubBin.appendingPathComponent("ssh", isDirectory: false))

        try writeSSHStubExecutable(
            stubInfocmp
                ? "#!/bin/sh\necho 'xterm-ghostty|stub terminfo for tests,'"
                // A cache-miss path with no usable infocmp must fall back rather than install.
                : "#!/bin/sh\nexit 1",
            to: stubBin.appendingPathComponent("infocmp", isDirectory: false)
        )

        let environment: [String: String] = [
            "GHOSTTY_SHELL_FEATURES": features,
            "HOME": home.path,
            // Pin the locale so shell diagnostics ("unbound variable") stay in English.
            "LC_ALL": "C",
            "PATH": [stubBin.path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":"),
            "TERM": "xterm-ghostty",
            "TMPDIR": tmp.path,
            "TTY": "/dev/null",
            "USER": ProcessInfo.processInfo.environment["USER"] ?? "tester",
            "XDG_STATE_HOME": state.path,
            "ZENTTY_FORCE_SHELL_INTEGRATION": "1",
            "ZENTTY_SHELL_INTEGRATION": "0",
            "ZENTTY_TEST_SSH_CONTROLPATH": userControlPath,
            "ZENTTY_TEST_SSH_EXIT": "\(sessionExitCode)",
            "ZENTTY_TEST_SSH_HOSTNAME": reportsHostname ? "example.invalid" : "",
            "ZENTTY_TEST_SSH_ORDER": orderURL.path,
            "ZENTTY_TEST_SSH_INSTALL_EXIT": "\(installExitCode)",
            "ZENTTY_TEST_SSH_LOG": logURL.path,
            "ZENTTY_TEST_SSH_READ_STDIN": readsStandardInput ? "1" : "0",
            "ZENTTY_TEST_SSH_STDIN": stdinURL.path,
            "ZENTTY_TEST_SSH_STDOUT": SSHFixture.remoteOutputMarker,
            "ZENTTY_TEST_SSH_TERMINFO": terminfoURL.path,
        ]

        return SSHFixture(
            root: root,
            tmpDirectory: tmp,
            environment: environment,
            logURL: logURL,
            stdinURL: stdinURL,
            terminfoURL: terminfoURL,
            orderURL: orderURL,
            cacheURL: state
                .appendingPathComponent("zentty", isDirectory: true)
                .appendingPathComponent("ssh_cache", isDirectory: false)
        )
    }



    @discardableResult
    func runSSHIntegration(
        shell: SSHIntegrationShell,
        command: String,
        fixture: SSHFixture,
        prelude: String = ""
    ) throws -> ShellRunResult {
        guard let executable = shell.executablePath else {
            throw XCTSkip("\(shell) not available on this host")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        let script = (prelude.isEmpty ? "" : prelude + "\n")
            + "source \(SSHStubScripts.singleQuoted(shell.integrationScriptURL.path))\n\(command)\n"
        process.arguments = shell.arguments(for: script)
        process.currentDirectoryURL = fixture.root
        process.environment = fixture.environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ShellRunResult(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            status: process.terminationStatus
        )
    }

    func skipUnlessSSHShellAvailable(_ shell: SSHIntegrationShell) throws {
        guard shell.executablePath != nil else {
            throw XCTSkip("\(shell) not available on this host")
        }
    }

    func writeSSHStubExecutable(_ contents: String, to url: URL) throws {
        try (contents + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// A temp dir short enough to host a Unix domain socket: `/tmp/zentty-ssh-test.XXXXXX`
    /// is 27 chars, where the system temporary directory alone is already ~49 on macOS.
    func makeShortSSHTemporaryDirectory() throws -> URL {
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6))
        let url = URL(fileURLWithPath: "/tmp/zentty-ssh-test.\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func makeSSHTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

enum SSHIntegrationShell: CustomStringConvertible {
    case zsh
    /// System bash 3.2 — the version macOS ships and most users still run.
    case bash
    /// Homebrew bash 5.x, skipped when it is not installed.
    case bash5
    case fish
    case nu

    /// System bash plus, when present, Homebrew's bash 5. When bash 5 is missing the
    /// caller still runs bash 3.2; `ShellIntegrationSSHPosixTests.test_bash5_…` records
    /// the gap as a skip so the lost coverage is visible in the report.
    static var bashVariants: [SSHIntegrationShell] {
        SSHIntegrationShell.bash5.executablePath == nil ? [.bash] : [.bash, .bash5]
    }

    var description: String {
        switch self {
        case .zsh: return "zsh"
        case .bash: return "bash(3.2)"
        case .bash5: return "bash(5.x)"
        case .fish: return "fish"
        case .nu: return "nu"
        }
    }

    var executablePath: String? {
        switch self {
        case .zsh:
            return "/bin/zsh"
        case .bash:
            return "/bin/bash"
        case .bash5:
            return ["/opt/homebrew/bin/bash", "/usr/local/bin/bash"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        case .fish, .nu:
            let name = self == .fish ? "fish" : "nu"
            return ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        }
    }

    func arguments(for command: String) -> [String] {
        switch self {
        case .zsh:
            return ["-f", "-c", command]
        case .bash, .bash5:
            return ["--noprofile", "--norc", "-c", command]
        case .fish:
            return ["--no-config", "-c", command]
        case .nu:
            return ["--no-config-file", "-c", command]
        }
    }

    /// Whether this shell's wrapper opens a ControlMaster of its own for the terminfo
    /// probe. nushell does not: its session has to be the command's final expression, so
    /// there is nowhere to tear a master down (see the note in zentty.nu).
    var opensOwnControlMaster: Bool { self != .nu }

    /// Runs `command`, captures its stdout into a variable, and echoes it back as
    /// `captured=[…]` — the shell-specific spelling of `x=$(…)`.
    func captureCommand(assigning command: String) -> String {
        switch self {
        case .zsh, .bash, .bash5:
            return "captured_value=$(\(command)); echo \"captured=[$captured_value]\""
        case .fish:
            return "set -l captured_value (\(command)); echo \"captured=[$captured_value]\""
        case .nu:
            return "let captured_value = (\(command)); print $\"captured=[($captured_value | str trim)]\""
        }
    }

    var integrationScriptURL: URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let filename: String
        switch self {
        case .zsh: filename = "zentty-zsh-integration.zsh"
        case .bash, .bash5: filename = "zentty-bash-integration.bash"
        case .fish: filename = "fish/vendor_conf.d/zentty-shell-integration.fish"
        case .nu: filename = "nushell/vendor/autoload/zentty.nu"
        }
        return repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("shell-integration", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }
}
