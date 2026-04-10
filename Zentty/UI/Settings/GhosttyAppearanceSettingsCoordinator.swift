import AppKit
import Foundation
import os

struct AppearanceSettingsSourceState: Equatable {
    var subtitle: String
    var showsCreateSharedConfigAction: Bool
}

enum GhosttySharedConfigDecision: Equatable {
    case createSharedConfig
    case keepOnlyInZentty
    case cancel
}

@MainActor
final class GhosttySharedConfigPromptSession {
    static let shared = GhosttySharedConfigPromptSession()

    private(set) var decision: GhosttySharedConfigDecision?
    private(set) var hasPromptedThisSession = false

    func record(_ decision: GhosttySharedConfigDecision) {
        hasPromptedThisSession = true
        self.decision = decision
    }

    func markPromptedWithoutDecision() {
        hasPromptedThisSession = true
    }

    func resetForTesting() {
        decision = nil
        hasPromptedThisSession = false
    }
}

typealias GhosttySharedConfigDecisionProvider = @MainActor (NSWindow?) async -> GhosttySharedConfigDecision

@MainActor
protocol AppearanceSettingsConfigCoordinating {
    var sourceState: AppearanceSettingsSourceState { get }
    func applyTheme(_ name: String, presentingWindow: NSWindow?) async
    func applyBackgroundOpacity(_ opacity: CGFloat, presentingWindow: NSWindow?) async
    func createSharedConfig(presentingWindow: NSWindow?) async
}

@MainActor
final class GhosttyAppearanceSettingsCoordinator: AppearanceSettingsConfigCoordinating {
    private struct PendingMutation {
        let key: String
        let value: String
        let applyLocally: (inout AppConfig) -> Void
    }

    private let logger = Logger(subsystem: "be.zenjoy.zentty", category: "GhosttyAppearanceSettings")
    private let configStore: AppConfigStore
    private let configEnvironmentProvider: () -> GhosttyConfigEnvironment
    private let runtimeReload: @MainActor () -> Void
    private let decisionProvider: GhosttySharedConfigDecisionProvider
    private let promptSession: GhosttySharedConfigPromptSession
    private let fileManager: FileManager

    init(
        configStore: AppConfigStore,
        configEnvironmentProvider: (() -> GhosttyConfigEnvironment)? = nil,
        runtimeReload: @escaping @MainActor () -> Void = { LibghosttyRuntime.shared.reloadConfig() },
        decisionProvider: @escaping GhosttySharedConfigDecisionProvider = GhosttyAppearanceSettingsCoordinator.presentSharedConfigDecision,
        promptSession: GhosttySharedConfigPromptSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.configStore = configStore
        self.configEnvironmentProvider = configEnvironmentProvider ?? {
            GhosttyConfigEnvironment(appConfigProvider: { [weak configStore] in
                configStore?.current ?? .default
            })
        }
        self.runtimeReload = runtimeReload
        self.decisionProvider = decisionProvider
        self.promptSession = promptSession
        self.fileManager = fileManager
    }

    var sourceState: AppearanceSettingsSourceState {
        if currentStack()?.writeTargetURL != nil {
            return AppearanceSettingsSourceState(
                subtitle: "Using your Ghostty config.",
                showsCreateSharedConfigAction: false
            )
        }

        return AppearanceSettingsSourceState(
            subtitle: "Using Zentty defaults. Appearance changes stay local until you create a shared Ghostty config.",
            showsCreateSharedConfigAction: true
        )
    }

    func applyTheme(_ name: String, presentingWindow: NSWindow?) async {
        let sanitized = GhosttyConfigWriter.sanitizedThemeName(name)
        guard !sanitized.isEmpty else {
            return
        }

        await applyMutation(
            PendingMutation(
                key: "theme",
                value: sanitized,
                applyLocally: { $0.appearance.localThemeName = sanitized }
            ),
            presentingWindow: presentingWindow
        )
    }

    func applyBackgroundOpacity(_ opacity: CGFloat, presentingWindow: NSWindow?) async {
        await applyMutation(
            PendingMutation(
                key: "background-opacity",
                value: GhosttyConfigWriter.formattedBackgroundOpacity(opacity),
                applyLocally: { $0.appearance.localBackgroundOpacity = opacity }
            ),
            presentingWindow: presentingWindow
        )
    }

    func createSharedConfig(presentingWindow _: NSWindow?) async {
        guard let stack = currentStack(), stack.writeTargetURL == nil else {
            return
        }

        createSharedConfig(from: stack, pendingMutation: nil)
    }

    private func applyMutation(_ mutation: PendingMutation, presentingWindow: NSWindow?) async {
        guard let stack = currentStack() else {
            return
        }

        if let writeTargetURL = stack.writeTargetURL {
            writeSharedValue(mutation.value, forKey: mutation.key, to: writeTargetURL)
            runtimeReload()
            return
        }

        let resolvedDecision: GhosttySharedConfigDecision
        if let decision = promptSession.decision {
            resolvedDecision = decision
        } else if promptSession.hasPromptedThisSession {
            resolvedDecision = .keepOnlyInZentty
        } else {
            resolvedDecision = await decisionProvider(presentingWindow)
            if resolvedDecision == .cancel {
                promptSession.markPromptedWithoutDecision()
            } else {
                promptSession.record(resolvedDecision)
            }
        }

        switch resolvedDecision {
        case .createSharedConfig:
            createSharedConfig(from: stack, pendingMutation: mutation)
        case .keepOnlyInZentty:
            persistLocalOnlyMutation(mutation)
        case .cancel:
            return
        }
    }

    private func currentStack() -> GhosttyConfigEnvironment.ResolvedStack? {
        currentEnvironment().resolvedStack()
    }

    private func currentEnvironment() -> GhosttyConfigEnvironment {
        configEnvironmentProvider()
    }

    private func persistLocalOnlyMutation(_ mutation: PendingMutation) {
        do {
            try configStore.update { config in
                mutation.applyLocally(&config)
            }
            runtimeReload()
        } catch {
            logger.error("Failed to persist local-only Ghostty appearance override: \(error.localizedDescription)")
        }
    }

    private func createSharedConfig(
        from stack: GhosttyConfigEnvironment.ResolvedStack,
        pendingMutation: PendingMutation?
    ) {
        let targetURL = stack.preferredCreateTargetURL
        var content = stack.loadFiles.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        content = applyingOverrides(from: stack.localOverrideContents, to: content)

        if let pendingMutation {
            content = GhosttyConfigWriter.updating(
                content: content.isEmpty ? nil : content,
                value: pendingMutation.value,
                forKey: pendingMutation.key
            )
        } else if !content.hasSuffix("\n"), !content.isEmpty {
            content += "\n"
        }

        do {
            try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: targetURL, options: .atomic)
            try configStore.update { config in
                config.appearance = .default
            }
            runtimeReload()
        } catch {
            logger.error("Failed to create shared Ghostty config at \(targetURL.path, privacy: .public): \(error.localizedDescription)")
        }
    }

    private func applyingOverrides(from rawContents: String?, to baseContent: String) -> String {
        guard let rawContents else {
            return baseContent
        }

        var content: String? = baseContent.isEmpty ? nil : baseContent
        for rawLine in rawContents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else {
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            content = GhosttyConfigWriter.updating(content: content, value: value, forKey: key)
        }

        return content ?? ""
    }

    private func writeSharedValue(_ value: String, forKey key: String, to targetURL: URL) {
        GhosttyConfigWriter(configURL: targetURL).updateValue(value, forKey: key)
    }

    static func presentSharedConfigDecision(window: NSWindow?) async -> GhosttySharedConfigDecision {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "Create a shared Ghostty config?"
            alert.informativeText = "This will copy Zentty’s current terminal appearance defaults into Ghostty so future theme and opacity changes are shared with Ghostty too."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Create Shared Ghostty Config")
            alert.addButton(withTitle: "Keep Only in Zentty")
            alert.addButton(withTitle: "Cancel")

            let resolveDecision: (NSApplication.ModalResponse) -> Void = { response in
                switch response {
                case .alertFirstButtonReturn:
                    continuation.resume(returning: .createSharedConfig)
                case .alertSecondButtonReturn:
                    continuation.resume(returning: .keepOnlyInZentty)
                default:
                    continuation.resume(returning: .cancel)
                }
            }

            if let window {
                alert.beginSheetModal(for: window, completionHandler: resolveDecision)
            } else {
                resolveDecision(alert.runModal())
            }
        }
    }
}
