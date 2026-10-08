import AppKit
import Foundation

let isHostedTestMode = CommandLine.arguments.contains("-ApplePersistenceIgnoreState")
    || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
if !isHostedTestMode, ZenttyBuildFlavor.current == .dev {
    // Zentty Dev keeps its own config dir; on first launch it starts from a
    // copy of the production settings instead of defaults.
    let home = FileManager.default.homeDirectoryForCurrentUser
    AppConfigStore.seedDevConfigIfNeeded(
        productionDirectoryURL: ZenttyBuildFlavor.production.configDirectoryURL(homeDirectoryURL: home),
        devDirectoryURL: ZenttyBuildFlavor.dev.configDirectoryURL(homeDirectoryURL: home)
    )
}
let configStore = AppConfigStore()

if !isHostedTestMode {
    _ = ErrorReportingBootstrap.startIfNeeded(
        appConfig: configStore.current,
        bundleConfiguration: ErrorReportingBundleConfiguration.load(from: .main),
        client: SentryErrorReportingClient()
    )

    _ = AgentIPCServer.shared.startIfNeeded()

    // Manifest agents (e.g. kilo) get PATH wrappers materialized under the
    // runtime root because the bundled bin/ tree only covers builtin tools.
    let manifestWrapperRoot = ZenttyRuntimePaths
        .currentRootURL(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        .appendingPathComponent(ZenttyBuildFlavor.current.agentWrappersDirectoryName, isDirectory: true)
    if let supportDirectory = AgentStatusHelper.wrapperSupportDirectoryPath(in: .main) {
        do {
            _ = try AgentManifestWrapperMaterializer.materialize(
                manifests: AgentManifestRegistry.shared.manifests,
                rootURL: manifestWrapperRoot,
                sharedWrapperPath: supportDirectory
                    + "/zentty-agent-wrapper"
            )
        } catch {
            agentIntegrationLogger.error(
                "Failed to materialize manifest agent wrappers: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(isHostedTestMode ? .prohibited : .regular)

let delegate = AppDelegate(
    shouldOpenMainWindow: !isHostedTestMode,
    configStore: configStore
)
app.delegate = delegate
 
app.run()
