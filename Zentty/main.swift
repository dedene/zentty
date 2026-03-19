import AppKit
import Foundation

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

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
