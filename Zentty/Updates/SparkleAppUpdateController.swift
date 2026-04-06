import AppKit
import Foundation
import Sparkle

@MainActor
final class SparkleAppUpdateController: NSObject, AppUpdateControlling {
    private let configStore: AppConfigStore
    let updateStateStore: AppUpdateStateStore
    private let bundle: Bundle
    private var updaterController: SPUStandardUpdaterController!
    private var configObserverID: UUID?
    private var currentChannel: AppUpdateChannel

    static func makeIfConfigured(
        configStore: AppConfigStore,
        stateStore: AppUpdateStateStore,
        bundle: Bundle = .main
    ) -> AppUpdateControlling? {
        guard bundle.sparkleFeedURLString != nil, bundle.sparklePublicEDKey != nil else {
            return nil
        }

        return SparkleAppUpdateController(
            configStore: configStore,
            stateStore: stateStore,
            bundle: bundle
        )
    }

    private init(
        configStore: AppConfigStore,
        stateStore: AppUpdateStateStore,
        bundle: Bundle
    ) {
        self.configStore = configStore
        self.updateStateStore = stateStore
        self.bundle = bundle
        self.currentChannel = configStore.current.updates.channel
        super.init()

        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        configObserverID = configStore.addObserver { [weak self] config in
            Task { @MainActor [weak self] in
                self?.handleConfigChange(config)
            }
        }
    }

    deinit {
        if let configObserverID {
            configStore.removeObserver(configObserverID)
        }
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    func start() {
        updateStateStore.setUpdateAvailable(false)
        updaterController.startUpdater()
        _ = updaterController.updater.clearFeedURLFromUserDefaults()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else {
            return
        }

        updaterController.checkForUpdates(nil)
    }

    private func handleConfigChange(_ config: AppConfig) {
        guard config.updates.channel != currentChannel else {
            return
        }

        currentChannel = config.updates.channel
        updateStateStore.setUpdateAvailable(false)
        updaterController.updater.resetUpdateCycleAfterShortDelay()
    }
}

extension SparkleAppUpdateController: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        currentChannel.sparkleAllowedChannels
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        bundle.sparkleFeedURLString
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        _ = item
        updateStateStore.setUpdateAvailable(true)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        updateStateStore.setUpdateAvailable(false)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        _ = error
        updateStateStore.setUpdateAvailable(false)
    }

    @objc(updater:userDidMakeChoice:forUpdate:state:)
    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        _ = updater
        _ = updateItem
        _ = state

        if choice == .skip || choice == .install {
            updateStateStore.setUpdateAvailable(false)
        }
    }
}

private extension AppUpdateChannel {
    var sparkleAllowedChannels: Set<String> {
        switch self {
        case .stable:
            []
        case .beta:
            ["beta"]
        }
    }
}

private extension Bundle {
    var sparkleFeedURLString: String? {
        nonEmptyInfoDictionaryValue(forKey: "SUFeedURL")
    }

    var sparklePublicEDKey: String? {
        nonEmptyInfoDictionaryValue(forKey: "SUPublicEDKey")
    }

    func nonEmptyInfoDictionaryValue(forKey key: String) -> String? {
        guard let value = object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
