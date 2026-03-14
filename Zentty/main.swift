import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
    TerminalAdapterRegistry.useLibghosttyAdapters()
}

let delegate = AppDelegate()
app.delegate = delegate

app.run()
