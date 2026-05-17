import XCTest
@testable import Zentty

final class DockerServerDiscoveryTests: XCTestCase {
    private let worklaneID = WorklaneID("worklane-1")
    private let paneA = PaneID("pane-a")
    private let paneB = PaneID("pane-b")
    private let date = Date(timeIntervalSince1970: 2_000)

    func test_skips_when_docker_is_not_responsive() throws {
        let date = date
        let discovery = DockerServerDiscovery(
            dockerInspector: FakeDockerInspector(isResponsive: false, containers: [webContainer()]),
            currentDate: { date }
        )

        XCTAssertTrue(discovery.discover(context: context()).isEmpty)
    }

    func test_discovers_compose_web_service_published_port() throws {
        let date = date
        let discovery = DockerServerDiscovery(
            dockerInspector: FakeDockerInspector(isResponsive: true, containers: [webContainer()]),
            currentDate: { date }
        )

        let servers = discovery.discover(context: context())

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].origin, "http://localhost:5173")
        XCTAssertEqual(servers[0].paneID, paneA)
        XCTAssertEqual(servers[0].source, .docker)
        XCTAssertEqual(servers[0].confidence, .cwd)
    }

    func test_ignores_postgres_and_redis_ports() throws {
        let date = date
        let discovery = DockerServerDiscovery(
            dockerInspector: FakeDockerInspector(
                isResponsive: true,
                containers: [
                    dbContainer(name: "postgres", image: "postgres:16", hostPort: 5432, containerPort: 5432),
                    dbContainer(name: "redis", image: "redis:7", hostPort: 6379, containerPort: 6379),
                ]
            ),
            currentDate: { date }
        )

        XCTAssertTrue(discovery.discover(context: context()).isEmpty)
    }

    func test_matches_compose_project_path_to_worklane_path() throws {
        let date = date
        let matching = webContainer(projectPath: "/tmp/project")
        let unrelated = webContainer(id: "other", projectPath: "/tmp/other", hostPort: 3001)
        let discovery = DockerServerDiscovery(
            dockerInspector: FakeDockerInspector(isResponsive: true, containers: [matching, unrelated]),
            currentDate: { date }
        )

        let servers = discovery.discover(context: context())

        XCTAssertEqual(servers.map(\.origin), ["http://localhost:5173"])
    }

    func test_unrelated_compose_path_is_not_included_by_generic_npm_run_command() throws {
        let date = date
        let discovery = DockerServerDiscovery(
            dockerInspector: FakeDockerInspector(
                isResponsive: true,
                containers: [webContainer(projectPath: "/tmp/other")]
            ),
            currentDate: { date }
        )

        let servers = discovery.discover(context: DockerDiscoveryContext(
            worklaneID: worklaneID,
            focusedPaneID: paneA,
            panes: [
                DockerPaneContext(paneID: paneA, workingDirectory: "/tmp/project", recentCommandLines: ["npm run dev"])
            ]
        ))

        XCTAssertTrue(servers.isEmpty)
    }

    func test_assigns_matching_container_to_focused_or_recent_pane_for_path() throws {
        let date = date
        let discovery = DockerServerDiscovery(
            dockerInspector: FakeDockerInspector(isResponsive: true, containers: [webContainer(projectPath: "/tmp/project")]),
            currentDate: { date }
        )

        let servers = discovery.discover(context: DockerDiscoveryContext(
            worklaneID: worklaneID,
            focusedPaneID: paneB,
            panes: [
                DockerPaneContext(paneID: paneA, workingDirectory: "/tmp/project", recentCommandLines: ["docker compose up"]),
                DockerPaneContext(paneID: paneB, workingDirectory: "/tmp/project/frontend", recentCommandLines: []),
            ]
        ))

        XCTAssertEqual(servers.single?.paneID, paneB)
    }

    func test_assigns_matching_container_to_deepest_pane_for_nested_path() throws {
        let date = date
        let discovery = DockerServerDiscovery(
            dockerInspector: FakeDockerInspector(
                isResponsive: true,
                containers: [webContainer(projectPath: "/tmp/project/frontend")]
            ),
            currentDate: { date }
        )

        let servers = discovery.discover(context: DockerDiscoveryContext(
            worklaneID: worklaneID,
            focusedPaneID: nil,
            panes: [
                DockerPaneContext(paneID: paneA, workingDirectory: "/tmp/project", recentCommandLines: []),
                DockerPaneContext(paneID: paneB, workingDirectory: "/tmp/project/frontend", recentCommandLines: []),
            ]
        ))

        XCTAssertEqual(servers.single?.paneID, paneB)
    }

    func test_web_container_does_not_emit_non_web_published_ports() throws {
        let date = date
        let container = DockerContainer(
            id: "web",
            name: "web",
            image: "node:22",
            command: "npm run vite",
            labels: [
                "com.docker.compose.project.working_dir": "/tmp/project",
                "com.docker.compose.service": "web",
            ],
            publishedPorts: [
                DockerPublishedPort(hostIP: "0.0.0.0", hostPort: 5173, containerPort: 5173, protocolName: "tcp"),
                DockerPublishedPort(hostIP: "0.0.0.0", hostPort: 9229, containerPort: 9229, protocolName: "tcp"),
            ]
        )
        let discovery = DockerServerDiscovery(
            dockerInspector: FakeDockerInspector(isResponsive: true, containers: [container]),
            currentDate: { date }
        )

        let servers = discovery.discover(context: context())

        XCTAssertEqual(servers.map(\.origin), ["http://localhost:5173"])
    }

    func test_cli_inspector_returns_not_responsive_without_existing_docker_socket() {
        let inspector = DockerCLIInspector(
            dockerExecutableURL: URL(fileURLWithPath: "/path/that/must/not/be/launched"),
            socketExists: { _ in false }
        )

        XCTAssertFalse(inspector.isDockerResponsive())
    }

    func test_dip_command_or_config_enables_docker_discovery() throws {
        let date = date
        let container = DockerContainer(
            id: "web",
            name: "app",
            image: "ruby:3.3",
            command: "bin/rails server",
            labels: [:],
            publishedPorts: [
                DockerPublishedPort(hostIP: "0.0.0.0", hostPort: 3000, containerPort: 3000, protocolName: "tcp")
            ]
        )
        let discovery = DockerServerDiscovery(
            dockerInspector: FakeDockerInspector(isResponsive: true, containers: [container]),
            currentDate: { date }
        )

        let servers = discovery.discover(context: DockerDiscoveryContext(
            worklaneID: worklaneID,
            focusedPaneID: paneA,
            panes: [
                DockerPaneContext(paneID: paneA, workingDirectory: "/tmp/project", recentCommandLines: ["dip up web"])
            ]
        ))

        XCTAssertEqual(servers.single?.origin, "http://localhost:3000")
        XCTAssertNil(servers.single?.paneID)
        XCTAssertEqual(servers.single?.confidence, .worklane)
    }

    private func context() -> DockerDiscoveryContext {
        DockerDiscoveryContext(
            worklaneID: worklaneID,
            focusedPaneID: paneA,
            panes: [
                DockerPaneContext(paneID: paneA, workingDirectory: "/tmp/project", recentCommandLines: [])
            ]
        )
    }

    private func webContainer(
        id: String = "web",
        projectPath: String = "/tmp/project",
        hostPort: Int = 5173
    ) -> DockerContainer {
        DockerContainer(
            id: id,
            name: "project-web-1",
            image: "node:22",
            command: "npm run vite -- --host 0.0.0.0",
            labels: [
                "com.docker.compose.project.working_dir": projectPath,
                "com.docker.compose.service": "web",
            ],
            publishedPorts: [
                DockerPublishedPort(hostIP: "0.0.0.0", hostPort: hostPort, containerPort: 5173, protocolName: "tcp")
            ]
        )
    }

    private func dbContainer(
        name: String,
        image: String,
        hostPort: Int,
        containerPort: Int
    ) -> DockerContainer {
        DockerContainer(
            id: name,
            name: name,
            image: image,
            command: image,
            labels: [
                "com.docker.compose.project.working_dir": "/tmp/project",
                "com.docker.compose.service": name,
            ],
            publishedPorts: [
                DockerPublishedPort(hostIP: "0.0.0.0", hostPort: hostPort, containerPort: containerPort, protocolName: "tcp")
            ]
        )
    }
}

private struct FakeDockerInspector: DockerInspecting {
    let isResponsive: Bool
    let containers: [DockerContainer]

    func isDockerResponsive() -> Bool {
        isResponsive
    }

    func runningContainers() throws -> [DockerContainer] {
        containers
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? self[0] : nil
    }
}
