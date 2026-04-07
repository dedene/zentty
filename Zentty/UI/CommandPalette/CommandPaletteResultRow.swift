import SwiftUI

struct CommandPaletteResultRow: View {
    let item: CommandPaletteItem
    let showsSubtitle: Bool
    let isSelected: Bool
    let primaryColor: Color
    let secondaryColor: Color
    let selectedBackgroundColor: Color
    let hoverBackgroundColor: Color

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white : primaryColor)
                    .lineLimit(1)
                if showsSubtitle {
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : secondaryColor)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(item.category)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isSelected ? .white.opacity(0.7) : secondaryColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill((isSelected ? Color.white : primaryColor).opacity(0.08))
                )
            if let shortcut = item.shortcutDisplay {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : secondaryColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? selectedBackgroundColor : (isHovered ? hoverBackgroundColor : .clear))
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
