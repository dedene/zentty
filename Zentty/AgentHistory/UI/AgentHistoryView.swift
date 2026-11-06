import SwiftUI

/// The palette's SwiftUI body: search row, filter pills, the body for the current state
/// (results with list + preview, or a state message), footer, the folder-gone sheet, and the
/// transient message.
/// Keys never reach these views: the panel's key monitor routes them to the model first.
struct AgentHistoryView: View {
    @ObservedObject var model: AgentHistoryViewModel
    @FocusState private var isQueryFocused: Bool

    private var theme: AgentHistoryTheme { model.theme }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if showsSearchChrome {
                    searchRow
                    if !model.pills.isEmpty {
                        pillsRow
                    }
                    divider
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsSearchChrome {
                    divider
                    AgentHistoryFooterView(model: model)
                }
            }
            if let sheet = model.folderSheet {
                AgentHistoryFolderGoneSheet(model: model, sheet: sheet)
                    .transition(.opacity)
            }
            if let message = model.transientMessage {
                AgentHistoryTransientMessageView(message: message, theme: theme)
                    .padding(.bottom, 46)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { isQueryFocused = true }
        .onChange(of: model.body) { _ in
            // The search row appears when the consent card hands over to results.
            if showsSearchChrome { isQueryFocused = true }
        }
        .onChange(of: model.queryFocusRequest) { _ in
            if showsSearchChrome { isQueryFocused = true }
        }
    }

    private var showsSearchChrome: Bool { model.body.showsSearchChrome }

    private var divider: some View {
        Rectangle()
            .fill(theme.separator)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    // MARK: - Search row

    private var queryBinding: Binding<String> {
        Binding(get: { model.query }, set: { model.updateQuery($0) })
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(theme.secondaryText)
                .accessibilityHidden(true)
            TextField(
                "Search agent sessions",
                text: queryBinding,
                prompt: Text("Search sessions, prompts, replies…").foregroundColor(theme.secondaryText)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .foregroundStyle(theme.primaryText)
            .focused($isQueryFocused)
            .accessibilityLabel("Search agent sessions")
            if !model.query.isEmpty {
                Button {
                    model.clearQuery()
                    isQueryFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityLabel("Clear search")
            }
            scopePicker
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 50)
    }

    private var scopePicker: some View {
        HStack(spacing: 2) {
            if let project = model.projectScope {
                scopeButton(project.displayName, isSelected: model.scope != .all)
            }
            scopeButton("All projects", isSelected: model.scope == .all)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(theme.cardBorder, lineWidth: 1)
        )
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search scope")
    }

    private func scopeButton(_ title: String, isSelected: Bool) -> some View {
        Button {
            if !isSelected {
                model.toggleScope()
            }
            isQueryFocused = true
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? theme.selectedBackground : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!model.canToggleScope)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(model.canToggleScope ? "Press ⇥ to switch scope" : "")
    }

    private var pillsRow: some View {
        HStack(spacing: 6) {
            ForEach(model.pills) { pill in
                Text(pill.label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(pill.isPending ? theme.secondaryText : theme.primaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.selectedBackground.opacity(pill.isPending ? 0.35 : 0.7)))
                    .accessibilityLabel(pill.accessibilityLabel)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch model.body {
        case .loading:
            AgentHistoryMessageView(title: "Looking for agent sessions…", theme: theme)
        case .consent:
            if let consent = model.consent {
                AgentHistoryConsentView(model: model, consent: consent)
            } else {
                AgentHistoryMessageView(title: "Looking for agent sessions…", theme: theme)
            }
        case .noAgents(let checkedPaths):
            AgentHistoryNoAgentsView(checkedPaths: checkedPaths, theme: theme)
        case .indexUnavailable(let reason):
            AgentHistoryIndexUnavailableView(
                reason: reason,
                isDiskFullPause: model.isPausedForDiskFull,
                theme: theme,
                onRebuild: model.rebuildIndex,
                onOpenSettings: model.openProblemLink
            )
        case .historyOff:
            AgentHistoryOffView(theme: theme, onOpenSettings: model.openProblemLink)
        case .results:
            if model.isShowingIndexProgress, let progress = model.footer.indexProgress {
                AgentHistoryIndexProgressView(
                    progress: progress,
                    status: model.footer.health,
                    theme: theme,
                    onClose: model.closeIndexProgress
                )
            } else {
                results
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if model.layout?.isCompact == true {
            if model.detail == .none {
                AgentHistoryResultsList(model: model)
            } else {
                AgentHistoryPreview(model: model)
            }
        } else {
            HStack(spacing: 0) {
                AgentHistoryResultsList(model: model)
                    .frame(width: model.layout?.listWidth ?? AgentHistoryPanelLayout.wideListWidth)
                Rectangle()
                    .fill(theme.separator)
                    .frame(width: 1)
                    .accessibilityHidden(true)
                AgentHistoryPreview(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

extension AgentHistoryViewModel {
    /// Disk-full pauses resume by themselves, so the unavailable view offers no rebuild then.
    var isPausedForDiskFull: Bool {
        if case .paused(.diskFull, _) = services.control.status.state {
            return true
        }
        return false
    }
}
