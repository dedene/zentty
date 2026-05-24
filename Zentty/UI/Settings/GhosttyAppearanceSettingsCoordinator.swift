import AppKit
import Foundation
import os

struct AppearanceSettingsSourceState: Equatable {
    var subtitle: String
    var showsCreateSharedConfigAction: Bool
}

enum AppearanceThemeSlot: Equatable {
    case dark
    case light
}

struct AppearanceThemePreferences: Equatable {
    var mode: AppConfig.Appearance.ThemeMode
    var darkThemeName: String?
    var lightThemeName: String?

    init(
        mode: AppConfig.Appearance.ThemeMode,
        darkThemeName: String?,
        lightThemeName: String?
    ) {
        self.mode = mode
        self.darkThemeName = darkThemeName
        self.lightThemeName = lightThemeName
    }

    init(appearance: AppConfig.Appearance) {
        self.init(
            mode: appearance.themeMode,
            darkThemeName: appearance.preferredDarkThemeName ?? appearance.localThemeName,
            lightThemeName: appearance.preferredLightThemeName
        )
    }

    func themeName(for slot: AppearanceThemeSlot) -> String {
        switch slot {
        case .dark:
            darkThemeName ?? GhosttyThemeLibrary.fallbackThemeName
        case .light:
            lightThemeName ?? GhosttyThemeLibrary.fallbackLightThemeName
        }
    }

    var activeSlot: AppearanceThemeSlot {
        mode == .alwaysLight ? .light : .dark
    }
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
    var themePreferences: AppearanceThemePreferences { get }
    var syncOpenCodeThemeWithTerminal: Bool { get }
    func applyTheme(_ name: String, presentingWindow: NSWindow?) async
    func applyTheme(_ name: String, slot: AppearanceThemeSlot, presentingWindow: NSWindow?) async
    func applyThemeMode(_ mode: AppConfig.Appearance.ThemeMode, presentingWindow: NSWindow?) async
    func resetThemePreferences(presentingWindow: NSWindow?) async
    func applyBackgroundOpacity(_ opacity: CGFloat, presentingWindow: NSWindow?) async
    func applyOpenCodeThemeSync(_ enabled: Bool) async
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
        if currentStack()?.mode == .sharedGhostty {
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

    var syncOpenCodeThemeWithTerminal: Bool {
        configStore.current.appearance.syncOpenCodeThemeWithTerminal
    }

    var themePreferences: AppearanceThemePreferences {
        resolvedThemePreferences()
    }

    func applyTheme(_ name: String, presentingWindow: NSWindow?) async {
        await applyTheme(name, slot: themePreferences.activeSlot, presentingWindow: presentingWindow)
    }

    func applyTheme(_ name: String, slot: AppearanceThemeSlot, presentingWindow: NSWindow?) async {
        let sanitized = GhosttyConfigWriter.sanitizedThemeName(name)
        let persistedThemeName = GhosttyThemeLibrary.persistedThemeName(for: sanitized)
        guard !persistedThemeName.isEmpty else {
            return
        }

        var preferences = themePreferences
        switch slot {
        case .dark:
            preferences.darkThemeName = persistedThemeName
        case .light:
            preferences.lightThemeName = persistedThemeName
        }

        await applyThemePreferences(preferences, presentingWindow: presentingWindow)
    }

    func applyThemeMode(_ mode: AppConfig.Appearance.ThemeMode, presentingWindow: NSWindow?) async {
        var preferences = themePreferences
        preferences.mode = mode
        await applyThemePreferences(preferences, presentingWindow: presentingWindow)
    }

    func resetThemePreferences(presentingWindow: NSWindow?) async {
        await applyThemePreferences(
            AppearanceThemePreferences(
                mode: .alwaysDark,
                darkThemeName: GhosttyThemeLibrary.fallbackPersistedThemeName,
                lightThemeName: GhosttyThemeLibrary.fallbackLightThemeName
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

    func applyOpenCodeThemeSync(_ enabled: Bool) async {
        do {
            try configStore.update { config in
                config.appearance.syncOpenCodeThemeWithTerminal = enabled
            }
        } catch {
            logger.error("Failed to persist OpenCode theme sync setting: \(error.localizedDescription)")
        }
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

        if stack.mode == .sharedGhostty {
            createSharedConfig(from: stack, pendingMutation: mutation)
            return
        }

        persistLocalOnlyMutation(mutation)
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

    private func applyThemePreferences(
        _ preferences: AppearanceThemePreferences,
        presentingWindow _: NSWindow?
    ) async {
        let spec = GhosttyThemeSpec(
            mode: preferences.mode,
            darkThemeName: preferences.darkThemeName,
            lightThemeName: preferences.lightThemeName
        )

        guard let stack = currentStack() else {
            return
        }

        do {
            try configStore.update { config in
                apply(preferences: preferences, to: &config.appearance)
            }
        } catch {
            logger.error("Failed to persist theme preferences: \(error.localizedDescription)")
        }

        if let writeTargetURL = stack.writeTargetURL {
            writeSharedValue(spec.rawValue, forKey: "theme", to: writeTargetURL)
            runtimeReload()
            return
        }

        if stack.mode == .sharedGhostty {
            createSharedConfig(
                from: stack,
                pendingMutation: PendingMutation(
                    key: "theme",
                    value: spec.rawValue,
                    applyLocally: { _ in }
                )
            )
            return
        }

        runtimeReload()
    }

    private func apply(preferences: AppearanceThemePreferences, to appearance: inout AppConfig.Appearance) {
        appearance.themeMode = preferences.mode
        appearance.preferredDarkThemeName = preferences.darkThemeName
        appearance.preferredLightThemeName = preferences.lightThemeName
        appearance.localThemeName = preferences.mode == .alwaysDark ? preferences.darkThemeName : nil
    }

    private func resolvedThemePreferences() -> AppearanceThemePreferences {
        var preferences = AppearanceThemePreferences(appearance: configStore.current.appearance)
        guard let stack = currentStack(),
              stack.mode == .sharedGhostty,
              let sharedThemeSpec = resolvedSharedThemeSpec(from: stack) else {
            return preferences
        }

        if sharedThemeSpec.hasQualifiedSlot {
            preferences.mode = sharedThemeSpec.spec.mode
            preferences.darkThemeName = sharedThemeSpec.spec.darkThemeName ?? preferences.darkThemeName
            preferences.lightThemeName = sharedThemeSpec.spec.lightThemeName ?? preferences.lightThemeName
            return preferences
        }

        if preferences.mode == .alwaysLight {
            preferences.lightThemeName = sharedThemeSpec.spec.darkThemeName
                ?? sharedThemeSpec.spec.lightThemeName
                ?? preferences.lightThemeName
            return preferences
        }

        preferences.mode = sharedThemeSpec.spec.mode
        preferences.darkThemeName = sharedThemeSpec.spec.darkThemeName ?? preferences.darkThemeName
        preferences.lightThemeName = sharedThemeSpec.spec.lightThemeName ?? preferences.lightThemeName
        return preferences
    }

    private struct SharedThemeSpec {
        var spec: GhosttyThemeSpec
        var hasQualifiedSlot: Bool
    }

    private func resolvedSharedThemeSpec(from stack: GhosttyConfigEnvironment.ResolvedStack) -> SharedThemeSpec? {
        var visitedPaths: Set<String> = []
        var resolvedRawThemeSpec: String?

        for loadFile in stack.loadFiles {
            resolvedRawThemeSpec = rawThemeSpec(at: loadFile, visitedPaths: &visitedPaths) ?? resolvedRawThemeSpec
        }

        guard let resolvedRawThemeSpec,
              let spec = GhosttyThemeSpec(rawValue: resolvedRawThemeSpec) else {
            return nil
        }

        return SharedThemeSpec(
            spec: spec,
            hasQualifiedSlot: rawThemeSpecHasQualifiedSlot(resolvedRawThemeSpec)
        )
    }

    private func rawThemeSpecHasQualifiedSlot(_ rawValue: String) -> Bool {
        rawValue
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .split(separator: ",")
            .contains { slot in
                let trimmedSlot = slot.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmedSlot.hasPrefix("dark:") || trimmedSlot.hasPrefix("light:")
            }
    }

    private func rawThemeSpec(at url: URL, visitedPaths: inout Set<String>) -> String? {
        let normalizedPath = url.standardizedFileURL.path
        guard visitedPaths.insert(normalizedPath).inserted else {
            return nil
        }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        var resolvedRawThemeSpec: String?
        for rawLine in contents.split(whereSeparator: \.isNewline) {
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

            if key == "config-file",
               let includedURL = resolveIncludedConfigURL(rawValue: value, relativeTo: url) {
                resolvedRawThemeSpec = rawThemeSpec(at: includedURL, visitedPaths: &visitedPaths) ?? resolvedRawThemeSpec
                continue
            }

            guard key == "theme" else {
                continue
            }

            resolvedRawThemeSpec = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }

        return resolvedRawThemeSpec
    }

    private func resolveIncludedConfigURL(rawValue: String, relativeTo sourceURL: URL) -> URL? {
        let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !value.isEmpty else {
            return nil
        }

        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value)
        }
        if value.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
        }

        return sourceURL.deletingLastPathComponent().appendingPathComponent(value)
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
