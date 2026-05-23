import XCTest
@_spi(Private) import Sentry
@testable import Zentty

final class ErrorReportingBootstrapTests: XCTestCase {
    override func tearDown() {
        ErrorReportingRuntimeState.setEnabledForCurrentProcess(false)
        SentrySDK.close()
        super.tearDown()
    }

    func test_start_if_needed_starts_client_when_enabled_and_bundle_configuration_exists() {
        let client = SpyErrorReportingClient()

        let didStart = ErrorReportingBootstrap.startIfNeeded(
            appConfig: AppConfig.default,
            bundleConfiguration: ErrorReportingBundleConfiguration(
                dsn: "https://public@example.com/1",
                releaseName: "Zentty@1.0",
                dist: "167"
            ),
            client: client
        )

        XCTAssertTrue(didStart)
        let configuration = try? XCTUnwrap(client.startConfiguration)
        XCTAssertEqual(configuration?.dsn, "https://public@example.com/1")
        XCTAssertEqual(configuration?.releaseName, "Zentty@1.0")
        XCTAssertEqual(configuration?.dist, "167")
        XCTAssertEqual(configuration?.tracesSampleRate, 0)
        XCTAssertFalse(configuration?.enableAutoSessionTracking ?? true)
        XCTAssertFalse(configuration?.enableAutoPerformanceTracing ?? true)
        XCTAssertFalse(configuration?.enableNetworkBreadcrumbs ?? true)
        XCTAssertFalse(configuration?.enableWatchdogTerminationTracking ?? true)
        XCTAssertTrue(configuration?.enableUncaughtNSExceptionReporting ?? false)
        XCTAssertEqual(configuration?.maxBreadcrumbs, 0)
        XCTAssertFalse(configuration?.sendDefaultPii ?? true)
    }

    func test_start_if_needed_skips_client_when_user_opted_out() {
        let client = SpyErrorReportingClient()
        var config = AppConfig.default
        config.errorReporting.enabled = false

        let didStart = ErrorReportingBootstrap.startIfNeeded(
            appConfig: config,
            bundleConfiguration: ErrorReportingBundleConfiguration(
                dsn: "https://public@example.com/1",
                releaseName: "Zentty@1.0",
                dist: "167"
            ),
            client: client
        )

        XCTAssertFalse(didStart)
        XCTAssertNil(client.startConfiguration)
    }

    func test_bundle_configuration_requires_non_empty_dsn() {
        XCTAssertNil(ErrorReportingBundleConfiguration(infoDictionary: [:]))
        XCTAssertNil(ErrorReportingBundleConfiguration(infoDictionary: [
            ErrorReportingBundleConfiguration.dsnKey: "   ",
        ]))

        let configuration = ErrorReportingBundleConfiguration(infoDictionary: [
            ErrorReportingBundleConfiguration.dsnKey: "https://public@example.com/1",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "456",
        ])

        XCTAssertEqual(configuration?.dsn, "https://public@example.com/1")
        XCTAssertEqual(configuration?.releaseName, "Zentty@1.2.3")
        XCTAssertEqual(configuration?.dist, "456")
    }

    @MainActor
    func test_restart_requests_new_application_instance_and_terminates_after_successful_launch() async {
        let applicationURL = URL(fileURLWithPath: "/Applications/Zentty.app")
        var openedURL: URL?
        var capturedConfiguration: NSWorkspace.OpenConfiguration?
        var capturedCompletion: ((NSRunningApplication?, Error?) -> Void)?
        var terminateCount = 0
        let terminated = expectation(description: "terminated")

        ErrorReportingApplicationRestart.restart(
            applicationURL: applicationURL,
            opener: { url, configuration, completion in
                openedURL = url
                capturedConfiguration = configuration
                capturedCompletion = completion
            },
            terminate: {
                terminateCount += 1
                terminated.fulfill()
            },
            logLaunchFailure: { error in
                XCTFail("Unexpected launch failure: \(error)")
            }
        )

        XCTAssertEqual(openedURL, applicationURL)
        XCTAssertTrue(capturedConfiguration?.activates ?? false)
        XCTAssertTrue(capturedConfiguration?.createsNewApplicationInstance ?? false)
        XCTAssertEqual(terminateCount, 0)

        capturedCompletion?(NSRunningApplication.current, nil)

        await fulfillment(of: [terminated], timeout: 1)
        XCTAssertEqual(terminateCount, 1)
    }

    @MainActor
    func test_restart_logs_launch_failure_and_does_not_terminate() async throws {
        let applicationURL = URL(fileURLWithPath: "/Applications/Zentty.app")
        let failure = NSError(
            domain: "ZenttyTests.ErrorReportingRestart",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Launch denied"]
        )
        let loggedError = LockedValue<NSError?>(nil)
        let logged = expectation(description: "launch failure logged")
        let terminated = expectation(description: "should not terminate")
        terminated.isInverted = true

        ErrorReportingApplicationRestart.restart(
            applicationURL: applicationURL,
            opener: { _, _, completion in
                completion(nil, failure)
            },
            terminate: {
                terminated.fulfill()
            },
            logLaunchFailure: { error in
                loggedError.set(error as NSError)
                logged.fulfill()
            }
        )

        await fulfillment(of: [logged, terminated], timeout: 0.1)
        XCTAssertEqual(loggedError.get()?.domain, failure.domain)
        XCTAssertEqual(loggedError.get()?.code, failure.code)
    }

    @MainActor
    func test_sentry_client_start_does_not_install_custom_event_or_breadcrumb_scrubbers() throws {
        let client = SentryErrorReportingClient()

        client.start(
            configuration: ErrorReportingClientConfiguration(
                dsn: "https://public@example.com/1",
                releaseName: "Zentty@1.0",
                dist: "167",
                tracesSampleRate: 0,
                sendDefaultPii: false,
                enableAutoSessionTracking: false,
                enableAutoPerformanceTracing: false,
                enableNetworkBreadcrumbs: false,
                enableWatchdogTerminationTracking: false,
                enableUncaughtNSExceptionReporting: true,
                maxBreadcrumbs: 0
            )
        )

        let options = try XCTUnwrap(SentrySDK.startOption)
        XCTAssertNil(options.beforeSend)
        XCTAssertNil(options.beforeBreadcrumb)
        XCTAssertTrue(options.enableUncaughtNSExceptionReporting)
    }
}

private final class SpyErrorReportingClient: ErrorReportingClient {
    private(set) var startConfiguration: ErrorReportingClientConfiguration?

    func start(configuration: ErrorReportingClientConfiguration) {
        startConfiguration = configuration
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
