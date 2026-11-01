import SwiftUI

/// A centered (or compact, left-aligned) message with optional detail.
struct AgentHistoryMessageView: View {
    let title: String
    var detail: String?
    let theme: AgentHistoryTheme
    var isCompact = false

    var body: some View {
        VStack(alignment: isCompact ? .leading : .center, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: isCompact ? .regular : .medium))
                .foregroundStyle(isCompact ? theme.secondaryText : theme.primaryText)
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .multilineTextAlignment(isCompact ? .leading : .center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: isCompact ? .leading : .center)
        .padding(isCompact ? 0 : 28)
        .accessibilityElement(children: .combine)
    }
}

/// "No conversations from … found on this Mac." with the folders that were checked.
struct AgentHistoryNoAgentsView: View {
    let checkedPaths: [String]
    let theme: AgentHistoryTheme

    static var title: String {
        let names = AgentHistoryAgent.allCases.map(\.displayName)
        let list = names.count > 1
            ? names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "")
            : names.joined()
        return "No conversations from \(list) found on this Mac."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.primaryText)
            if !checkedPaths.isEmpty {
                Text("Checked:")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(checkedPaths, id: \.self) { path in
                        Text(AgentHistoryPreview.abbreviated(path))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}

/// The typed query found nothing (yet).
struct AgentHistoryNoResultsView: View {
    let empty: AgentHistoryEmptyResults
    let theme: AgentHistoryTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(empty.title)
                .font(.system(size: 13))
                .foregroundStyle(empty == .searching ? theme.secondaryText : theme.primaryText)
            if let scopeHint = empty.scopeHint {
                Text(scopeHint)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            }
            if let filterHint = empty.filterHint {
                Text(filterHint)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 20)
        .accessibilityElement(children: .combine)
    }
}

/// The index can't be read: why, and "Rebuild Index" when rebuilding helps.
struct AgentHistoryIndexUnavailableView: View {
    let reason: AgentHistoryFailureReason
    /// Indexing resumes on its own once space returns.
    let isDiskFullPause: Bool
    let theme: AgentHistoryTheme
    let onRebuild: () -> Void
    let onOpenSettings: () -> Void

    static func message(for reason: AgentHistoryFailureReason) -> String {
        switch reason {
        case .openFailed:
            "Agent History can't open its search index."
        case .newerSchema:
            "The index was created by a newer Zentty. Rebuild it to keep searching."
        case .corrupt:
            "The search index is damaged. Rebuild it to keep searching."
        case .removalsUnreadable:
            "Agent History can't read its list of removed sessions, so it stopped indexing. Delete the index in Settings to start over."
        }
    }

    static func offersRebuild(_ reason: AgentHistoryFailureReason, isDiskFullPause: Bool) -> Bool {
        reason != .removalsUnreadable && !isDiskFullPause
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Index unavailable")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.primaryText)
            Text(Self.message(for: reason))
                .font(.system(size: 12.5))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                AgentHistoryActionButton(title: "Open Settings", keys: nil, isPrimary: false, theme: theme, action: onOpenSettings)
                if Self.offersRebuild(reason, isDiskFullPause: isDiskFullPause) {
                    AgentHistoryActionButton(title: "Rebuild Index", keys: nil, isPrimary: true, theme: theme, action: onRebuild)
                }
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// Shown until the consent card (UI7) is in place: the index is turned on in Settings.
struct AgentHistoryConsentPendingView: View {
    let theme: AgentHistoryTheme
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Search your past agent sessions")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.primaryText)
            Text("Turn on Agent History in Settings to build a search index of your agent conversations.")
                .font(.system(size: 12.5))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            AgentHistoryActionButton(title: "Open Settings", keys: nil, isPrimary: true, theme: theme, action: onOpenSettings)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// One footer key hint, e.g. "⌘↩ split" (A-15).
struct AgentHistoryKeyHint: Hashable {
    let keys: String
    let label: String
}

/// Key hints on the left; index health (or the short-terms hint) and the problem link right.
struct AgentHistoryFooterView: View {
    @ObservedObject var model: AgentHistoryViewModel

    var body: some View {
        let theme = model.theme
        HStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                hints(Self.fullHints(queryIsEmpty: model.query.isEmpty), theme: theme)
                hints(Self.shortHints(queryIsEmpty: model.query.isEmpty), theme: theme)
                hints([], theme: theme)
            }
            Spacer(minLength: 8)
            health(theme: theme)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(theme.secondaryText)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    static func fullHints(queryIsEmpty: Bool) -> [AgentHistoryKeyHint] {
        [
            AgentHistoryKeyHint(keys: "↑↓", label: "select"),
            AgentHistoryKeyHint(keys: "↩", label: "resume or jump"),
            AgentHistoryKeyHint(keys: "⌘↩", label: "split"),
            AgentHistoryKeyHint(keys: "→", label: "transcript"),
            AgentHistoryKeyHint(keys: "⇥", label: "scope"),
            AgentHistoryKeyHint(keys: "esc", label: queryIsEmpty ? "close" : "clear"),
        ]
    }

    static func shortHints(queryIsEmpty: Bool) -> [AgentHistoryKeyHint] {
        [
            AgentHistoryKeyHint(keys: "↩", label: "resume"),
            AgentHistoryKeyHint(keys: "⌘↩", label: "split"),
            AgentHistoryKeyHint(keys: "esc", label: queryIsEmpty ? "close" : "clear"),
        ]
    }

    private func hints(_ hints: [AgentHistoryKeyHint], theme: AgentHistoryTheme) -> some View {
        HStack(spacing: 12) {
            ForEach(hints, id: \.self) { hint in
                HStack(spacing: 4) {
                    Text(hint.keys)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(theme.cardBackground))
                    Text(hint.label)
                }
                .fixedSize()
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func health(theme: AgentHistoryTheme) -> some View {
        let footer = model.footer
        HStack(spacing: 10) {
            if let hint = footer.hint {
                Text(hint)
            } else {
                HStack(spacing: 5) {
                    Circle()
                        .fill(footer.health.isWarning ? theme.warning : theme.live)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(footer.health.text)
                        .foregroundStyle(footer.health.isWarning ? theme.warning : theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
            if let problem = footer.problemLink {
                Button(action: model.openProblemLink) {
                    Text(problem)
                        .underline()
                        .foregroundStyle(theme.warning)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityHint("Opens Agent History settings")
            }
        }
        .layoutPriority(1)
    }
}

/// The in-panel transient message ("Copied resume command").
struct AgentHistoryTransientMessageView: View {
    let message: String
    let theme: AgentHistoryTheme

    var body: some View {
        Text(message)
            .font(.system(size: 12.5))
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.selectedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.cardBorder, lineWidth: 1)
            )
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(message)
    }
}
