import AppKit
import Foundation

let isHostedTestMode = CommandLine.arguments.contains("-ApplePersistenceIgnoreState")
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
