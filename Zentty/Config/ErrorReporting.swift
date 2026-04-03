import AppKit
import Foundation

typealias ErrorReportingBundleConfigurationProvider = @Sendable () -> ErrorReportingBundleConfiguration?
typealias ErrorReportingConfirmationPresenter = @MainActor (NSWindow, Bool, @escaping (ErrorReportingChangeDecision) -> Void) -> Void
typealias ErrorReportingRestartHandler = @MainActor () -> Void

enum ErrorReportingChangeDecision: Equatable, Sendable {
    case restartNow
    case restartLater
    case cancel
}

struct ErrorReportingBundleConfiguration: Equatable, Sendable {
    static let dsnKey = "GlitchTipDSN"

    let dsn: String
    let releaseName: String?
    let dist: String?

    init(dsn: String, releaseName: String?, dist: String?) {
        self.dsn = dsn
        self.releaseName = releaseName
        self.dist = dist
    }

    init?(infoDictionary: [String: Any]) {
        guard let rawDSN = infoDictionary[Self.dsnKey] as? String else {
            return nil
        }

        let dsn = rawDSN.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dsn.isEmpty else {
            return nil
        }

        self.dsn = dsn

        if let version = infoDictionary["CFBundleShortVersionString"] as? String,
           !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            releaseName = "Zentty@\(version)"
        } else {
            releaseName = nil
        }

        if let bundleVersion = infoDictionary["CFBundleVersion"] as? String,
           !bundleVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dist = bundleVersion
        } else {
            dist = nil
        }
    }

    static func load(from bundle: Bundle) -> ErrorReportingBundleConfiguration? {
        ErrorReportingBundleConfiguration(infoDictionary: bundle.infoDictionary ?? [:])
    }
}

struct ErrorReportingClientConfiguration: Equatable, Sendable {
    let dsn: String
    let releaseName: String?
    let dist: String?
    let tracesSampleRate: Double
    let sendDefaultPii: Bool
    let enableAutoSessionTracking: Bool
    let enableAutoPerformanceTracing: Bool
    let enableNetworkBreadcrumbs: Bool
    let enableWatchdogTerminationTracking: Bool
    let maxBreadcrumbs: UInt
}

protocol ErrorReportingClient {
    func start(configuration: ErrorReportingClientConfiguration)
}

enum ErrorReportingRuntimeState {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var currentProcessEnabled = false

    static var isEnabledForCurrentProcess: Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentProcessEnabled
    }

    static func setEnabledForCurrentProcess(_ enabled: Bool) {
        lock.lock()
        currentProcessEnabled = enabled
        lock.unlock()
    }
}

enum ErrorReportingBootstrap {
    @discardableResult
    static func startIfNeeded(
        appConfig: AppConfig,
        bundleConfiguration: ErrorReportingBundleConfiguration?,
        client: ErrorReportingClient
    ) -> Bool {
        guard appConfig.errorReporting.enabled, let bundleConfiguration else {
            ErrorReportingRuntimeState.setEnabledForCurrentProcess(false)
            return false
        }

        client.start(
            configuration: ErrorReportingClientConfiguration(
                dsn: bundleConfiguration.dsn,
                releaseName: bundleConfiguration.releaseName,
                dist: bundleConfiguration.dist,
                tracesSampleRate: 0,
                sendDefaultPii: false,
                enableAutoSessionTracking: false,
                enableAutoPerformanceTracing: false,
                enableNetworkBreadcrumbs: false,
                enableWatchdogTerminationTracking: false,
                maxBreadcrumbs: 0
            )
        )
        ErrorReportingRuntimeState.setEnabledForCurrentProcess(true)
        return true
    }
}

enum ErrorReportingRestartConfirmation {
    @MainActor
    static func present(
        window: NSWindow,
        newValue: Bool,
        completion: @escaping (ErrorReportingChangeDecision) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = newValue ? "Enable Error Reporting?" : "Disable Error Reporting?"
        alert.informativeText = "This change takes effect after restarting Zentty."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Restart Later")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                completion(.restartNow)
            case .alertSecondButtonReturn:
                completion(.restartLater)
            default:
                completion(.cancel)
            }
        }
    }
}

enum ErrorReportingApplicationRestart {
    @MainActor
    static func restart() {
        let applicationURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
            guard error == nil else {
                return
            }
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }
}
