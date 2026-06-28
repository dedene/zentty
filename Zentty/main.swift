import AppKit
import Foundation

@main
struct ZenttyApp {
    @MainActor
    static func main() {
        let isHostedTestMode = CommandLine.arguments.contains("-ApplePersistenceIgnoreState")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let configStore = AppConfigStore()

        if !isHostedTestMode {
            _ = ErrorReportingBootstrap.startIfNeeded(
                appConfig: configStore.current,
                bundleConfiguration: ErrorReportingBundleConfiguration.load(from: .main),
                client: SentryErrorReportingClient()
            )

            _ = AgentIPCServer.shared.startIfNeeded()
        }

        let app = NSApplication.shared
        app.setActivationPolicy(isHostedTestMode ? .prohibited : .regular)

        let delegate = AppDelegate(
            shouldOpenMainWindow: !isHostedTestMode,
            configStore: configStore
        )
        app.delegate = delegate
         
        app.run()
    }
}

