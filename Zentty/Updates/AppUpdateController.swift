import AppKit

@MainActor
protocol AppUpdateControlling: AnyObject {
    var canCheckForUpdates: Bool { get }
    var updateStateStore: AppUpdateStateStore { get }

    func start()
    func checkForUpdates()
}

@MainActor
func makeDefaultAppUpdateController(
    configStore: AppConfigStore,
    stateStore: AppUpdateStateStore = MainActorShim.assumeIsolated { AppUpdateStateStore() },
    bundle: Bundle = .main
) -> AppUpdateControlling {
    SparkleAppUpdateController.makeIfConfigured(
        configStore: configStore,
        stateStore: stateStore,
        bundle: bundle
    )
        ?? NoOpAppUpdateController(stateStore: stateStore)
}

@MainActor
final class NoOpAppUpdateController: AppUpdateControlling {
    let updateStateStore: AppUpdateStateStore

    init(stateStore: AppUpdateStateStore = MainActorShim.assumeIsolated { AppUpdateStateStore() }) {
        self.updateStateStore = stateStore
    }

    var canCheckForUpdates: Bool {
        false
    }

    func start() {}

    func checkForUpdates() {}
}
