import SwiftUI

/// The selected session: header, actions, folder-gone callout, meta list, matching (or first and
/// latest) turns, and the resume command. The header renders from the row at once; the turns
/// arrive with the preview load.
struct AgentHistoryPreview: View {
    @ObservedObject var model: AgentHistoryViewModel

    private var theme: AgentHistoryTheme { model.theme }

    var body: some View {
        if let row = model.selectedRow {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(row)
                    actions(row)
                    if model.folderGoneKeys.contains(row.key) {
                        callout("This session's folder no longer exists. Resume will ask where to continue.")
                    }
                    metaList(row)
                    if model.detail == .transcript {
                        transcriptSection(row)
                    } else {
                        turnsSection(row)
                    }
                    resumeCommandRow(row)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Preview")
        } else {
            AgentHistoryMessageView(title: "Nothing selected", theme: theme)
        }
    }

    // MARK: - Header and actions

    private func header(_ row: AgentHistoryResultRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AgentHistoryAgentBadge(agent: row.agent, theme: theme)
            VStack(alignment: .leading, spacing: 3) {
                Text(AgentHistoryTextStyler.attributed(
                    row.title,
                    theme: theme,
                    font: .system(size: 17, weight: .semibold),
                    color: theme.primaryText
                ))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                subtitle(row)
            }
        }
    }

    private func subtitle(_ row: AgentHistoryResultRow) -> some View {
        var parts = [row.agent.displayName]
        if let turns = row.summary?.turnCount {
            parts.append(turns == 1 ? "1 turn" : "\(turns) turns")
        }
        if let date = row.displayDate {
            parts.append(model.formatting.relativeTime(date, now: model.services.now()))
        }
        var text = Text(parts.joined(separator: " · ")).foregroundColor(theme.secondaryText)
        if let live = row.live {
            text = text + Text(" · ").foregroundColor(theme.secondaryText)
                + Text("Running in “\(live.paneDisplayName)”").foregroundColor(theme.live)
        }
        return text.font(.system(size: 12))
    }

    @ViewBuilder
    private func actions(_ row: AgentHistoryResultRow) -> some View {
        HStack(spacing: 8) {
            switch model.previewPrimaryAction(for: row.key) {
            case .launch:
                AgentHistoryActionButton(
                    title: row.live != nil ? "Jump to pane" : "Resume",
                    keys: "↩",
                    isPrimary: true,
                    theme: theme
                ) {
                    model.perform(.primary, on: row.key)
                }
                AgentHistoryActionButton(
                    title: row.live != nil ? "Fork into split" : "Open in split",
                    keys: "⌘↩",
                    isPrimary: false,
                    theme: theme
                ) {
                    model.perform(.secondary, on: row.key)
                }
            case .copySessionID:
                AgentHistoryActionButton(title: "Copy Session ID", keys: nil, isPrimary: true, theme: theme) {
                    model.copySessionID(for: row.key)
                }
            }
        }
    }

    private func callout(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(theme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.warning.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(theme.warning.opacity(0.45), lineWidth: 1))
    }

    // MARK: - Meta

    @ViewBuilder
    private func metaList(_ row: AgentHistoryResultRow) -> some View {
        let summary = row.summary
        VStack(alignment: .leading, spacing: 5) {
            if let folder = summary?.cwd ?? row.live?.workingDirectory {
                metaRow("Folder", value: Self.abbreviated(folder), suffix: model.folderGoneKeys.contains(row.key) ? "(removed)" : nil)
            }
            if let branch = summary?.branch {
                metaRow("Branch", value: branch)
            }
            if let modelName = summary?.model {
                metaRow("Model", value: [modelName, summary?.effort].compactMap { $0 }.joined(separator: " · "))
            }
            metaRow("Session ID", value: row.key.nativeID)
        }
    }

    private func metaRow(_ label: String, value: String, suffix: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 80, alignment: .leading)
            (Text(value).foregroundColor(theme.primaryText)
                + Text(suffix.map { " \($0)" } ?? "").foregroundColor(theme.warning))
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Turns

    @ViewBuilder
    private func turnsSection(_ row: AgentHistoryResultRow) -> some View {
        switch model.preview {
        case .idle, .loading:
            sectionLabel(model.parsedQuery.isEmpty ? "First prompt and latest reply" : "Matching turns")
            AgentHistoryMessageView(title: "Loading…", theme: theme, isCompact: true)
        case .failed(let failure):
            AgentHistoryMessageView(title: Self.failureText(failure), theme: theme, isCompact: true)
        case .loaded(let preview):
            sectionLabel(preview.turnsAreMatches ? "Matching turns (\(preview.turns.count))" : "First prompt and latest reply")
            turnCards(preview.turns, agent: row.agent, lineLimit: 8)
        }
    }

    /// The full transcript in place of the turns (→ / ⌘Y); UI6 replaces this with its own view.
    @ViewBuilder
    private func transcriptSection(_ row: AgentHistoryResultRow) -> some View {
        sectionLabel("Full transcript")
        switch model.transcript {
        case .idle, .loading:
            AgentHistoryMessageView(title: "Loading…", theme: theme, isCompact: true)
        case .failed(let failure):
            AgentHistoryMessageView(title: Self.failureText(failure), theme: theme, isCompact: true)
        case .loaded(let transcript):
            turnCards(transcript.turns, agent: row.agent, lineLimit: nil)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }

    private func turnCards(_ turns: [HistoryTurnMatch], agent: AgentHistoryAgent, lineLimit: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(turns, id: \.messageID) { turn in
                AgentHistoryTurnCard(turn: turn, agent: agent, theme: theme, lineLimit: lineLimit)
            }
        }
    }

    static func failureText(_ failure: AgentHistoryViewModel.LoadFailure) -> String {
        switch failure {
        case .notIndexed: "Not indexed yet"
        case .sessionNotFound: "This session is no longer in Agent History."
        case .failed: "Couldn't load this session."
        }
    }

    // MARK: - Resume command

    @ViewBuilder
    private func resumeCommandRow(_ row: AgentHistoryResultRow) -> some View {
        switch model.resumeAvailability(for: row.key) {
        case .some(.available(let plan)):
            HStack(spacing: 8) {
                Text(plan.command)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Resume command: \(plan.command)")
                AgentHistoryActionButton(title: "Copy", keys: nil, isPrimary: false, theme: theme, isSmall: true) {
                    model.copyResumeCommand(for: row.key)
                }
                .accessibilityLabel("Copy resume command")
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(theme.cardBorder, lineWidth: 1))
        default:
            HStack(spacing: 8) {
                Text("Can't build a resume command for this session")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AgentHistoryActionButton(title: "Copy Session ID", keys: nil, isPrimary: false, theme: theme, isSmall: true) {
                    model.copySessionID(for: row.key)
                }
            }
        }
    }

    /// `~/…` for paths under the home directory.
    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// One turn: who wrote it and the highlighted text.
struct AgentHistoryTurnCard: View {
    let turn: HistoryTurnMatch
    let agent: AgentHistoryAgent
    let theme: AgentHistoryTheme
    let lineLimit: Int?

    var body: some View {
        let speaker = turn.role == .user ? "You" : agent.displayName
        VStack(alignment: .leading, spacing: 3) {
            Text(speaker)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Text(AgentHistoryTextStyler.attributed(
                AgentHistoryHighlightedText(turn.text, ranges: turn.highlights),
                theme: theme,
                font: .system(size: 12.5),
                color: theme.primaryText
            ))
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.cardBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(turn.role == .user ? theme.selectedBackground : theme.cardBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(turn.role == .user ? "You said" : "\(agent.displayName) said") \(turn.text)")
    }
}

/// The palette's buttons: primary (filled) or secondary, with an optional key hint.
struct AgentHistoryActionButton: View {
    let title: String
    let keys: String?
    let isPrimary: Bool
    let theme: AgentHistoryTheme
    var isSmall = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: isSmall ? 11 : 12.5, weight: isPrimary ? .semibold : .regular))
                if let keys {
                    Text(keys)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .opacity(0.75)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(isPrimary ? Color.white : theme.primaryText)
            .padding(.horizontal, isSmall ? 8 : 12)
            .padding(.vertical, isSmall ? 3 : 6)
            .background(
                RoundedRectangle(cornerRadius: isSmall ? 5 : 8, style: .continuous)
                    .fill(isPrimary ? Color.accentColor : theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: isSmall ? 5 : 8, style: .continuous)
                    .stroke(isPrimary ? Color.clear : theme.cardBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .fixedSize()
    }
}
