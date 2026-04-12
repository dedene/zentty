import Foundation
import Sentry

final class SentryErrorReportingClient: ErrorReportingClient {
    func start(configuration: ErrorReportingClientConfiguration) {
        SentrySDK.start { options in
            options.dsn = configuration.dsn
            options.releaseName = configuration.releaseName
            options.dist = configuration.dist
            options.tracesSampleRate = NSNumber(value: configuration.tracesSampleRate)
            options.sendDefaultPii = configuration.sendDefaultPii
            options.enableAutoSessionTracking = configuration.enableAutoSessionTracking
            options.enableAutoPerformanceTracing = configuration.enableAutoPerformanceTracing
            options.enableNetworkBreadcrumbs = configuration.enableNetworkBreadcrumbs
            options.enableWatchdogTerminationTracking = configuration.enableWatchdogTerminationTracking
            options.enableUncaughtNSExceptionReporting = configuration.enableUncaughtNSExceptionReporting
            options.maxBreadcrumbs = configuration.maxBreadcrumbs
        }
    }
}
