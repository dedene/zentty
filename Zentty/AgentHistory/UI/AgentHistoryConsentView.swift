import SwiftUI

/// The first-run consent card (spec §4.5, D15): a standalone 640 pt card without search row or
/// footer. It reports its height so the panel fits it; taller content scrolls.
struct AgentHistoryConsentView: View {
    @ObservedObject var model: AgentHistoryViewModel
    let consent: AgentHistoryConsentModel

    private var theme: AgentHistoryTheme { model.theme }
    private var formatting: AgentHistoryFormatting { model.formatting }
    /// The card has no search field, so its controls take Tab, Shift-Tab and Space themselves.
    private var joinsKeyLoop: Bool { model.body.controlsTakeKeyboardFocus }

    var body: some View {
        ScrollView(.vertical) {
            card
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: AgentHistoryConsentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .onPreferenceChange(AgentHistoryConsentHeightKey.self) { height in
            if height > 0, model.consentFittingHeight != height {
                model.consentFittingHeight = height
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent History setup")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AgentHistoryConsentModel.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text(consent.bodyText(formatting: formatting))
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            sourceList
            if consent.showsRetentionNudge || consent.retentionError != nil || consent.didRaiseRetention {
                retentionNudge
            }
            excludedFolders
            if let saveError = consent.saveError {
                Text(saveError)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error: \(saveError)")
            }
            if consent.isIndexing {
                progress
            } else {
                Text(AgentHistoryConsentModel.footnote)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Sources

    private var sourceList: some View {
        VStack(spacing: 0) {
            ForEach(Array(consent.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(theme.separator)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
                sourceRow(row)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.cardBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents to index")
    }

    private func sourceRow(_ row: AgentHistoryConsentModel.SourceRow) -> some View {
        let count = consent.countText(for: row, formatting: formatting)
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { row.isFound && row.isEnabled },
                set: { model.setConsentSource(row.agent, enabled: $0) }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .agentHistoryKeyLoop(joins: joinsKeyLoop)
            .disabled(!row.isFound || consent.isIndexing)
            .accessibilityLabel("Index \(row.agent.displayName) sessions")
            .accessibilityValue(count)
            AgentHistoryAgentBadge(agent: row.agent, theme: theme)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.agent.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                if let rootPath = row.rootPath {
                    Text(AgentHistoryPreview.abbreviated(rootPath))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityHidden(true)
            Spacer(minLength: 8)
            Text(count)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(row.isFound ? theme.primaryText : theme.secondaryText)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .opacity(row.isFound ? 1 : 0.5)
    }

    // MARK: - Retention

    private var retentionNudge: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let raised = consent.raisedRetentionText {
                Label(raised, systemImage: "checkmark.circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.secondaryText)
            }
            if let nudge = consent.retentionNudgeText {
                HStack(alignment: .center, spacing: 12) {
                    Text(nudge)
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    AgentHistoryActionButton(
                        title: AgentHistoryConsentModel.keepOneYearTitle,
                        keys: nil,
                        isPrimary: false,
                        theme: theme,
                        isSmall: true,
                        isFocusable: joinsKeyLoop,
                        action: model.keepClaudeConversationsOneYear
                    )
                    .accessibilityHint("Changes Claude Code's settings to keep conversations for 365 days")
                }
            }
            if let error = consent.retentionError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.warning.opacity(0.25), lineWidth: 1))
    }

    // MARK: - Excluded folders

    private var excludedFolders: some View {
        AgentHistoryFlowLayout(spacing: 6) {
            Text("Never index:")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
            ForEach(consent.excludedFolders, id: \.self) { folder in
                folderChip(folder)
            }
            AgentHistoryActionButton(
                title: AgentHistoryConsentModel.addFolderTitle,
                keys: nil,
                isPrimary: false,
                theme: theme,
                isSmall: true,
                isFocusable: joinsKeyLoop,
                action: model.requestAddExcludedFolder
            )
            .disabled(consent.isIndexing)
            .accessibilityHint("Choose folders whose sessions are never indexed")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Excluded folders")
    }

    private func folderChip(_ folder: String) -> some View {
        let display = AgentHistoryPreview.abbreviated(folder)
        return HStack(spacing: 4) {
            Text(display)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            if !consent.isIndexing {
                Button {
                    model.removeExcludedFolder(folder)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .agentHistoryKeyLoop(joins: joinsKeyLoop)
                .accessibilityLabel("Remove \(display) from excluded folders")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(theme.cardBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    // MARK: - Actions and progress

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            AgentHistoryActionButton(
                title: AgentHistoryConsentModel.declineTitle,
                keys: "esc",
                isPrimary: false,
                theme: theme,
                isFocusable: joinsKeyLoop,
                action: model.declineConsent
            )
            AgentHistoryActionButton(
                title: consent.confirmTitle(formatting: formatting),
                keys: "↩",
                isPrimary: true,
                theme: theme,
                isFocusable: joinsKeyLoop,
                action: model.confirmConsent
            )
            .disabled(!consent.canConfirm)
            .opacity(consent.canConfirm ? 1 : 0.5)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let fraction = consent.overallProgress?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView(value: 0, total: 1)
                }
            }
            .progressViewStyle(.linear)
            .accessibilityLabel("Indexing progress")
            Text(AgentHistoryConsentModel.indexingNote)
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AgentHistoryConsentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Wraps its children onto as many lines as needed (the excluded-folder chips).
struct AgentHistoryFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = clampedSize(subviews[index], width: bounds.width)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// A child never gets wider than a line, so a long folder path truncates instead of overflowing.
    private func clampedSize(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard ideal.width > width, width.isFinite else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: ideal.height))
    }

    private func arrange(_ subviews: Subviews, width maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = clampedSize(subviews[index], width: maxWidth)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
