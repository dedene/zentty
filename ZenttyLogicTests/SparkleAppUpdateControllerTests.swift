import Foundation
import Sparkle
import XCTest
@testable import Zentty

@MainActor
final class SparkleAppUpdateControllerTests: XCTestCase {
    func test_make_default_app_update_controller_returns_noop_without_sparkle_bundle_configuration() throws {
        let stateStore = AppUpdateStateStore()
        let controller = makeDefaultAppUpdateController(
            configStore: makeConfigStore(),
            stateStore: stateStore,
            bundle: try makeTemporaryBundle(named: "SparkleUnconfigured", includeSparkleConfiguration: false)
        )

        XCTAssertTrue(controller is NoOpAppUpdateController)
        XCTAssertTrue(controller.updateStateStore === stateStore)
    }

    func test_make_default_app_update_controller_returns_sparkle_controller_with_configured_bundle() throws {
        let stateStore = AppUpdateStateStore()
        let controller = makeDefaultAppUpdateController(
            configStore: makeConfigStore(),
            stateStore: stateStore,
            bundle: try makeTemporarySparkleBundle(named: "SparkleConfigured")
        )

        XCTAssertTrue(controller is SparkleAppUpdateController)
        XCTAssertTrue(controller.updateStateStore === stateStore)
    }

    func test_sparkle_controller_responds_to_real_user_choice_delegate_selector() throws {
        let controller = try makeConfiguredSparkleController(named: "SparkleSelector")

        XCTAssertTrue(
            (controller as AnyObject).responds(
                to: NSSelectorFromString("updater:userDidMakeChoice:forUpdate:state:")
            )
        )
    }

    func test_sparkle_controller_marks_update_available_when_valid_update_is_found() throws {
        let stateStore = AppUpdateStateStore()
        let controller = try makeConfiguredSparkleController(
            named: "SparkleDidFindUpdate",
            stateStore: stateStore
        )

        controller.updater(fakeUpdater(), didFindValidUpdate: try makeAppcastItem())

        XCTAssertTrue(stateStore.current.isUpdateAvailable)
    }

    func test_sparkle_controller_clears_update_available_when_update_is_not_found() throws {
        let stateStore = AppUpdateStateStore()
        stateStore.setUpdateAvailable(true)
        let controller = try makeConfiguredSparkleController(
            named: "SparkleDidNotFindUpdate",
            stateStore: stateStore
        )

        controller.updaterDidNotFindUpdate(fakeUpdater())

        XCTAssertFalse(stateStore.current.isUpdateAvailable)
    }

    func test_sparkle_controller_clears_update_available_when_user_skips_update() throws {
        let stateStore = AppUpdateStateStore()
        stateStore.setUpdateAvailable(true)
        let controller = try makeConfiguredSparkleController(
            named: "SparkleSkipUpdate",
            stateStore: stateStore
        )

        controller.updater(
            fakeUpdater(),
            userDidMake: .skip,
            forUpdate: try makeAppcastItem(),
            state: fakeUserUpdateState()
        )

        XCTAssertFalse(stateStore.current.isUpdateAvailable)
    }

    func test_sparkle_controller_clears_update_available_when_user_installs_update() throws {
        let stateStore = AppUpdateStateStore()
        stateStore.setUpdateAvailable(true)
        let controller = try makeConfiguredSparkleController(
            named: "SparkleInstallUpdate",
            stateStore: stateStore
        )

        controller.updater(
            fakeUpdater(),
            userDidMake: .install,
            forUpdate: try makeAppcastItem(),
            state: fakeUserUpdateState()
        )

        XCTAssertFalse(stateStore.current.isUpdateAvailable)
    }

    func test_sparkle_controller_keeps_update_available_when_user_dismisses_update() throws {
        let stateStore = AppUpdateStateStore()
        stateStore.setUpdateAvailable(true)
        let controller = try makeConfiguredSparkleController(
            named: "SparkleDismissUpdate",
            stateStore: stateStore
        )

        controller.updater(
            fakeUpdater(),
            userDidMake: .dismiss,
            forUpdate: try makeAppcastItem(),
            state: fakeUserUpdateState()
        )

        XCTAssertTrue(stateStore.current.isUpdateAvailable)
    }

    private func makeConfigStore() -> AppConfigStore {
        AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "Zentty.SparkleAppUpdateControllerTests")
        )
    }

    private func makeConfiguredSparkleController(
        named name: String,
        stateStore: AppUpdateStateStore = AppUpdateStateStore()
    ) throws -> SparkleAppUpdateController {
        try XCTUnwrap(
            makeDefaultAppUpdateController(
                configStore: makeConfigStore(),
                stateStore: stateStore,
                bundle: makeTemporarySparkleBundle(named: name)
            ) as? SparkleAppUpdateController
        )
    }

    private func makeAppcastItem() throws -> SUAppcastItem {
        let appcastItem = SUAppcastItem(
            dictionary: [
                "title": "Zentty 1.2.0",
                "sparkle:version": "120",
                "sparkle:shortVersionString": "1.2.0",
                "link": "https://releases.zentty.org/release-notes/1.2.0.html",
            ]
        )
        return try XCTUnwrap(appcastItem)
    }

    private func fakeUpdater() -> SPUUpdater {
        // These delegate tests only verify local state transitions; the updater instance is unused.
        unsafeBitCast(NSObject(), to: SPUUpdater.self)
    }

    private func fakeUserUpdateState() -> SPUUserUpdateState {
        // Sparkle does not expose a public initializer, and the delegate implementation does not read it.
        unsafeBitCast(NSObject(), to: SPUUserUpdateState.self)
    }

    private func makeTemporarySparkleBundle(named name: String) throws -> Bundle {
        try makeTemporaryBundle(named: name, includeSparkleConfiguration: true)
    }

    private func makeTemporaryBundle(
        named name: String,
        includeSparkleConfiguration: Bool
    ) throws -> Bundle {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("\(name).app", isDirectory: true)
        let contentsURL = rootURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)
        let sparkleConfiguration = includeSparkleConfiguration
            ? """
            <key>SUFeedURL</key>
            <string>https://releases.zentty.org/appcast.xml</string>
            <key>SUPublicEDKey</key>
            <string>test-public-key</string>
            """
            : ""
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>be.zenjoy.zentty.tests.\(name)</string>
            <key>CFBundleExecutable</key>
            <string>\(name)</string>
            <key>CFBundleName</key>
            <string>\(name)</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            \(sparkleConfiguration)
        </dict>
        </plist>
        """
        try infoPlist.write(to: infoPlistURL, atomically: true, encoding: .utf8)

        let executableURL = macOSURL.appendingPathComponent(name, isDirectory: false)
        FileManager.default.createFile(atPath: executableURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        return try XCTUnwrap(Bundle(url: rootURL))
    }
}
