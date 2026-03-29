import SwiftUI

struct CommandPaletteTheme {
    let primaryColor: Color
    let secondaryColor: Color
    let separatorColor: Color
    let selectedBackgroundColor: Color
    let hoverBackgroundColor: Color

    init(zenttyTheme: ZenttyTheme) {
        primaryColor = Color(nsColor: zenttyTheme.commandPaletteText)
        secondaryColor = Color(nsColor: zenttyTheme.commandPaletteSecondaryText)
        separatorColor = Color(nsColor: zenttyTheme.commandPaletteSeparator)
        selectedBackgroundColor = Color(nsColor: zenttyTheme.commandPaletteRowSelectedBackground)
        hoverBackgroundColor = Color(nsColor: zenttyTheme.commandPaletteRowHoverBackground)
    }
}

struct CommandPaletteView: View {
    let items: [CommandPaletteItem]
    let recentItems: [CommandPaletteItem]
    let theme: CommandPaletteTheme
    let onExecute: (AppCommandID) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool

    private var displayedItems: [CommandPaletteItem] {
        if searchText.isEmpty {
            return recentItems
        }

        let query = searchText.lowercased()
        return items
            .map { item in (item: item, score: FuzzyMatcher.score(query: query, in: item.searchText)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .map(\.item)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
                .opacity(0.3)
            resultsList
        }
        .frame(width: 640)
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onKeyPress(.return) {
            executeSelected()
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(theme.secondaryColor)
            TextField("Type a command\u{2026}", text: $searchText, prompt: Text("Type a command\u{2026}").foregroundStyle(theme.secondaryColor))
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(theme.primaryColor)
                .focused($isSearchFocused)
                .onAppear { isSearchFocused = true }
                .onChange(of: searchText) {
                    selectedIndex = 0
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.secondaryColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var resultsList: some View {
        Group {
            let results = displayedItems
            if results.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                CommandPaletteResultRow(
                                    item: item,
                                    isSelected: index == selectedIndex,
                                    primaryColor: theme.primaryColor,
                                    secondaryColor: theme.secondaryColor,
                                    selectedBackgroundColor: theme.selectedBackgroundColor,
                                    hoverBackgroundColor: theme.hoverBackgroundColor
                                )
                                .id(item.id)
                                .onTapGesture {
                                    onExecute(item.id)
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: selectedIndex) {
                        if let item = results[safe: selectedIndex] {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(item.id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        Text(searchText.isEmpty ? "No recent commands" : "No matching commands")
            .font(.system(size: 13))
            .foregroundStyle(theme.secondaryColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    private var displayedItemCount: Int {
        displayedItems.count
    }

    private func moveSelection(by delta: Int) {
        let count = displayedItemCount
        guard count > 0 else { return }
        selectedIndex = max(0, min(count - 1, selectedIndex + delta))
    }

    private func executeSelected() {
        let results = displayedItems
        guard let item = results[safe: selectedIndex] else { return }
        onExecute(item.id)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
