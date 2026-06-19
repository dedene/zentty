import AppKit

@MainActor
protocol SettingsSidebarViewControllerDelegate: AnyObject {
    func settingsSidebar(_ controller: SettingsSidebarViewController, didSelect section: SettingsSection)
}

/// Source-list sidebar for the settings window. Renders the grouped
/// `SettingsSidebarLayout` as a table and reports selection back to its
/// delegate. Selection is the only state it owns; the host swaps the detail
/// content in response.
@MainActor
final class SettingsSidebarViewController: NSViewController {
    enum Row: Equatable {
        case header(String)
        case section(SettingsSection)
    }

    /// Horizontal gutter the sidebar's content keeps from its edges — the same
    /// inset the search field uses, i.e. the gap between the sidebar and the
    /// main window. Row highlights and content align to it.
    nonisolated static let contentHorizontalInset: CGFloat = 10

    private enum Metrics {
        static let sectionRowHeight: CGFloat = 30
        static let headerRowHeight: CGFloat = 26
        // Align the group header text with the row icons.
        static let rowLeadingInset: CGFloat = SettingsSidebarViewController.contentHorizontalInset + 2
        static let verticalContentInset: CGFloat = 6
    }

    weak var delegate: SettingsSidebarViewControllerDelegate?

    let tableView = NSTableView()
    let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let groups: [SettingsSidebarGroup]
    private(set) var rows: [Row]
    private var selectedSection: SettingsSection?
    private var isSynchronizingSelection = false

    init(groups: [SettingsSidebarGroup] = SettingsSidebarLayout.groups) {
        self.groups = groups
        self.rows = SettingsSidebarViewController.flatten(groups)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settings.sidebar.column"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .fullWidth
        tableView.selectionHighlightStyle = .regular
        tableView.floatsGroupRows = false
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.rowSizeStyle = .custom
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: Metrics.verticalContentInset,
            left: 0,
            bottom: Metrics.verticalContentInset,
            right: 0
        )
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search"
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self

        let container = NSView()
        container.addSubview(searchField)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            // Anchor to the safe-area top so the field clears the traffic lights
            // while the sidebar's vibrant material still fills up behind them.
            searchField.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.contentHorizontalInset),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.contentHorizontalInset),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
    }

    /// Selects the row for `section` without re-notifying the delegate.
    func select(section: SettingsSection) {
        _ = view
        selectedSection = section
        if rows.firstIndex(of: .section(section)) == nil, !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            rows = Self.flatten(groups)
            tableView.reloadData()
        }
        guard let index = rows.firstIndex(of: .section(section)), tableView.selectedRow != index else {
            return
        }
        isSynchronizingSelection = true
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        isSynchronizingSelection = false
    }

    private func applyFilter() {
        rows = Self.filterRows(query: searchField.stringValue, groups: groups)
        tableView.reloadData()
        restoreSelectionAfterFilter()
    }

    /// Keeps the active section selected when it survives the filter; otherwise
    /// selects the first visible section and tells the host to follow.
    private func restoreSelectionAfterFilter() {
        if let selectedSection, let index = rows.firstIndex(of: .section(selectedSection)) {
            isSynchronizingSelection = true
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            isSynchronizingSelection = false
            return
        }

        guard
            let firstIndex = rows.firstIndex(where: { row in
                if case .section = row { return true }
                return false
            }),
            case let .section(section) = rows[firstIndex]
        else {
            return
        }

        isSynchronizingSelection = true
        tableView.selectRowIndexes(IndexSet(integer: firstIndex), byExtendingSelection: false)
        isSynchronizingSelection = false
        selectedSection = section
        delegate?.settingsSidebar(self, didSelect: section)
    }

    func handleAppearanceChange() {
        // Badges use fixed system colors; nudge row views to redraw any
        // appearance-derived content.
        tableView.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
    }

    static func flatten(_ groups: [SettingsSidebarGroup]) -> [Row] {
        var result: [Row] = []
        for group in groups {
            if let title = group.title {
                result.append(.header(title))
            }
            result.append(contentsOf: group.sections.map(Row.section))
        }
        return result
    }

    /// Filters the grouped layout by `query`, matching section titles and
    /// keywords. Group headers are dropped when none of their sections match.
    /// An empty query returns the full layout.
    static func filterRows(query: String, groups: [SettingsSidebarGroup]) -> [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return flatten(groups)
        }

        var result: [Row] = []
        for group in groups {
            let matching = group.sections.filter { sectionMatches($0, needle: needle) }
            guard !matching.isEmpty else { continue }
            if let title = group.title {
                result.append(.header(title))
            }
            result.append(contentsOf: matching.map(Row.section))
        }
        return result
    }

    private static func sectionMatches(_ section: SettingsSection, needle: String) -> Bool {
        if section.title.lowercased().contains(needle) {
            return true
        }
        return section.searchKeywords.contains { $0.contains(needle) }
    }
}

extension SettingsSidebarViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }
}

extension SettingsSidebarViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] {
            return true
        }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .section = rows[row] {
            return true
        }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header:
            return Metrics.headerRowHeight
        case .section:
            return Metrics.sectionRowHeight
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        // Group headers keep the default (non-interactive) row; section rows use
        // a row view with a soft selection + hover hint instead of the accent fill.
        guard case .section = rows[row] else { return nil }
        let identifier = SettingsSidebarTableRowView.reuseIdentifier
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? SettingsSidebarTableRowView {
            return reused
        }
        let rowView = SettingsSidebarTableRowView()
        rowView.identifier = identifier
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .header(title):
            return makeHeaderView(title: title)
        case let .section(section):
            return makeSectionView(section: section)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSynchronizingSelection else { return }
        let row = tableView.selectedRow
        guard row >= 0, case let .section(section) = rows[row] else { return }
        selectedSection = section
        delegate?.settingsSidebar(self, didSelect: section)
    }

    private func makeHeaderView(title: String) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("settings.sidebar.header")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let label = NSTextField(labelWithString: "")
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Metrics.rowLeadingInset),
                    label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3),
                ])
                return cell
            }()
        cell.textField?.stringValue = title
        return cell
    }

    private func makeSectionView(section: SettingsSection) -> NSView {
        let cell = (tableView.makeView(
            withIdentifier: SettingsSidebarRowView.reuseIdentifier,
            owner: self
        ) as? SettingsSidebarRowView) ?? SettingsSidebarRowView()
        cell.configure(with: section)
        return cell
    }
}

extension SettingsSidebarViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_: Notification) {
        applyFilter()
    }
}

/// Sidebar row background in the Raycast style: a soft, rounded gray selection
/// (never the saturated accent fill) plus a faint hover hint on the row under
/// the pointer.
@MainActor
final class SettingsSidebarTableRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("settings.sidebar.rowBackground")

    private enum Metrics {
        /// Padding around the icon badge — equal on the left, top, and bottom.
        static let iconPadding: CGFloat = 4
        static let cornerRadius: CGFloat = 6
    }

    private var isHovered = false {
        didSet {
            if isHovered != oldValue { needsDisplay = true }
        }
    }
    private var hoverTrackingArea: NSTrackingArea?

    // Keep the icon + title using normal (dark) colors when selected, so the
    // title doesn't turn white the way it would on the emphasized accent fill.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in _: NSRect) {
        guard isSelected else { return }
        fillRoundedBackground(with: .unemphasizedSelectedContentBackgroundColor)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isHovered, !isSelected else { return }
        fillRoundedBackground(with: NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.5))
    }

    private func fillRoundedBackground(with color: NSColor) {
        let path = NSBezierPath(
            roundedRect: highlightRect(),
            xRadius: Metrics.cornerRadius,
            yRadius: Metrics.cornerRadius
        )
        color.setFill()
        path.fill()
    }

    /// The rounded highlight. Left and right margins are equal and both match the
    /// sidebar's content gutter (the gap from the sidebar to the main window).
    /// The vertical inset is sized so the icon keeps the same padding above/below.
    private func highlightRect() -> NSRect {
        let gutter = SettingsSidebarViewController.contentHorizontalInset
        let verticalInset = (bounds.height - SettingsSidebarRowView.badgeDiameter) / 2 - Metrics.iconPadding
        return NSRect(
            x: gutter,
            y: bounds.minY + verticalInset,
            width: bounds.width - gutter * 2,
            height: bounds.height - verticalInset * 2
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
    }
}
