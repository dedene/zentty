import Darwin
import XCTest
@testable import Zentty

/// Drives `DockerCLIInspector` against fake `docker` executables. The real
/// inspector launches `/usr/bin/env docker …`, so a fake receives `docker` as
/// `$1` and the subcommand as `$2`.
final class DockerCLIInspectorProcessTests: XCTestCase {
    private var fixture: FakeExecutableFixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try FakeExecutableFixture(name: "DockerCLIInspectorProcessTests")
    }

    override func tearDownWithError() throws {
        fixture?.tearDown()
        fixture = nil
        try super.tearDownWithError()
    }

    func test_ps_that_ignores_sigterm_is_killed_and_reaped_on_timeout() throws {
        let pidFile = fixture.trackPIDFile(named: "ps.pid")
        // Docker CLI 29.x ignores the first SIGTERM; fill the pipe, then hang
        // in a process that keeps the same pid (exec) and the ignored signal.
        let fake = try fixture.makeExecutable(body: """
        if [ "$2" = "ps" ]; then
          echo $$ > '\(pidFile.path)'
          trap '' TERM
          printf '%0200000d' 0
          exec /bin/sleep 30
        fi
        exit 1
        """)
        try fixture.prewarm(fake)
        let inspector = makeInspector(fake, commandTimeout: 3)

        let startedAt = Date()
        XCTAssertThrowsError(try inspector.runningContainers()) { error in
            XCTAssertEqual(error as? DockerCLIError, .timedOut(subcommand: "ps"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 6)

        try fixture.assertProcessReaped(pidFile: pidFile, "timed-out docker child must be killed and reaped")
    }

    func test_parses_inspect_output_larger_than_the_pipe_buffer() throws {
        let inspectLine = #"{"Id":"c%d","Name":"/web-%d","Config":{"Image":"node:22","Labels":{"com.docker.compose.project.working_dir":"/tmp/project"},"Cmd":["npm","run","dev"],"Entrypoint":null},"NetworkSettings":{"Ports":{"5173/tcp":[{"HostIp":"0.0.0.0","HostPort":"5173"}]}}}\n"#
        let fake = try fixture.makeExecutable(body: """
        case "$2" in
          ps) for i in $(seq 1 1000); do echo "c$i"; done ;;
          inspect) for i in $(seq 1 1000); do printf '\(inspectLine)' "$i" "$i"; done ;;
          *) exit 1 ;;
        esac
        """)
        let inspector = makeInspector(fake, commandTimeout: 10)

        let containers = try inspector.runningContainers()

        XCTAssertEqual(containers.count, 1000)
        XCTAssertEqual(containers.first?.id, "c1")
        XCTAssertEqual(containers.last?.name, "web-1000")
        XCTAssertEqual(containers.first?.publishedPorts.first?.hostPort, 5173)
    }

    func test_passes_compact_format_and_ids_to_inspect() throws {
        let argsFile = fixture.directory.appendingPathComponent("inspect.args")
        let fake = try fixture.makeExecutable(body: """
        case "$2" in
          ps) printf 'a1\\nb2\\n' ;;
          inspect) printf '%s\\n' "$@" > '\(argsFile.path)' ;;
          *) exit 1 ;;
        esac
        """)

        XCTAssertEqual(try makeInspector(fake).runningContainers(), [])

        let arguments = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(arguments, ["docker", "inspect", "--format", DockerCLIInspector.inspectFormat, "a1", "b2"])
    }

    func test_no_running_containers_skips_inspect() throws {
        let fake = try fixture.makeExecutable(body: #"[ "$2" = "ps" ] && exit 0; exit 1"#)

        XCTAssertEqual(try makeInspector(fake).runningContainers(), [])
    }

    func test_daemon_down_fails_definitively_and_quickly() throws {
        // What `docker ps` does when the socket file lingers but no daemon listens.
        let fake = try fixture.makeExecutable(body: """
        echo 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?' >&2
        exit 1
        """)
        try fixture.prewarm(fake)
        let inspector = makeInspector(fake, commandTimeout: 5)

        let startedAt = Date()
        XCTAssertThrowsError(try inspector.runningContainers()) { error in
            XCTAssertEqual(
                error as? DockerCLIError,
                .commandFailed(
                    subcommand: "ps",
                    status: 1,
                    message: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"
                )
            )
            XCTAssertEqual((error as? DockerCLIError)?.isDefinitive, true)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2, "a fast failure must not wait for the command timeout")
    }

    func test_docker_missing_from_path_fails_definitively() throws {
        // The real lookup (`/usr/bin/env docker`) with a PATH that has no docker.
        let fake = try fixture.makeExecutable(body: #"exec /usr/bin/env PATH=/nonexistent-zentty-path "$@""#)

        XCTAssertThrowsError(try makeInspector(fake).runningContainers()) { error in
            guard case .commandFailed(subcommand: "ps", status: 127, _) = error as? DockerCLIError else {
                return XCTFail("expected env's 127 for a missing docker, got \(error)")
            }
        }
    }

    func test_launch_failure_is_definitive() {
        let inspector = makeInspector(fixture.directory.appendingPathComponent("missing-docker"))

        XCTAssertThrowsError(try inspector.runningContainers()) { error in
            guard case .launchFailed(subcommand: "ps", _) = error as? DockerCLIError else {
                return XCTFail("expected launchFailed, got \(error)")
            }
            XCTAssertEqual((error as? DockerCLIError)?.isDefinitive, true)
        }
    }

    func test_non_zero_inspect_exit_throws() throws {
        let fake = try fixture.makeExecutable(body: """
        case "$2" in
          ps) echo a1 ;;
          *) echo 'permission denied' >&2; exit 1 ;;
        esac
        """)

        XCTAssertThrowsError(try makeInspector(fake).runningContainers()) { error in
            XCTAssertEqual(error as? DockerCLIError, .commandFailed(subcommand: "inspect", status: 1, message: "permission denied"))
        }
    }

    func test_container_that_vanished_before_inspect_keeps_the_others() throws {
        let fake = try fixture.makeExecutable(body: """
        case "$2" in
          ps) printf 'gone\\nweb\\n' ;;
          inspect)
            echo '{"Id":"web","Name":"/web","Config":{"Image":"node","Labels":null,"Cmd":null,"Entrypoint":null},"NetworkSettings":{"Ports":null}}'
            echo 'error: no such object: gone' >&2
            exit 1 ;;
        esac
        """)

        let containers = try makeInspector(fake).runningContainers()

        XCTAssertEqual(containers.map(\.id), ["web"])
    }

    func test_socket_check_does_not_launch_docker() {
        let inspector = DockerCLIInspector(
            dockerExecutableURL: URL(fileURLWithPath: "/path/that/must/not/be/launched"),
            socketExists: { _ in true }
        )

        XCTAssertTrue(inspector.hasDockerSocket())
    }

    // MARK: - Inspect format parsing

    func test_parses_compact_inspect_lines_and_tolerates_null_fields() {
        // Shape captured from `docker inspect --format DockerCLIInspector.inspectFormat`
        // (Docker 29.7): `Cmd`, `Labels` and `Ports` can be `null`, and an
        // exposed-but-unpublished port maps to an empty array.
        let output = Data("""
        {"Id":"pg","Name":"/rubrikit-postgres-1","Config":{"Image":"postgres:18","Labels":{"com.docker.compose.project.working_dir":"/tmp/project"},"Cmd":["postgres"],"Entrypoint":["docker-entrypoint.sh"]},"NetworkSettings":{"Ports":{"5432/tcp":[{"HostIp":"0.0.0.0","HostPort":"5433"},{"HostIp":"::","HostPort":"5433"}]}}}
        {"Id":"mail","Name":"/mailpit","Config":{"Image":"axllent/mailpit","Labels":null,"Cmd":null,"Entrypoint":["/mailpit"]},"NetworkSettings":{"Ports":{"1025/tcp":[],"8025/tcp":null}}}
        {"Id":"bare","Name":"/bare","Config":{"Image":"busybox","Labels":{},"Cmd":null,"Entrypoint":null},"NetworkSettings":{"Ports":null}}

        """.utf8)

        let containers = DockerCLIInspector.containers(fromInspectOutput: output)

        XCTAssertEqual(containers.map(\.id), ["pg", "mail", "bare"])
        XCTAssertEqual(containers[0].name, "rubrikit-postgres-1")
        XCTAssertEqual(containers[0].command, "postgres")
        XCTAssertEqual(containers[0].labels["com.docker.compose.project.working_dir"], "/tmp/project")
        XCTAssertEqual(
            containers[0].publishedPorts.sorted { $0.hostIP < $1.hostIP },
            [
                DockerPublishedPort(hostIP: "0.0.0.0", hostPort: 5433, containerPort: 5432, protocolName: "tcp"),
                DockerPublishedPort(hostIP: "::", hostPort: 5433, containerPort: 5432, protocolName: "tcp"),
            ]
        )
        XCTAssertEqual(containers[1].labels, [:])
        XCTAssertEqual(containers[1].command, "/mailpit")
        XCTAssertEqual(containers[1].publishedPorts, [])
        XCTAssertEqual(containers[2].command, "")
        XCTAssertEqual(containers[2].publishedPorts, [])
    }

    func test_skips_malformed_inspect_line() {
        let output = Data("""
        {"Id":"a","Name":"/a","Config":{"Image":"node","Labels":null,"Cmd":null,"Entrypoint":null},"NetworkSettings":{"Ports":null}}
        template: :1: function "jsn" not defined
        {"Id":"b","Name":"/b","Config":{"Image":"node","Labels":null,"Cmd":null,"Entrypoint":null},"NetworkSettings":{"Ports":null}}
        """.utf8)

        XCTAssertEqual(DockerCLIInspector.containers(fromInspectOutput: output).map(\.id), ["a", "b"])
    }

    // MARK: - Helpers

    private func makeInspector(_ executable: URL, commandTimeout: TimeInterval = 5) -> DockerCLIInspector {
        DockerCLIInspector(
            dockerExecutableURL: executable,
            socketExists: { _ in true },
            commandTimeout: commandTimeout
        )
    }
}
