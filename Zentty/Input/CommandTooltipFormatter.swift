enum CommandTooltipFormatter {
    static func title(
        _ title: String,
        commandID: AppCommandID,
        shortcutManager: ShortcutManager
    ) -> String {
        guard let shortcut = shortcutManager.shortcut(for: commandID) else {
            return title
        }

        return "\(title) (\(shortcut.displayString))"
    }
}
