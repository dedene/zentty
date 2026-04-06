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
                maxBreadcrumbs: 0
            )
        )

        let options = try XCTUnwrap(SentrySDK.startOption)
        XCTAssertNil(options.beforeSend)
        XCTAssertNil(options.beforeBreadcrumb)
    }
}

private final class SpyErrorReportingClient: ErrorReportingClient {
    private(set) var startConfiguration: ErrorReportingClientConfiguration?

    func start(configuration: ErrorReportingClientConfiguration) {
        startConfiguration = configuration
    }
}
