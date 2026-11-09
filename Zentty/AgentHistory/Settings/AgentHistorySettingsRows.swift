import AppKit

/// Layout pieces for Settings › Agent History: card assembly, section headers and the rows
/// whose text follows the history status. The section view controller owns the state.
@MainActor
enum AgentHistorySettingsRows {
    static let amber = NSColor.systemOrange

    static func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let label = SettingsFormBuilder.label(text, font: .systemFont(ofSize: size, weight: weight))
        label.textColor = color
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func secondaryLabel(_ text: String) -> NSTextField {
        label(text, color: .secondaryLabelColor)
    }

    /// A card whose rows are separated like the Agents section's cards. `trailing` follows the
    /// last row without a separator (it brings its own when it has content).
    static func card(rows: [NSView], trailing: NSView? = nil) -> SettingsCardView {
        let card = SettingsCardView()
        let stack = verticalStack(spacing: 0)
        card.addSubview(stack)
        for (index, row) in rows.enumerated() {
            if index > 0 {
                SettingsFormBuilder.separator(addedTo: stack)
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if let trailing {
            stack.addArrangedSubview(trailing)
            trailing.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        pin(stack, to: card, inset: 0)
        return card
    }

    /// The section's cards and headers, top to bottom, pinned to the scroll content.
    static func stack(_ sections: [NSView], in contentView: NSView) {
        let stack = verticalStack(spacing: 16)
        contentView.addSubview(stack)
        for section in sections {
            stack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    /// Title and explanation above a card.
    static func sectionHeader(title: String, subtitle: String?) -> NSView {
        let stack = verticalStack(spacing: 4)
        stack.addArrangedSubview(label(title, size: 13, weight: .semibold))
        if let subtitle {
            let subtitleLabel = secondaryLabel(subtitle)
            stack.addArrangedSubview(subtitleLabel)
            subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// Padded content for a card row that isn't a switch row.
    static func paddedRow(_ content: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        pin(content, to: container, inset: 14, horizontal: 16)
        return container
    }

    /// Text on the left, a button on the right (Maintenance, Restore All).
    static func actionRow(text: NSView, button: NSButton) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(text)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(button)
        return row
    }

    static func button(_ title: String, target: AnyObject, action: Selector, small: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        if small {
            button.controlSize = .small
        }
        return button
    }

    static func verticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// Removes every arranged subview of `stack`.
    static func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    static func pin(_ view: NSView, to container: NSView, inset: CGFloat, horizontal: CGFloat? = nil) {
        view.translatesAutoresizingMaskIntoConstraints = false
        let side = horizontal ?? inset
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: side),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -side),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
        ])
    }

    // MARK: - Copy

    static func removedSessionsText(_ count: Int, formatting: AgentHistoryFormatting) -> String {
        switch count {
        case 0: return "No sessions removed from Agent History."
        case 1: return "1 session removed from Agent History"
        default: return "\(formatting.number(count)) sessions removed from Agent History"
        }
    }

    /// Maintenance note while `removals.json` can't be read: rebuilding fails closed.
    static let rebuildBlockedText = "Rebuild is off: Agent History can't read its list of removed sessions, and rebuilding without it could bring them back. Delete the index to start over."
    /// Maintenance note while standing by: the index belongs to the instance writing it.
    static let rebuildOwnedElsewhereText = "Rebuild is off: another Zentty instance owns the index. Rebuild there, or quit it and rebuild here."

    static func retentionText(days: Int) -> String {
        let period = days == 1 ? "1 day" : "\(days) days"
        return "Claude Code deletes conversations after \(period), so they'll drop out of Agent History too."
    }
}

/// One agent in the Sources card: name, root folders, counts, the latest error and, when the
/// agent wasn't found, the folders that were checked. Text follows `update(_:)`.
@MainActor
final class AgentHistorySettingsSourceRowView: NSView {
    let agent: AgentHistoryAgent
    let toggle = NSSwitch()
    private let rootsLabel = AgentHistorySettingsRows.secondaryLabel("")
    private let summaryLabel = AgentHistorySettingsRows.secondaryLabel("")
    private let errorLabel = AgentHistorySettingsRows.label("", color: AgentHistorySettingsRows.amber)
    private let checkedLabel = AgentHistorySettingsRows.label("", size: 11, color: .tertiaryLabelColor)

    init(agent: AgentHistoryAgent, target: AnyObject, action: Selector) {
        self.agent = agent
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = AgentHistorySettingsRows.verticalStack(spacing: 2)
        stack.addArrangedSubview(AgentHistorySettingsRows.label(agent.displayName, size: 13, weight: .semibold))
        for label in [rootsLabel, summaryLabel, errorLabel, checkedLabel] {
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        addSubview(stack)
        toggle.target = target
        toggle.action = action
        toggle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggle)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ row: AgentHistorySettingsSourceRow, canToggle: Bool) {
        toggle.state = row.isEnabled && row.isDetected ? .on : .off
        toggle.isEnabled = canToggle && row.isDetected
        set(rootsLabel, row.rootsText)
        set(summaryLabel, row.summaryText)
        set(errorLabel, row.errorText)
        set(checkedLabel, row.checkedPathsText.map { "Checked:\n\($0)" })
    }

    var textsForTesting: [String] {
        [rootsLabel, summaryLabel, errorLabel, checkedLabel].filter { !$0.isHidden }.map(\.stringValue)
    }

    private func set(_ label: NSTextField, _ text: String?) {
        label.stringValue = text ?? ""
        label.isHidden = text?.isEmpty ?? true
    }
}

/// One Claude Code config folder in the Sources card: its retention, and "Keep 1 Year" when
/// Zentty may raise it.
@MainActor
struct AgentHistorySettingsRetentionRow: Equatable {
    let directory: String
    let text: String
    let note: String?
    let offersKeepOneYear: Bool

    /// nil when the retention needs no mention (a year or more, `0`, or unreadable).
    static func make(status: ClaudeRetentionStatus, didRaise: Bool, showsPath: String?) -> AgentHistorySettingsRetentionRow? {
        let directory = status.configDirectory.path
        if didRaise, status.effectiveDays >= ClaudeRetentionSettings.recommendedDays {
            return AgentHistorySettingsRetentionRow(
                directory: directory, text: AgentHistoryConsentModel.raisedRetentionText,
                note: showsPath, offersKeepOneYear: false
            )
        }
        if status.isNudgeEligible {
            return AgentHistorySettingsRetentionRow(
                directory: directory, text: AgentHistorySettingsRows.retentionText(days: status.effectiveDays),
                note: showsPath, offersKeepOneYear: true
            )
        }
        if status.source == .managedSettings,
           (1..<ClaudeRetentionSettings.recommendedDays).contains(status.effectiveDays) {
            let note = ["Set by your organization", showsPath].compactMap { $0 }.joined(separator: " · ")
            return AgentHistorySettingsRetentionRow(
                directory: directory, text: AgentHistorySettingsRows.retentionText(days: status.effectiveDays),
                note: note, offersKeepOneYear: false
            )
        }
        return nil
    }

    /// Replaces `stack`'s rows; each brings the separator above it.
    static func fill(
        _ stack: NSStackView,
        with rows: [AgentHistorySettingsRetentionRow],
        isEnabled: Bool,
        target: AnyObject,
        action: Selector
    ) {
        AgentHistorySettingsRows.clear(stack)
        for row in rows {
            SettingsFormBuilder.separator(addedTo: stack)
            let view = row.makeView(target: target, action: action)
            view.agentHistoryDescendant(ofType: NSButton.self)?.isEnabled = isEnabled
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    func makeView(target: AnyObject, action: Selector) -> NSView {
        let text = AgentHistorySettingsRows.verticalStack(spacing: 2)
        let main = AgentHistorySettingsRows.label(self.text)
        text.addArrangedSubview(main)
        main.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        if let note {
            text.addArrangedSubview(AgentHistorySettingsRows.label(note, size: 11, color: .secondaryLabelColor))
        }
        guard offersKeepOneYear else {
            return AgentHistorySettingsRows.paddedRow(text)
        }
        let button = AgentHistorySettingsRows.button(AgentHistoryConsentModel.keepOneYearTitle, target: target, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(directory)
        return AgentHistorySettingsRows.paddedRow(AgentHistorySettingsRows.actionRow(text: text, button: button))
    }
}

extension NSView {
    /// Depth-first search of the subview tree (Settings › Agent History rows and tests).
    func agentHistoryDescendant<T: NSView>(ofType type: T.Type) -> T? {
        agentHistoryDescendants(ofType: type).first
    }

    func agentHistoryDescendants<T: NSView>(ofType type: T.Type) -> [T] {
        subviews.flatMap { subview -> [T] in
            ((subview as? T).map { [$0] } ?? []) + subview.agentHistoryDescendants(ofType: type)
        }
    }
}
