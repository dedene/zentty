import SwiftUI

struct CommandPaletteResolvedScope: Equatable {
    let family: CommandPaletteItemFamily
    let title: String
    let subtitle: String?
}

struct CommandPaletteResolvedItem: Equatable {
    let item: CommandPaletteItem
    let showsSubtitle: Bool
}

struct CommandPaletteResolvedResults: Equatable {
    let items: [CommandPaletteResolvedItem]
    let scope: CommandPaletteResolvedScope?
}

enum CommandPaletteResultsResolver {
    static func resolve(
        searchText: String,
        items: [CommandPaletteItem],
        recentItems: [CommandPaletteItem]
    ) -> CommandPaletteResolvedResults {
        let normalizedQuery = normalized(searchText)
        guard !normalizedQuery.isEmpty else {
            return CommandPaletteResolvedResults(
                items: recentItems.map { CommandPaletteResolvedItem(item: $0, showsSubtitle: true) },
                scope: nil
            )
        }

        if let scopeActivation = resolveScope(query: normalizedQuery, items: items) {
            return resolveScopedResults(
                queryRemainder: scopeActivation.remainder,
                items: items,
                recentItems: recentItems,
                family: scopeActivation.family
            )
        }

        let resolvedItems = items
            .enumerated()
            .map { index, item in
                (item: item, score: FuzzyMatcher.score(query: normalizedQuery, in: item.searchText), index: index)
            }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.index < rhs.index
                }
                return lhs.score > rhs.score
            }
            .map { CommandPaletteResolvedItem(item: $0.item, showsSubtitle: true) }

        return CommandPaletteResolvedResults(items: resolvedItems, scope: nil)
    }

    private static func resolveScopedResults(
        queryRemainder: String,
        items: [CommandPaletteItem],
        recentItems: [CommandPaletteItem],
        family: CommandPaletteItemFamily
    ) -> CommandPaletteResolvedResults {
        let familyItems = items.enumerated().compactMap { index, item -> (item: CommandPaletteItem, index: Int)? in
            guard item.family == family else { return nil }
            return (item, index)
        }

        let recentRankByID = Dictionary(
            uniqueKeysWithValues: recentItems
                .filter { $0.family == family }
                .enumerated()
                .map { offset, item in (item.id, offset) }
        )

        let normalizedRemainder = normalized(queryRemainder)
        let scoredItems = familyItems.map { entry in
            let target = entry.item.familySearchText ?? entry.item.searchText
            return (
                item: entry.item,
                index: entry.index,
                score: normalizedRemainder.isEmpty ? 0 : FuzzyMatcher.score(query: normalizedRemainder, in: target),
                recentRank: recentRankByID[entry.item.id]
            )
        }

        let orderedItems = scoredItems.sorted { lhs, rhs in
            let lhsMatches = lhs.score > 0
            let rhsMatches = rhs.score > 0
            if lhsMatches != rhsMatches {
                return lhsMatches && !rhsMatches
            }

            if lhsMatches && rhsMatches && lhs.score != rhs.score {
                return lhs.score > rhs.score
            }

            switch (lhs.recentRank, rhs.recentRank) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let leftFamilyOrder = lhs.item.familyOrder ?? lhs.index
                let rightFamilyOrder = rhs.item.familyOrder ?? rhs.index
                if leftFamilyOrder != rightFamilyOrder {
                    return leftFamilyOrder < rightFamilyOrder
                }
                return lhs.index < rhs.index
            }
        }

        let scopeSubtitle = orderedItems.first?.item.subtitle
        return CommandPaletteResolvedResults(
            items: orderedItems.map {
                CommandPaletteResolvedItem(
                    item: $0.item,
                    showsSubtitle: $0.item.family != family
                )
            },
            scope: CommandPaletteResolvedScope(
                family: family,
                title: family.scopeTitle,
                subtitle: scopeSubtitle
            )
        )
    }

    private static func resolveScope(
        query: String,
        items: [CommandPaletteItem]
    ) -> (family: CommandPaletteItemFamily, remainder: String)? {
        for family in CommandPaletteItemFamily.allCases {
            let familyItems = items.filter { $0.family == family }
            guard !familyItems.isEmpty else { continue }

            if let remainder = family.explicitRemainder(for: query) {
                return (family, remainder)
            }

            if let remainder = family.aliasRemainder(for: query),
               (remainder.isEmpty || familyItems.contains(where: {
                   FuzzyMatcher.score(
                       query: remainder,
                       in: $0.familySearchText ?? $0.searchText
                   ) > 0
               }))
            {
                return (family, remainder)
            }
        }

        return nil
    }

    private static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

private extension CommandPaletteItemFamily {
    static let allCases: [CommandPaletteItemFamily] = [.openWith]

    var scopeTitle: String {
        switch self {
        case .openWith:
            "Open With"
        }
    }

    func explicitRemainder(for query: String) -> String? {
        switch self {
        case .openWith:
            return remainder(in: query, matching: "open with")
        }
    }

    func aliasRemainder(for query: String) -> String? {
        switch self {
        case .openWith:
            return remainder(in: query, matching: "open")
        }
    }

    private func remainder(in query: String, matching prefix: String) -> String? {
        if query == prefix {
            return ""
        }

        let prefixedValue = "\(prefix) "
        guard query.hasPrefix(prefixedValue) else { return nil }
        return String(query.dropFirst(prefixedValue.count))
    }
}

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
    let onExecute: (CommandPaletteItemID) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool

    private var resolvedResults: CommandPaletteResolvedResults {
        CommandPaletteResultsResolver.resolve(
            searchText: searchText,
            items: items,
            recentItems: recentItems
        )
    }

    private var displayedItems: [CommandPaletteResolvedItem] {
        resolvedResults.items
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
                VStack(spacing: 0) {
                    if let scope = resolvedResults.scope {
                        scopeHeader(scope)
                    }

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(results.enumerated()), id: \.element.item.id) { index, resolvedItem in
                                    CommandPaletteResultRow(
                                        item: resolvedItem.item,
                                        showsSubtitle: resolvedItem.showsSubtitle,
                                        isSelected: index == selectedIndex,
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
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                        }
                        .frame(maxHeight: 340)
                        .onChange(of: selectedIndex) {
                            if let item = results[safe: selectedIndex] {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    proxy.scrollTo(item.item.id, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
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
        onExecute(item.item.id)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
