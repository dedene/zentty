import SwiftUI

/// The result list: section headers with their notes, rows, and the empty states. Rows are not
/// focusable; the search field keeps focus and ↑↓ move the selection.
struct AgentHistoryResultsList: View {
    @ObservedObject var model: AgentHistoryViewModel

    var body: some View {
        let theme = model.theme
        let now = model.services.now()
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.sections) { section in
                        sectionHeader(section, theme: theme)
                        ForEach(section.rows) { row in
                            rowView(row, theme: theme, now: now)
                        }
                    }
                    if let empty = model.emptyResults {
                        AgentHistoryNoResultsView(empty: empty, theme: theme)
                    } else if model.rows.isEmpty, model.query.isEmpty {
                        AgentHistoryMessageView(
                            title: "No sessions yet",
                            detail: "Sessions show up here as soon as they are indexed.",
                            theme: theme
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 2)
                .padding(.bottom, 10)
            }
            .onChange(of: model.selectedKey) { key in
                guard let key else { return }
                proxy.scrollTo(key)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessions")
    }

    private func sectionHeader(_ section: AgentHistorySection, theme: AgentHistoryTheme) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(section.kind.title)
                .font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 8)
            if let note = section.note {
                Text(note)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(theme.secondaryText)
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func rowView(_ row: AgentHistoryResultRow, theme: AgentHistoryTheme, now: Date) -> some View {
        let isFolderGone = model.folderGoneKeys.contains(row.key)
        return AgentHistoryResultRowView(
            row: row,
            isSelected: row.key == model.selectedKey,
            isFolderGone: isFolderGone,
            theme: theme,
            formatting: model.formatting,
            now: now
        )
        .id(row.key)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.select(row.key)
            model.perform(.primary, on: row.key)
        })
        .simultaneousGesture(TapGesture().onEnded {
            model.select(row.key)
        })
        .contextMenu {
            ForEach(model.rowMenuItems(for: row.key), id: \.self) { item in
                if item == .removeFromHistory {
                    Divider()
                }
                Button(item.title) {
                    model.perform(item, on: row.key)
                }
            }
        }
        .accessibilityAction {
            model.select(row.key)
            model.perform(.primary, on: row.key)
        }
    }
}

/// One session row: agent badge, title, meta line, snippet, and the right column (Live,
/// Archived, Folder gone, time, match count).
struct AgentHistoryResultRowView: View {
    let row: AgentHistoryResultRow
    let isSelected: Bool
    let isFolderGone: Bool
    let theme: AgentHistoryTheme
    let formatting: AgentHistoryFormatting
    let now: Date

    @State private var isHovered = false

    private var primaryColor: Color { isSelected ? .white : theme.primaryText }
    private var secondaryColor: Color { isSelected ? .white.opacity(0.75) : theme.secondaryText }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentHistoryAgentBadge(agent: row.agent, theme: theme, isSelected: isSelected)
            VStack(alignment: .leading, spacing: 2) {
                Text(AgentHistoryTextStyler.attributed(
                    row.title,
                    theme: theme,
                    font: .system(size: 13, weight: .semibold),
                    color: primaryColor
                ))
                .lineLimit(1)
                .truncationMode(.tail)
                metaLine
                if let snippet = row.snippet {
                    snippetLine(snippet)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            sideColumn
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? theme.selectedBackground : (isHovered ? theme.hoverBackground : .clear))
        )
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(formatting.rowAccessibilityLabel(row, isFolderGone: isFolderGone, now: now))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var metaLine: some View {
        var parts = [row.agent.displayName]
        if let repo = row.summary?.repoName ?? row.live?.worklaneDisplayName {
            parts.append(repo)
        }
        if let branch = row.summary?.branch {
            parts.append(branch)
        }
        var text = Text(parts.joined(separator: " · ")).foregroundColor(secondaryColor)
        if let note = row.note {
            text = text + Text(" · ").foregroundColor(secondaryColor)
                + Text(formatting.noteText(note)).foregroundColor(primaryColor.opacity(0.8))
        }
        return text
            .font(.system(size: 11.5))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func snippetLine(_ snippet: AgentHistorySnippetLine) -> some View {
        let lead = Text("\(formatting.snippetRoleLabel(snippet.role)): ")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(secondaryColor)
        let body = Text(AgentHistoryTextStyler.attributed(
            snippet.text,
            theme: theme,
            font: .system(size: 12),
            color: primaryColor.opacity(0.85)
        ))
        return (lead + body)
            .lineLimit(2)
            .opacity(row.isStale ? 0.6 : 1)
            .padding(.top, 2)
    }

    private var sideColumn: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if row.live != nil {
                HStack(spacing: 4) {
                    Circle().fill(theme.live).frame(width: 6, height: 6)
                    Text("Live").fontWeight(.semibold)
                }
                .foregroundStyle(theme.live)
            }
            if row.summary?.isArchived == true {
                Text("Archived")
            }
            if isFolderGone {
                Text("Folder gone").foregroundStyle(theme.warning)
            }
            if let date = row.displayDate {
                Text(formatting.relativeTime(date, now: now))
            }
            if let matches = formatting.matches(row.hitCount) {
                Text(matches)
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(secondaryColor)
        .lineLimit(1)
        .fixedSize()
    }
}

/// The 24 pt rounded badge with the agent's monochrome glyph.
struct AgentHistoryAgentBadge: View {
    let agent: AgentHistoryAgent
    let theme: AgentHistoryTheme
    var isSelected = false
    var size: CGFloat = 24

    var body: some View {
        Image(nsImage: AgentHistoryAgentIcon.image(for: agent))
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size * 0.58, height: size * 0.58)
            .foregroundStyle(isSelected ? Color.white : theme.primaryText)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                    .fill(theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                    .stroke(theme.cardBorder, lineWidth: 1)
            )
            .padding(.top, 1)
            .accessibilityHidden(true)
    }
}
