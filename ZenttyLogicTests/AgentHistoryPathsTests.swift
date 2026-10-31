import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryPathsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    func test_production_flavor_path() {
        let paths = AgentHistoryPaths.resolve(environment: [:], homeDirectoryURL: home, flavor: .production)
        XCTAssertEqual(paths.directoryURL.path, "/Users/tester/Library/Application Support/Zentty/AgentHistory")
    }

    func test_dev_flavor_path() {
        let paths = AgentHistoryPaths.resolve(environment: [:], homeDirectoryURL: home, flavor: .dev)
        XCTAssertEqual(paths.directoryURL.path, "/Users/tester/Library/Application Support/Zentty Dev/AgentHistory")
    }

    func test_default_config_file_keeps_flavor_path() {
        let configURL = AppConfigStore.defaultFileURL(homeDirectoryURL: home, flavor: .dev)
        let paths = AgentHistoryPaths.resolve(environment: [:], homeDirectoryURL: home, flavor: .dev, configFileURL: configURL)
        XCTAssertEqual(paths.directoryURL.path, "/Users/tester/Library/Application Support/Zentty Dev/AgentHistory")
    }

    func test_xctest_environment_uses_temporary_directory() {
        let paths = AgentHistoryPaths.resolve(
            environment: ["XCTestConfigurationFilePath": "/tmp/whatever.xctestconfiguration"],
            homeDirectoryURL: home,
            flavor: .production,
            configFileURL: AppConfigStore.defaultFileURL(homeDirectoryURL: home, flavor: .production)
        )
        let expected = FileManager.default.temporaryDirectory
            .appendingPathComponent("zentty-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            .appendingPathComponent("AgentHistory", isDirectory: true)
        XCTAssertEqual(paths.directoryURL.standardizedFileURL.path, expected.standardizedFileURL.path)
        XCTAssertFalse(paths.directoryURL.path.hasPrefix(home.path))
    }

    func test_override_environment_wins() {
        let environment = [
            AgentHistoryPaths.overrideEnvironmentKey: "~/custom/history",
            "XCTestConfigurationFilePath": "/tmp/whatever.xctestconfiguration",
        ]
        let paths = AgentHistoryPaths.resolve(
            environment: environment,
            homeDirectoryURL: home,
            flavor: .production,
            configFileURL: URL(fileURLWithPath: "/tmp/other/config.toml")
        )
        XCTAssertEqual(paths.directoryURL.path, "/Users/tester/custom/history")

        let absolute = AgentHistoryPaths.resolve(
            environment: [AgentHistoryPaths.overrideEnvironmentKey: "/var/tmp/h"],
            homeDirectoryURL: home
        )
        XCTAssertEqual(absolute.directoryURL.path, "/var/tmp/h")

        let blank = AgentHistoryPaths.resolve(
            environment: [AgentHistoryPaths.overrideEnvironmentKey: "  "],
            homeDirectoryURL: home,
            flavor: .production
        )
        XCTAssertEqual(blank.directoryURL.path, "/Users/tester/Library/Application Support/Zentty/AgentHistory")
    }

    func test_non_default_config_file_puts_index_beside_it() {
        let paths = AgentHistoryPaths.resolve(
            environment: [:],
            homeDirectoryURL: home,
            flavor: .production,
            configFileURL: URL(fileURLWithPath: "/tmp/zentty-fixture/config.toml")
        )
        XCTAssertEqual(paths.directoryURL.path, "/tmp/zentty-fixture/AgentHistory")
    }

    func test_file_names() {
        let paths = AgentHistoryPaths(directoryURL: URL(fileURLWithPath: "/x/AgentHistory", isDirectory: true))
        XCTAssertEqual(paths.databaseURL.path, "/x/AgentHistory/index.sqlite")
        XCTAssertEqual(paths.walURL.path, "/x/AgentHistory/index.sqlite-wal")
        XCTAssertEqual(paths.shmURL.path, "/x/AgentHistory/index.sqlite-shm")
        XCTAssertEqual(paths.stateURL.path, "/x/AgentHistory/state.json")
        XCTAssertEqual(paths.lockURL.path, "/x/AgentHistory/index.lock")

        // 2026-10-31 10:15:00 UTC
        let date = Date(timeIntervalSince1970: 1_793_441_700)
        XCTAssertEqual(paths.corruptDatabaseURL(at: date).lastPathComponent, "index.corrupt-20261031T101500Z.sqlite")
        XCTAssertTrue(AgentHistoryPaths.isCorruptCopyName("index.corrupt-20261031T101500Z.sqlite"))
        XCTAssertFalse(AgentHistoryPaths.isCorruptCopyName("index.sqlite"))
        XCTAssertFalse(AgentHistoryPaths.isCorruptCopyName("state.json"))
    }
}
