import AppKit
import Foundation

let isHostedTestMode = CommandLine.arguments.contains("-ApplePersistenceIgnoreState")

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
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate(shouldOpenMainWindow: !isHostedTestMode)
app.delegate = delegate
 
app.run()
