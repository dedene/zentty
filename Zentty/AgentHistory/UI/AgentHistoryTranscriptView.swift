import SwiftUI

/// What the transcript view shows for a loaded transcript: the turns, where to scroll, and the
/// note above a capped transcript. Only user and agent turns exist (nothing stores tool calls,
/// so there are no "N tool calls" lines, D24).
struct AgentHistoryTranscriptPresentation: Equatable {
    let sessionID: Int64?
    let turns: [HistoryTurnMatch]
    /// The first matching turn; nil without a match (the view then stays at the top).
    let scrollTargetID: Int64?
    /// Set when the engine left older turns out (`HistorySearchEngine.transcriptLimit`).
    let truncationNote: String?

    init(_ transcript: HistoryTranscript, sessionID: Int64?, formatting: AgentHistoryFormatting) {
        self.sessionID = sessionID
        turns = transcript.turns
        if let target = transcript.firstMatchMessageID,
           transcript.turns.contains(where: { $0.messageID == target }) {
            scrollTargetID = target
        } else {
            scrollTargetID = nil
        }
        truncationNote = transcript.isTruncated
            ? formatting.transcriptTruncationNote(shownTurns: transcript.turns.count)
            : nil
    }
}

extension AgentHistoryViewModel {
    /// The loaded transcript of the selected session; nil while hidden, loading or failed.
    var transcriptPresentation: AgentHistoryTranscriptPresentation? {
        guard detail == .transcript, case .loaded(let transcript) = transcript else {
            return nil
        }
        return AgentHistoryTranscriptPresentation(
            transcript,
            sessionID: selectedRow?.sessionID,
            formatting: formatting
        )
    }
}

/// The full, read-only transcript (→ / ⌘Y) in place of the preview: a compact header, then every
/// turn oldest first, scrolled to the first match. Turns are lazy so 2,000-turn sessions stay
/// cheap; text is not selectable in v1. ←, ⌘Y or esc returns to the preview (key router).
struct AgentHistoryTranscriptView: View {
    @ObservedObject var model: AgentHistoryViewModel
    let row: AgentHistoryResultRow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: AgentHistoryTheme { model.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(theme.separator)
                .frame(height: 1)
                .accessibilityHidden(true)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Full transcript")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            AgentHistoryAgentBadge(agent: row.agent, theme: theme)
            VStack(alignment: .leading, spacing: 2) {
                Text(AgentHistoryTextStyler.attributed(
                    row.title,
                    theme: theme,
                    font: .system(size: 14, weight: .semibold),
                    color: theme.primaryText
                ))
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            backButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        var parts = ["Full transcript"]
        if let presentation = model.transcriptPresentation {
            parts.append(model.formatting.turnCount(presentation.turns.count))
        }
        return parts.joined(separator: " · ")
    }

    private var backButton: some View {
        Button {
            model.closeDetail()
        } label: {
            HStack(spacing: 5) {
                Text("←")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .accessibilityHidden(true)
                Text("Preview")
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(theme.cardBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel("Back to preview")
        .help("← or ⌘Y returns to the preview")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.transcript {
        case .idle, .loading:
            AgentHistoryMessageView(title: "Loading transcript…", theme: theme, isCompact: true)
                .padding(20)
        case .failed(let failure):
            AgentHistoryMessageView(title: AgentHistoryPreview.failureText(failure), theme: theme, isCompact: true)
                .padding(20)
        case .loaded:
            if let presentation = model.transcriptPresentation {
                if presentation.turns.isEmpty {
                    AgentHistoryMessageView(title: "No turns in this session yet.", theme: theme, isCompact: true)
                        .padding(20)
                } else {
                    turnList(presentation)
                }
            }
        }
    }

    private func turnList(_ presentation: AgentHistoryTranscriptPresentation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let note = presentation.truncationNote {
                        Text(note)
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 4)
                    }
                    ForEach(presentation.turns, id: \.messageID) { turn in
                        AgentHistoryTurnCard(turn: turn, agent: row.agent, theme: theme, lineLimit: nil)
                            .id(turn.messageID)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel("Transcript turns")
            .task(id: ScrollKey(sessionID: presentation.sessionID, target: presentation.scrollTargetID)) {
                guard let target = presentation.scrollTargetID else { return }
                // One layout pass first, so the lazy stack knows where the target sits.
                await Task.yield()
                if reduceMotion {
                    proxy.scrollTo(target, anchor: .top)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
        }
    }

    private struct ScrollKey: Equatable {
        let sessionID: Int64?
        let target: Int64?
    }
}
