import AppKit
import FuzzyMatch

enum CommandPaletteLayoutMetrics {
    static let panelWidth: CGFloat = 640
    static let maximumPanelHeight: CGFloat = 480
    static let searchFieldHeight: CGFloat = 58
    static let footerHeight: CGFloat = 50
    static let dividerHeight: CGFloat = 1
    static let rowIconSize: CGFloat = 20
    static let rowIconSymbolSize: CGFloat = 15
    static let rowIconOpacity = 0.9
    static let rowHorizontalPadding: CGFloat = 8
    static let rowVerticalPadding: CGFloat = 5
    static let rowSpacing: CGFloat = 2
    static let resultsVerticalPadding: CGFloat = 12
    static let sectionHeaderHorizontalPadding = rowHorizontalPadding
    static let sectionHeaderBottomSpacing: CGFloat = 2
    static let sectionHeaderHeight: CGFloat = lineHeight(for: .systemFont(ofSize: 11, weight: .semibold)) + 8
    static let dynamicHeightChangeAnimationDuration: TimeInterval = 0
    static let visualOverflowAllowance: CGFloat = 2
    static let scopedHeaderHeightWithSubtitle: CGFloat = lineHeight(for: .systemFont(ofSize: 11, weight: .semibold))
        + lineHeight(for: .systemFont(ofSize: 11))
        + rowSpacing
        + 14
    static let scopedHeaderHeightWithoutSubtitle: CGFloat = lineHeight(for: .systemFont(ofSize: 11, weight: .semibold))
        + 14
    static let singleLineRowHeight: CGFloat = max(
        lineHeight(for: .systemFont(ofSize: 13, weight: .medium)),
        rowIconSize
    ) + (rowVerticalPadding * 2)
    static let doubleLineRowHeight: CGFloat = lineHeight(for: .systemFont(ofSize: 13, weight: .medium))
        + lineHeight(for: .systemFont(ofSize: 11))
        + rowSpacing
        + (rowVerticalPadding * 2)
    static let emptyStateHeight: CGFloat = lineHeight(for: .systemFont(ofSize: 13))
        + 48

    private static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func preferredPanelHeight(results: CommandPaletteResolvedResults) -> CGFloat {
        min(maximumPanelHeight, ceil(uncappedPanelHeight(results: results)))
    }

    static func uncappedPanelHeight(results: CommandPaletteResolvedResults) -> CGFloat {
        let scopeHeight: CGFloat
        if let scope = results.scope {
            scopeHeight = (scope.subtitle?.isEmpty == false)
                ? scopedHeaderHeightWithSubtitle
                : scopedHeaderHeightWithoutSubtitle
        } else {
            scopeHeight = 0
        }

        let sectionHeaderHeight = results.scope == nil
            ? CGFloat(results.sections.count) * Self.sectionHeaderHeight
            : 0

        let resultsHeight: CGFloat
        if results.items.isEmpty {
            resultsHeight = emptyStateHeight
        } else {
            resultsHeight = results.items.reduce(CGFloat.zero) { partial, item in
                partial + (item.showsSubtitle ? doubleLineRowHeight : singleLineRowHeight)
            } + sectionHeaderHeight + resultsVerticalPadding
                + (CGFloat(max(results.items.count - 1, 0)) * rowSpacing)
                + visualOverflowAllowance
        }

        let totalHeight = searchFieldHeight + dividerHeight + scopeHeight + resultsHeight + footerHeight
        return ceil(totalHeight)
    }

    static func maximumScrollableResultsHeight(scope: CommandPaletteResolvedScope?) -> CGFloat {
        let scopeHeight: CGFloat
        if let scope {
            scopeHeight = (scope.subtitle?.isEmpty == false)
                ? scopedHeaderHeightWithSubtitle
                : scopedHeaderHeightWithoutSubtitle
        } else {
            scopeHeight = 0
        }

        return maximumPanelHeight - searchFieldHeight - dividerHeight - scopeHeight - footerHeight
    }
}

struct CommandPaletteSearchIndex {
    let items: [CommandPaletteSearchCandidate]
    let recentItems: [CommandPaletteItem]
    let recentPaneIDs: [CommandPaletteItemID]
    let currentPaneID: CommandPaletteItemID?
    let emptyActionIDs: [CommandPaletteItemID]
    let itemByID: [CommandPaletteItemID: CommandPaletteItem]
    let itemsByFamily: [CommandPaletteItemFamily: [CommandPaletteSearchCandidate]]

    init(
        items: [CommandPaletteItem],
        recentItems: [CommandPaletteItem],
        recentPaneIDs: [CommandPaletteItemID] = [],
        currentPaneID: CommandPaletteItemID? = nil,
        emptyActionIDs: [CommandPaletteItemID] = []
    ) {
        let candidates = items.enumerated().map { index, item in
            CommandPaletteSearchCandidate(index: index, item: item)
        }
        self.items = candidates
        self.recentItems = recentItems
        self.recentPaneIDs = recentPaneIDs
        self.currentPaneID = currentPaneID
        self.emptyActionIDs = emptyActionIDs
        self.itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        self.itemsByFamily = Dictionary(grouping: candidates.compactMap { candidate in
            candidate.item.family.map { ($0, candidate) }
        }, by: \.0).mapValues { $0.map(\.1) }
    }
}

struct CommandPaletteSearchCandidate {
    let index: Int
    let item: CommandPaletteItem
    let searchText: String
    let primarySearchText: String
    let secondarySearchText: String
    let primaryAliasSearchText: String
    let secondaryAliasSearchText: String
    let familySearchText: String?

    init(index: Int, item: CommandPaletteItem) {
        self.index = index
        self.item = item
        self.searchText = item.searchText
        self.primarySearchText = item.primarySearchText
        self.secondarySearchText = item.secondarySearchText
        self.primaryAliasSearchText = item.primaryAliasSearchText
        self.secondaryAliasSearchText = item.secondaryAliasSearchText
        self.familySearchText = item.familySearchText
    }
}

struct CommandPaletteResolvedScope: Equatable {
    let family: CommandPaletteItemFamily
    let title: String
    let subtitle: String?
}

struct CommandPaletteResolvedItem: Equatable {
    let item: CommandPaletteItem
    let showsSubtitle: Bool
    let showsCategory: Bool
}

struct CommandPaletteResolvedSection: Equatable, Identifiable {
    let id: String
    let title: String
    let items: [CommandPaletteResolvedItem]
}

struct CommandPaletteResolvedResults: Equatable {
    let items: [CommandPaletteResolvedItem]
    let scope: CommandPaletteResolvedScope?
    let sections: [CommandPaletteResolvedSection]
    let requiresScrolling: Bool

    init(
        items: [CommandPaletteResolvedItem],
        scope: CommandPaletteResolvedScope?,
        sections: [CommandPaletteResolvedSection]? = nil,
        requiresScrolling: Bool = false
    ) {
        self.items = items
        self.scope = scope
        self.sections = sections ?? (items.isEmpty ? [] : [
            CommandPaletteResolvedSection(id: "results", title: "", items: items),
        ])
        self.requiresScrolling = requiresScrolling
    }
}

enum CommandPaletteResultsResolver {
    private static let activeSearchLimitByGroup: [CommandPaletteItemGroup: Int] = [
        .pane: 12,
        .settings: 8,
        .action: 12,
    ]

    static func resolve(
        searchText: String,
        items: [CommandPaletteItem],
        recentItems: [CommandPaletteItem],
        recentPaneIDs: [CommandPaletteItemID] = [],
        currentPaneID: CommandPaletteItemID? = nil,
        emptyActionIDs: [CommandPaletteItemID] = []
    ) -> CommandPaletteResolvedResults {
        let index = CommandPaletteSearchIndex(
            items: items,
            recentItems: recentItems,
            recentPaneIDs: recentPaneIDs,
            currentPaneID: currentPaneID,
            emptyActionIDs: emptyActionIDs
        )
        return resolve(searchText: searchText, index: index)
    }

    static func resolve(
        searchText: String,
        index searchIndex: CommandPaletteSearchIndex
    ) -> CommandPaletteResolvedResults {
        let normalizedQuery = CommandPaletteSearchTextNormalizer.normalized(searchText)
        guard !normalizedQuery.isEmpty else {
            return resolveEmptyResults(
                searchIndex: searchIndex
            )
        }

        if let scopeActivation = resolveScope(query: normalizedQuery, searchIndex: searchIndex) {
            return resolveScopedResults(
                queryRemainder: scopeActivation.remainder,
                searchIndex: searchIndex,
                family: scopeActivation.family
            )
        }

        let scoredItems = searchIndex.items
            .map { candidate in
                (
                    item: candidate.item,
                    score: CommandPaletteFieldAwareScorer.score(query: normalizedQuery, candidate: candidate),
                    index: candidate.index
                )
            }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.index < rhs.index
                }
                return lhs.score > rhs.score
            }

        let sections = groupedSections(from: scoredItems.map(\.item), appliesActiveSearchLimits: true)
        let results = CommandPaletteResolvedResults(
            items: sections.flatMap(\.items),
            scope: nil,
            sections: sections
        )
        return CommandPaletteResolvedResults(
            items: results.items,
            scope: nil,
            sections: sections,
            requiresScrolling: CommandPaletteLayoutMetrics.uncappedPanelHeight(results: results) > CommandPaletteLayoutMetrics.maximumPanelHeight
        )
    }

    private static func resolveEmptyResults(
        searchIndex: CommandPaletteSearchIndex
    ) -> CommandPaletteResolvedResults {
        let emptyActionIDSet = Set(searchIndex.emptyActionIDs)
        var sections: [CommandPaletteResolvedSection] = []

        let actionItems = searchIndex.emptyActionIDs.compactMap { searchIndex.itemByID[$0] }
        if !actionItems.isEmpty {
            sections.append(section(id: "empty-actions", title: "Actions", items: actionItems, showsSubtitle: false))
        }

        let paneItems = searchIndex.recentPaneIDs
            .removingDuplicates()
            .filter { $0 != searchIndex.currentPaneID }
            .compactMap { searchIndex.itemByID[$0] }
        if !paneItems.isEmpty {
            sections.append(section(id: "recent-panes", title: "Recent Panes", items: paneItems))
        }

        let recentActionItems = searchIndex.recentItems
            .filter { $0.group != .pane }
            .filter { !emptyActionIDSet.contains($0.id) }
            .removingDuplicates(by: \.id)
        if !recentActionItems.isEmpty {
            sections.append(section(id: "recent-actions", title: "Recent Actions", items: recentActionItems))
        }

        sections = sectionsPrunedToFitWithoutScrolling(sections)
        return CommandPaletteResolvedResults(
            items: sections.flatMap(\.items),
            scope: nil,
            sections: sections,
            requiresScrolling: false
        )
    }

    private static func groupedSections(
        from items: [CommandPaletteItem],
        appliesActiveSearchLimits: Bool = false
    ) -> [CommandPaletteResolvedSection] {
        CommandPaletteItemGroup.searchOrder.compactMap { group in
            var groupItems = items.filter { $0.group == group }
            if appliesActiveSearchLimits, let limit = activeSearchLimitByGroup[group] {
                groupItems = Array(groupItems.prefix(limit))
            }
            guard !groupItems.isEmpty else { return nil }
            return section(id: group.title.lowercased(), title: group.title, items: groupItems)
        }
    }

    private static func sectionsPrunedToFitWithoutScrolling(
        _ sections: [CommandPaletteResolvedSection]
    ) -> [CommandPaletteResolvedSection] {
        var fittedSections: [CommandPaletteResolvedSection] = []

        for section in sections {
            var fittedItems: [CommandPaletteResolvedItem] = []
            for item in section.items {
                let candidateSection = CommandPaletteResolvedSection(
                    id: section.id,
                    title: section.title,
                    items: fittedItems + [item]
                )
                let candidateSections = fittedSections + [candidateSection]
                let candidateResults = CommandPaletteResolvedResults(
                    items: candidateSections.flatMap(\.items),
                    scope: nil,
                    sections: candidateSections,
                    requiresScrolling: false
                )

                guard CommandPaletteLayoutMetrics.uncappedPanelHeight(results: candidateResults)
                    <= CommandPaletteLayoutMetrics.maximumPanelHeight
                else {
                    break
                }

                fittedItems.append(item)
            }

            if !fittedItems.isEmpty {
                fittedSections.append(
                    CommandPaletteResolvedSection(
                        id: section.id,
                        title: section.title,
                        items: fittedItems
                    )
                )
            }
        }

        return fittedSections
    }

    private static func section(
        id: String,
        title: String,
        items: [CommandPaletteItem],
        showsSubtitle: Bool = true,
        showsCategory: Bool = true
    ) -> CommandPaletteResolvedSection {
        CommandPaletteResolvedSection(
            id: id,
            title: title,
            items: items.map {
                CommandPaletteResolvedItem(
                    item: $0,
                    showsSubtitle: showsSubtitle,
                    showsCategory: showsCategory
                )
            }
        )
    }

    private static func resolveScopedResults(
        queryRemainder: String,
        searchIndex: CommandPaletteSearchIndex,
        family: CommandPaletteItemFamily
    ) -> CommandPaletteResolvedResults {
        let familyItems = searchIndex.itemsByFamily[family] ?? []

        let recentRankByID = Dictionary(
            uniqueKeysWithValues: searchIndex.recentItems
                .filter { $0.family == family }
                .enumerated()
                .map { offset, item in (item.id, offset) }
        )

        let normalizedRemainder = CommandPaletteSearchTextNormalizer.normalized(queryRemainder)
        let scoredItems = familyItems.map { entry in
            let target = entry.familySearchText ?? entry.searchText
            return (
                item: entry.item,
                index: entry.index,
                score: normalizedRemainder.isEmpty ? 0 : CommandPaletteFuzzyScorer.score(query: normalizedRemainder, in: target),
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
        let results = CommandPaletteResolvedResults(
            items: orderedItems.map {
                CommandPaletteResolvedItem(
                    item: $0.item,
                    showsSubtitle: $0.item.family != family,
                    showsCategory: $0.item.family != family
                )
            },
            scope: CommandPaletteResolvedScope(
                family: family,
                title: family.scopeTitle,
                subtitle: scopeSubtitle
            )
        )
        return CommandPaletteResolvedResults(
            items: results.items,
            scope: results.scope,
            sections: results.sections,
            requiresScrolling: CommandPaletteLayoutMetrics.uncappedPanelHeight(results: results) > CommandPaletteLayoutMetrics.maximumPanelHeight
        )
    }

    private static func resolveScope(
        query: String,
        searchIndex: CommandPaletteSearchIndex
    ) -> (family: CommandPaletteItemFamily, remainder: String)? {
        for family in CommandPaletteItemFamily.allCases {
            let familyItems = searchIndex.itemsByFamily[family] ?? []
            guard !familyItems.isEmpty else { continue }

            if let remainder = family.explicitRemainder(for: query) {
                return (family, remainder)
            }

            if let remainder = family.aliasRemainder(for: query),
               (remainder.isEmpty || familyItems.contains(where: {
                   CommandPaletteFuzzyScorer.score(
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
}

private extension CommandPaletteItemFamily {
    static let allCases: [CommandPaletteItemFamily] = [.openWith, .worklaneColor]

    var scopeTitle: String {
        switch self {
        case .openWith:
            "Open With"
        case .worklaneColor:
            "Worklane color"
        }
    }

    func explicitRemainder(for query: String) -> String? {
        switch self {
        case .openWith:
            return remainder(in: query, matching: "open with")
        case .worklaneColor:
            return remainder(in: query, matching: "worklane color")
        }
    }

    func aliasRemainder(for query: String) -> String? {
        switch self {
        case .openWith:
            return remainder(in: query, matching: "open")
        case .worklaneColor:
            return remainder(in: query, matching: "worklane")
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

private extension CommandPaletteItemGroup {
    static let searchOrder: [CommandPaletteItemGroup] = [.pane, .settings, .action]
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

private extension Array {
    func removingDuplicates<ID: Hashable>(by keyPath: KeyPath<Element, ID>) -> [Element] {
        var seen: Set<ID> = []
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}

enum CommandPaletteFuzzyScorer {
    private static let matcher = FuzzyMatch.FuzzyMatcher()

    static func score(query: String, in target: String) -> Double {
        matcher.score(target, against: query)?.score ?? 0
    }
}

enum CommandPaletteSearchTextNormalizer {
    static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func separatorInsensitive(_ text: String) -> String {
        normalized(
            text
                .lowercased()
                .map { isSeparator($0) ? " " : String($0) }
                .joined()
        )
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace
            || character == "-"
            || character == "_"
            || character == "."
            || character == "/"
    }
}

enum CommandPaletteFieldAwareScorer {
    static func score(query: String, candidate: CommandPaletteSearchCandidate) -> Double {
        let aliasQuery = CommandPaletteSearchTextNormalizer.separatorInsensitive(query)
        let primaryAliasScore = exactishScore(
            query: aliasQuery,
            target: candidate.primaryAliasSearchText,
            exact: 100,
            prefix: 94,
            contains: 88
        )
        let primaryFuzzyScore = CommandPaletteFuzzyScorer.score(query: query, in: candidate.primarySearchText)
        let secondaryAliasScore = exactishScore(
            query: aliasQuery,
            target: candidate.secondaryAliasSearchText,
            exact: 36,
            prefix: 32,
            contains: 28
        )
        let secondaryFuzzyScore = CommandPaletteFuzzyScorer.score(query: query, in: candidate.secondarySearchText)

        let primaryScore: Double
        if primaryAliasScore > 0 {
            primaryScore = primaryAliasScore
        } else if primaryFuzzyScore >= 0.7 {
            primaryScore = 70 + primaryFuzzyScore
        } else if primaryFuzzyScore > 0 {
            primaryScore = 12 + primaryFuzzyScore
        } else {
            primaryScore = 0
        }

        let secondaryScore: Double
        if secondaryAliasScore > 0 {
            secondaryScore = secondaryAliasScore
        } else if secondaryFuzzyScore > 0 {
            secondaryScore = secondaryFuzzyScore
        } else {
            secondaryScore = 0
        }

        let score = max(primaryScore, secondaryScore)
        guard score > 0 else { return 0 }
        return score + candidate.item.rankingBoost
    }

    private static func exactishScore(
        query: String,
        target: String,
        exact: Double,
        prefix: Double,
        contains: Double
    ) -> Double {
        guard !query.isEmpty, !target.isEmpty else { return 0 }
        if target == query { return exact }
        if target.hasPrefix(query) { return prefix }
        if target.contains(query) { return contains }
        return 0
    }
}
