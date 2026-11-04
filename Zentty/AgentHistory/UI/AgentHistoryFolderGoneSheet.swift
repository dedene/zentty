import SwiftUI

/// The folder-gone sheet as an in-panel overlay: a dimmed backdrop over the palette and a 500 pt
/// card near the top. Keys reach it through the panel's key monitor (↑↓ move, ↩ continue,
/// esc cancel); clicks pick an option, a double click continues with it.
struct AgentHistoryFolderGoneSheet: View {
    static let maxWidth: CGFloat = 500

    @ObservedObject var model: AgentHistoryViewModel
    let sheet: AgentHistoryFolderGoneSheetModel

    private var theme: AgentHistoryTheme { model.theme }

    var body: some View {
        ZStack(alignment: .top) {
            theme.sheetBackdrop
                .contentShape(Rectangle())
                // Clicks outside the card are absorbed; the sheet only closes on Cancel or esc.
                .onTapGesture {}
                .accessibilityHidden(true)
            card
                .frame(maxWidth: Self.maxWidth)
                .padding(.horizontal, 16)
                .padding(.top, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AgentHistoryFolderGoneSheetModel.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text(attributed(sheet.message, size: 12.5, color: theme.primaryText.opacity(0.85)))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(sheet.accessibilityMessage)
            VStack(spacing: 8) {
                ForEach(sheet.displayOptions) { option in
                    optionRow(option)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Where to continue")
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                AgentHistoryActionButton(
                    title: AgentHistoryFolderGoneSheetModel.cancelTitle,
                    keys: "esc",
                    isPrimary: false,
                    theme: theme,
                    action: model.cancelFolderSheet
                )
                .accessibilityLabel(AgentHistoryFolderGoneSheetModel.cancelTitle)
                AgentHistoryActionButton(
                    title: AgentHistoryFolderGoneSheetModel.confirmTitle,
                    keys: "↩",
                    isPrimary: true,
                    theme: theme,
                    action: model.confirmFolderSheet
                )
                .accessibilityLabel(AgentHistoryFolderGoneSheetModel.confirmTitle)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(theme.sheetBackground)
                .shadow(color: theme.sheetShadow, radius: 30, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(theme.cardBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(AgentHistoryFolderGoneSheetModel.title)
    }

    private func optionRow(_ option: AgentHistoryFolderGoneSheetModel.Option) -> some View {
        let isSelected = option.id == sheet.selectedIndex
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.accentColor : theme.secondaryText)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Text(attributed(option.detail, size: 11.5, color: theme.secondaryText))
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? theme.selectedBackground : theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.6) : theme.cardBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.selectFolderSheetOption(option.id, confirm: true)
        })
        .simultaneousGesture(TapGesture().onEnded {
            model.selectFolderSheetOption(option.id)
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectFolderSheetOption(option.id) }
    }

    /// Text runs in the system font, paths and commands in monospace on a faint chip.
    private func attributed(
        _ parts: [AgentHistoryFolderGoneSheetModel.TextPart],
        size: CGFloat,
        color: Color
    ) -> AttributedString {
        var result = AttributedString()
        for part in parts {
            switch part {
            case .text(let text):
                var run = AttributedString(text)
                run.font = .system(size: size)
                run.foregroundColor = color
                result += run
            case .code(let code):
                var run = AttributedString(code)
                run.font = .system(size: size - 1, design: .monospaced)
                run.foregroundColor = theme.primaryText
                run.backgroundColor = theme.cardBackground
                result += run
            }
        }
        return result
    }
}
