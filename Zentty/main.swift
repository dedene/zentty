import AppKit
import Foundation

let isHostedTestMode = CommandLine.arguments.contains("-ApplePersistenceIgnoreState")
let configStore = AppConfigStore()

if !isHostedTestMode {
    if let exitCode = AgentStatusHelper.runIfNeeded(
        arguments: CommandLine.arguments,
        environment: ProcessInfo.processInfo.environment
    ) {
        Foundation.exit(exitCode)
    }

    if let exitCode = ClaudeHookBridge.runIfNeeded(
        arguments: CommandLine.arguments,
        environment: ProcessInfo.processInfo.environment
    ) {
        Foundation.exit(exitCode)
    }

    _ = ErrorReportingBootstrap.startIfNeeded(
        appConfig: configStore.current,
        bundleConfiguration: ErrorReportingBundleConfiguration.load(from: .main),
        client: SentryErrorReportingClient()
    )
}

let app = NSApplication.shared
app.setActivationPolicy(isHostedTestMode ? .prohibited : .regular)

let delegate = AppDelegate(
    shouldOpenMainWindow: !isHostedTestMode,
    configStore: configStore
)
app.delegate = delegate
 
app.run()
