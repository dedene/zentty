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
    let theme: CommandPaletteTheme
    let onExecute: (CommandPaletteItemID) -> Void
    let onDismiss: () -> Void
    let onHeightChange: (CGFloat) -> Void

    @StateObject private var viewModel: CommandPaletteViewModel
    @FocusState private var isSearchFocused: Bool

    init(
        items: [CommandPaletteItem],
        recentItems: [CommandPaletteItem],
        recentPaneIDs: [CommandPaletteItemID],
        currentPaneID: CommandPaletteItemID?,
        emptyActionIDs: [CommandPaletteItemID],
        theme: CommandPaletteTheme,
        onExecute: @escaping (CommandPaletteItemID) -> Void,
        onDismiss: @escaping () -> Void,
        onHeightChange: @escaping (CGFloat) -> Void
    ) {
        let searchIndex = CommandPaletteSearchIndex(
            items: items,
            recentItems: recentItems,
            recentPaneIDs: recentPaneIDs,
            currentPaneID: currentPaneID,
            emptyActionIDs: emptyActionIDs
        )
        _viewModel = StateObject(wrappedValue: CommandPaletteViewModel(searchIndex: searchIndex))
        self.theme = theme
        self.onExecute = onExecute
        self.onDismiss = onDismiss
        self.onHeightChange = onHeightChange
    }

    private var displayedItems: [CommandPaletteResolvedItem] {
        viewModel.resolvedResults.items
    }

    private var preferredPanelHeight: CGFloat {
        CommandPaletteLayoutMetrics.preferredPanelHeight(results: viewModel.resolvedResults)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
                .opacity(0.3)
            resultsList
            Divider()
                .opacity(0.3)
            footer
        }
        .frame(
            width: CommandPaletteLayoutMetrics.panelWidth,
            height: preferredPanelHeight,
            alignment: .top
        )
        .onAppear {
            onHeightChange(preferredPanelHeight)
        }
        .onChange(of: preferredPanelHeight) { _, newValue in
            onHeightChange(newValue)
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onKeyPress(.return) {
            executeSelected()
            return .handled
        }
        .onKeyPress(.upArrow) {
            viewModel.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.moveSelection(by: 1)
            return .handled
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(theme.secondaryColor)
            TextField(
                "Search commands, panes, and settings\u{2026}",
                text: $viewModel.searchText,
                prompt: Text("Search commands, panes, and settings\u{2026}").foregroundStyle(theme.secondaryColor)
            )
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .foregroundStyle(theme.primaryColor)
                .focused($isSearchFocused)
                .onAppear { isSearchFocused = true }
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.updateSearchText("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.secondaryColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: CommandPaletteLayoutMetrics.searchFieldHeight)
    }

    private var resultsList: some View {
        Group {
            let results = displayedItems
            if results.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    if let scope = viewModel.resolvedResults.scope {
                        scopeHeader(scope)
                    }

                    ScrollViewReader { proxy in
                        resultRows(results)
                            .conditionalScroll(
                                enabled: viewModel.resolvedResults.requiresScrolling,
                                maxHeight: CommandPaletteLayoutMetrics.maximumScrollableResultsHeight(
                                    scope: viewModel.resolvedResults.scope
                                )
                            )
                            .onChange(of: viewModel.selectedIndex) {
                                guard viewModel.resolvedResults.requiresScrolling,
                                      let item = results[safe: viewModel.selectedIndex]
                                else { return }
                                proxy.scrollTo(item.item.id, anchor: .center)
                            }
                            .onChange(of: viewModel.resolvedResults) {
                                guard viewModel.resolvedResults.requiresScrolling,
                                      let item = viewModel.resolvedResults.items[safe: viewModel.selectedIndex]
                                else { return }
                                proxy.scrollTo(item.item.id, anchor: .center)
                            }
                    }
                }
            }
        }
    }

    private func resultRows(_ results: [CommandPaletteResolvedItem]) -> some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            if viewModel.resolvedResults.scope == nil {
                ForEach(viewModel.resolvedResults.sections) { section in
                    sectionHeader(section.title)
                    ForEach(section.items, id: \.item.id) { resolvedItem in
                        row(for: resolvedItem)
                    }
                }
            } else {
                ForEach(results, id: \.item.id) { resolvedItem in
                    row(for: resolvedItem)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, CommandPaletteLayoutMetrics.resultsVerticalPadding / 2)
    }

    private var emptyState: some View {
        Text(viewModel.searchText.isEmpty ? "No recent panes or actions" : "No matching commands, panes, or settings")
            .font(.system(size: 13))
            .foregroundStyle(theme.secondaryColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            footerHint(keys: ["↑", "↓"], label: "Navigate")
            footerHint(keys: ["Return"], label: "Select")
            footerHint(keys: ["Esc"], label: "Close")
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: CommandPaletteLayoutMetrics.footerHeight)
    }

    private func footerHint(keys: [String], label: String) -> some View {
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryColor)
                    .frame(minWidth: 28, minHeight: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.secondaryColor.opacity(0.08))
                    )
            }
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.secondaryColor)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.secondaryColor)
            .frame(
                height: CommandPaletteLayoutMetrics.sectionHeaderHeight
                    - CommandPaletteLayoutMetrics.sectionHeaderBottomSpacing,
                alignment: .bottomLeading
            )
            .padding(.bottom, CommandPaletteLayoutMetrics.sectionHeaderBottomSpacing)
            .padding(.horizontal, CommandPaletteLayoutMetrics.sectionHeaderHorizontalPadding)
    }

    private func row(for resolvedItem: CommandPaletteResolvedItem) -> some View {
        let index = viewModel.index(of: resolvedItem.item.id)
        return CommandPaletteResultRow(
            item: resolvedItem.item,
            showsSubtitle: resolvedItem.showsSubtitle,
            showsCategory: resolvedItem.showsCategory,
            isSelected: index == viewModel.selectedIndex,
            primaryColor: theme.primaryColor,
            secondaryColor: theme.secondaryColor,
            selectedBackgroundColor: theme.selectedBackgroundColor,
            hoverBackgroundColor: theme.hoverBackgroundColor
        )
        .id(resolvedItem.item.id)
        .onTapGesture {
            onExecute(resolvedItem.item.id)
        }
    }

    private func scopeHeader(_ scope: CommandPaletteResolvedScope) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(scope.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryColor)
            if let subtitle = scope.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func executeSelected() {
        guard let item = viewModel.selectedItem else { return }
        onExecute(item.item.id)
    }
}

@MainActor
final class CommandPaletteViewModel: ObservableObject {
    typealias Resolver = (String, CommandPaletteSearchIndex) -> CommandPaletteResolvedResults

    @Published var searchText: String {
        didSet {
            guard searchText != oldValue else { return }
            selectedIndex = 0
            resolve()
        }
    }
    @Published private(set) var selectedIndex: Int
    @Published private(set) var resolvedResults: CommandPaletteResolvedResults

    private let searchIndex: CommandPaletteSearchIndex
    private let resolver: Resolver
    private var itemIndexByID: [CommandPaletteItemID: Int]

    init(
        searchIndex: CommandPaletteSearchIndex,
        resolver: @escaping Resolver = CommandPaletteResultsResolver.resolve(searchText:index:)
    ) {
        self.searchIndex = searchIndex
        self.resolver = resolver
        self.searchText = ""
        self.selectedIndex = 0
        let initialResults = resolver("", searchIndex)
        self.resolvedResults = initialResults
        self.itemIndexByID = Self.makeItemIndexByID(for: initialResults.items)
    }

    var selectedItem: CommandPaletteResolvedItem? {
        resolvedResults.items[safe: selectedIndex]
    }

    func updateSearchText(_ searchText: String) {
        self.searchText = searchText
    }

    func moveSelection(by delta: Int) {
        let count = resolvedResults.items.count
        guard count > 0 else { return }
        selectedIndex = max(0, min(count - 1, selectedIndex + delta))
    }

    func index(of itemID: CommandPaletteItemID) -> Int {
        itemIndexByID[itemID] ?? 0
    }

    private func resolve() {
        let nextResults = resolver(searchText, searchIndex)
        itemIndexByID = Self.makeItemIndexByID(for: nextResults.items)
        resolvedResults = nextResults
    }

    private static func makeItemIndexByID(
        for items: [CommandPaletteResolvedItem]
    ) -> [CommandPaletteItemID: Int] {
        Dictionary(uniqueKeysWithValues: items.enumerated().map { index, item in
            (item.item.id, index)
        })
    }
}

private extension View {
    @ViewBuilder
    func conditionalScroll(enabled: Bool, maxHeight: CGFloat) -> some View {
        if enabled {
            ScrollView {
                self
            }
            .frame(maxHeight: maxHeight, alignment: .top)
        } else {
            self
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
