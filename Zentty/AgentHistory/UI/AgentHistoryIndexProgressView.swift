import SwiftUI

/// The initial index in numbers: overall, then per agent folder. Exists only while there are
/// sessions left to index, so the palette footer's link goes away when the backfill is done.
struct AgentHistoryIndexProgress: Equatable {
    struct Row: Equatable, Identifiable {
        let agent: AgentHistoryAgent
        let root: String
        let indexed: Int
        let total: Int

        var id: String { "\(agent.rawValue):\(root)" }
    }

    let backfill: AgentHistoryBackfillProgress
    let rows: [Row]

    var fraction: Double { backfill.fraction ?? 0 }

    init?(status: AgentHistoryStatus) {
        let progress: AgentHistoryBackfillProgress
        switch status.state {
        case .backfilling(let current), .paused(_, let current?):
            progress = current
        default:
            return nil
        }
        guard progress.totalSessions > 0, progress.indexedSessions < progress.totalSessions else {
            return nil
        }
        backfill = progress
        rows = status.sources
            .filter { $0.isEnabled && $0.discovered > 0 }
            .map { Row(agent: $0.agent, root: $0.root, indexed: $0.indexed, total: $0.discovered) }
    }
}

/// A thin bar along the footer's top edge.
struct AgentHistoryFooterProgressBar: View {
    let fraction: Double
    let theme: AgentHistoryTheme

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geometry.size.width * fraction)
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

/// Opened from the footer during the initial index; fills the results area until Esc.
struct AgentHistoryIndexProgressView: View {
    let progress: AgentHistoryIndexProgress
    let status: AgentHistoryFooterHealth
    let theme: AgentHistoryTheme
    let onClose: () -> Void

    private let formatting = AgentHistoryFormatting()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Building your search index")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Indexing progress")
                    Text(status.text)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(status.isWarning ? theme.warning : theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Newest sessions first. Everything indexed so far is searchable, and indexing keeps going when you close this.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !progress.rows.isEmpty {
                    sources
                }
                AgentHistoryActionButton(
                    title: "Back to Search",
                    keys: "esc",
                    isPrimary: false,
                    theme: theme,
                    action: onClose
                )
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var sources: some View {
        VStack(spacing: 0) {
            ForEach(Array(progress.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(theme.separator)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
                sourceRow(row)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.cardBackground)
        )
    }

    private func sourceRow(_ row: AgentHistoryIndexProgress.Row) -> some View {
        let counts = "\(formatting.number(row.indexed)) / \(formatting.number(row.total))"
        return HStack(spacing: 10) {
            AgentHistoryAgentBadge(agent: row.agent, theme: theme)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.agent.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                Text(AgentHistoryPreview.abbreviated(row.root))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(counts)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(theme.primaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.agent.displayName): \(counts) sessions")
    }
}
