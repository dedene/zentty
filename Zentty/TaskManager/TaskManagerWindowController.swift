import AppKit

@MainActor
final class TaskManagerWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    typealias PaneSourcesProvider = () -> [TaskManagerPaneSource]
    typealias FocusPaneHandler = (WindowID, WorklaneID, PaneID) -> Void
    typealias ClosePaneHandler = (WindowID, PaneID) -> Void

    private enum Column: String, CaseIterable {
        case pane
        case status
        case cpu
        case memory
        case network
        case hottestProcess
        case rootPID

        var title: String {
            switch self {
            case .pane: "Pane"
            case .status: "Status"
            case .cpu: "CPU"
            case .memory: "Memory"
            case .network: "Network"
            case .hottestProcess: "Hottest Process"
            case .rootPID: "Root PID"
            }
        }

        var width: CGFloat {
            switch self {
            case .pane: 210
            case .status: 120
            case .cpu: 82
            case .memory: 100
            case .network: 90
            case .hottestProcess: 150
            case .rootPID: 78
            }
        }
    }

    private enum Node {
        case pane(TaskManagerPaneRow)
        case process(TaskManagerProcessRow, parent: TaskManagerPaneRow)
    }

    private enum SelectionID: Hashable {
        case pane(PaneID)
        case process(parentPaneID: PaneID, pid: Int32)
    }

    private let paneSourcesProvider: PaneSourcesProvider
    private let focusPaneHandler: FocusPaneHandler
    private let closePaneHandler: ClosePaneHandler
    private let sampler = TaskManagerProcessSampler()

    private let searchField = NSSearchField(frame: .zero)
    private let outlineView = NSOutlineView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let focusButton = NSButton(title: "Focus Pane", target: nil, action: nil)
    private let copyPIDButton = NSButton(title: "Copy PID", target: nil, action: nil)
    private let endTaskButton = NSButton(title: "End Task", target: nil, action: nil)

    private var currentAppearance: NSAppearance?
    private var currentTheme: ZenttyTheme
    private var tableBackgroundColor = NSColor.controlBackgroundColor
    private var timer: Timer?
    private var query = ""
    private var rows: [TaskManagerPaneRow] = []
    private var visibleRows: [TaskManagerPaneRow] = []
    private var previousOrder: [PaneID] = []
    private var previousRowsByPaneID: [PaneID: TaskManagerPaneRow] = [:]
    private var expandedPaneIDs: Set<PaneID> = []
    private var isRestoringExpansion = false

    init(
        paneSourcesProvider: @escaping PaneSourcesProvider,
        focusPaneHandler: @escaping FocusPaneHandler,
        closePaneHandler: @escaping ClosePaneHandler,
        appearance: NSAppearance? = nil,
        theme: ZenttyTheme = ZenttyTheme.fallback(for: nil)
    ) {
        self.paneSourcesProvider = paneSourcesProvider
        self.focusPaneHandler = focusPaneHandler
        self.closePaneHandler = closePaneHandler
        self.currentTheme = theme
        self.currentAppearance = appearance ?? Self.appearance(for: theme)

        let window = TaskManagerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Task Manager"
        window.minSize = NSSize(width: 880, height: 420)
        super.init(window: window)
        window.delegate = self
        buildContent()
        applyAppearance(currentAppearance)
        applyTheme(theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(sender: Any?) {
        refresh()
        showWindow(sender)
        window?.center()
        startTimer()
    }

    func applyAppearance(_ appearance: NSAppearance?) {
        let resolvedAppearance = appearance ?? Self.appearance(for: currentTheme)
        currentAppearance = resolvedAppearance
        window?.appearance = resolvedAppearance
        window?.contentView?.appearance = resolvedAppearance
        searchField.appearance = resolvedAppearance
        focusButton.appearance = resolvedAppearance
        copyPIDButton.appearance = resolvedAppearance
        endTaskButton.appearance = resolvedAppearance
        scrollView.appearance = resolvedAppearance
        outlineView.appearance = resolvedAppearance
        outlineView.headerView?.appearance = resolvedAppearance
    }

    func applyTheme(_ theme: ZenttyTheme) {
        currentTheme = theme
        tableBackgroundColor = Self.tableBackgroundColor(for: theme)

        applyAppearance(Self.appearance(for: theme))

        window?.backgroundColor = theme.windowBackground
        if let contentView = window?.contentView {
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = theme.windowBackground.cgColor
        }
        scrollView.drawsBackground = true
        scrollView.backgroundColor = tableBackgroundColor
        outlineView.backgroundColor = tableBackgroundColor
        outlineView.gridColor = theme.contextStripBorder
        outlineView.reloadData()
    }

    func windowWillClose(_ notification: Notification) {
        stopTimer()
        expandedPaneIDs.removeAll()
    }

    func controlTextDidChange(_ notification: Notification) {
        query = searchField.stringValue
        applyFilterAndReload()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else {
            return visibleRows.count
        }

        switch node {
        case .pane(let row):
            return row.processRows.count
        case .process:
            return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else {
            return Node.pane(visibleRows[index])
        }

        switch node {
        case .pane(let row):
            return Node.process(row.processRows[index], parent: row)
        case .process:
            return Node.pane(visibleRows[index])
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard case .pane(let row) = item as? Node else {
            return false
        }
        return !row.processRows.isEmpty
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let column = tableColumn.flatMap({ Column(rawValue: $0.identifier.rawValue) }),
              let node = item as? Node else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("TaskManagerCell-\(column.rawValue)")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        cell.textField?.stringValue = text(for: node, column: column)
        cell.textField?.alignment = [.cpu, .memory, .network, .rootPID].contains(column) ? .right : .left
        cell.textField?.textColor = color(for: node, column: column)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        if !isRestoringExpansion,
           let node = item as? Node,
           case .pane(let row) = node {
            expandedPaneIDs.insert(row.paneID)
        }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        if !isRestoringExpansion,
           let node = item as? Node,
           case .pane(let row) = node {
            expandedPaneIDs.remove(row.paneID)
        }
        return true
    }

    @objc
    private func focusSelectedPane(_ sender: Any?) {
        guard let row = selectedPaneRow() else { return }
        focusPaneHandler(row.windowID, row.worklaneID, row.paneID)
    }

    @objc
    private func copySelectedPID(_ sender: Any?) {
        guard let pid = selectedPID() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(pid), forType: .string)
    }

    @objc
    private func endSelectedTask(_ sender: Any?) {
        guard let row = selectedPaneRow() else { return }
        closePaneHandler(row.windowID, row.paneID)
        refresh()
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        searchField.placeholderString = "Search"
        searchField.delegate = self

        for button in [focusButton, copyPIDButton, endTaskButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        focusButton.action = #selector(focusSelectedPane(_:))
        copyPIDButton.action = #selector(copySelectedPID(_:))
        endTaskButton.action = #selector(endSelectedTask(_:))

        let toolbar = NSStackView(views: [searchField, focusButton, copyPIDButton, endTaskButton])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.documentView = outlineView

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.allowsEmptySelection = true
        outlineView.rowSizeStyle = .medium
        outlineView.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 24))

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = min(70, column.width)
            tableColumn.headerCell.alignment = [.cpu, .memory, .network, .rootPID].contains(column) ? .right : .left
            outlineView.addTableColumn(tableColumn)
            if column == .pane {
                outlineView.outlineTableColumn = tableColumn
            }
        }

        let rootStack = NSStackView(views: [toolbar, scrollView])
        rootStack.orientation = .vertical
        rootStack.alignment = .width
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        updateButtons()
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView(frame: .zero)
        cell.identifier = identifier
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        TaskManagerTableRowView(theme: currentTheme)
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let paneSources = paneSourcesProvider()
        // Sample every pane's tree in one pass so the sampler can keep per-pane CPU
        // history; sampling trees one at a time wipes siblings' history each tick.
        let treesByRootPID = sampler.sample(rootPIDs: paneSources.compactMap(\.rootPID))
        rows = paneSources.map { pane in
            let processTree = pane.rootPID.flatMap { treesByRootPID[$0] }
            return TaskManagerPaneRowBuilder.row(
                for: pane,
                processTree: processTree,
                previousRow: previousRowsByPaneID[pane.paneID]
            )
        }
        applyFilterAndReload()
    }

    private func applyFilterAndReload() {
        syncExpandedPaneIDsFromOutlineView()
        let selectedID = selectedNodeID()
        let filteredRows = TaskManagerRowFilter.filter(rows, query: query)
        visibleRows = TaskManagerStableSorter.sort(filteredRows, previousOrder: previousOrder)
        previousOrder = visibleRows.map(\.paneID)
        previousRowsByPaneID = Dictionary(uniqueKeysWithValues: rows.map { ($0.paneID, $0) })
        isRestoringExpansion = true
        outlineView.reloadData()
        restoreExpandedPaneIDs()
        restoreSelection(selectedID)
        isRestoringExpansion = false
        updateButtons()
    }

    private func syncExpandedPaneIDsFromOutlineView() {
        guard outlineView.numberOfRows > 0 else { return }

        for rowIndex in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: rowIndex),
                  let node = item as? Node,
                  case .pane(let row) = node else {
                continue
            }

            if outlineView.isItemExpanded(item) {
                expandedPaneIDs.insert(row.paneID)
            } else {
                expandedPaneIDs.remove(row.paneID)
            }
        }
    }

    private func restoreExpandedPaneIDs() {
        guard !expandedPaneIDs.isEmpty else { return }

        var rowIndex = 0
        while rowIndex < outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: rowIndex),
                  let node = item as? Node,
                  case .pane(let row) = node else {
                rowIndex += 1
                continue
            }

            if expandedPaneIDs.contains(row.paneID) {
                outlineView.expandItem(item)
                rowIndex += row.processRows.count + 1
            } else {
                rowIndex += 1
            }
        }
    }

    private func selectedNodeID() -> SelectionID? {
        guard outlineView.selectedRow >= 0,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? Node else {
            return nil
        }

        return selectionID(for: node)
    }

    private func restoreSelection(_ selectedID: SelectionID?) {
        guard let selectedID else { return }

        for rowIndex in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: rowIndex) as? Node,
                  selectionID(for: node) == selectedID else {
                continue
            }

            outlineView.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
            return
        }
    }

    private func selectionID(for node: Node) -> SelectionID {
        switch node {
        case .pane(let row):
            return .pane(row.paneID)
        case .process(let process, let parent):
            return .process(parentPaneID: parent.paneID, pid: process.pid)
        }
    }

    private func selectedPaneRow() -> TaskManagerPaneRow? {
        guard outlineView.selectedRow >= 0,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? Node else {
            return nil
        }

        switch node {
        case .pane(let row):
            return row
        case .process(_, let parent):
            return parent
        }
    }

    private func selectedPID() -> Int32? {
        guard outlineView.selectedRow >= 0,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? Node else {
            return nil
        }

        switch node {
        case .pane(let row):
            return row.rootPID
        case .process(let process, _):
            return process.pid
        }
    }

    private func updateButtons() {
        let hasPane = selectedPaneRow() != nil
        focusButton.isEnabled = hasPane
        endTaskButton.isEnabled = hasPane
        copyPIDButton.isEnabled = selectedPID() != nil
    }

    private func text(for node: Node, column: Column) -> String {
        switch node {
        case .pane(let row):
            return text(for: row, column: column)
        case .process(let process, let parent):
            return text(for: process, parent: parent, column: column)
        }
    }

    private func text(for row: TaskManagerPaneRow, column: Column) -> String {
        switch column {
        case .pane:
            return row.paneTitle
        case .status:
            switch row.availability {
            case .available:
                return row.statusText ?? ""
            case .unavailable(let reason):
                return reason
            }
        case .cpu:
            return TaskManagerMetricFormatter.cpu(row.cpuPercent)
        case .memory:
            return TaskManagerMetricFormatter.memory(row.memoryBytes)
        case .network:
            return TaskManagerMetricFormatter.network(row.networkState)
        case .hottestProcess:
            return row.hottestProcess?.name ?? ""
        case .rootPID:
            return row.rootPID.map(String.init) ?? "-"
        }
    }

    private func text(for process: TaskManagerProcessRow, parent: TaskManagerPaneRow, column: Column) -> String {
        switch column {
        case .pane:
            return process.name
        case .status:
            return "PID \(process.pid)"
        case .cpu:
            return TaskManagerMetricFormatter.cpu(process.cpuPercent)
        case .memory:
            return TaskManagerMetricFormatter.memory(process.memoryBytes)
        case .network:
            return "-"
        case .hottestProcess:
            return ""
        case .rootPID:
            return String(process.pid)
        }
    }

    private func color(for node: Node, column: Column) -> NSColor {
        guard column == .cpu || column == .memory else {
            return currentTheme.primaryText
        }

        let cpu: Double
        switch node {
        case .pane(let row):
            cpu = row.cpuPercent ?? 0
        case .process(let process, _):
            cpu = process.cpuPercent
        }

        if column == .cpu, cpu >= 100 {
            return currentTheme.statusStopped
        }
        if column == .cpu, cpu >= 25 {
            return currentTheme.statusNeedsInput
        }
        return currentTheme.primaryText
    }

    private static func appearance(for theme: ZenttyTheme) -> NSAppearance? {
        NSAppearance(named: theme.windowBackground.isDarkThemeColor ? .darkAqua : .aqua)
    }

    private static func tableBackgroundColor(for theme: ZenttyTheme) -> NSColor {
        let mixTarget: NSColor = theme.windowBackground.isDarkThemeColor ? .black : .white
        return theme.windowBackground
            .mixed(towards: mixTarget, amount: theme.windowBackground.isDarkThemeColor ? 0.10 : 0.16)
            .withAlphaComponent(1)
    }
}

private final class TaskManagerTableRowView: NSTableRowView {
    private let theme: ZenttyTheme

    init(theme: ZenttyTheme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let base = TaskManagerTableRowView.backgroundColor(
            for: theme,
            isEmphasized: isEmphasized,
            isSelected: isSelected
        )
        base.setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        drawBackground(in: dirtyRect)
    }

    private static func backgroundColor(
        for theme: ZenttyTheme,
        isEmphasized: Bool,
        isSelected: Bool
    ) -> NSColor {
        if isSelected {
            let amount: CGFloat = isEmphasized ? 0.36 : 0.24
            return theme.windowBackground
                .mixed(towards: theme.openWithChromePrimaryTint, amount: amount)
                .withAlphaComponent(1)
        }
        return NSColor.clear
    }
}

private final class TaskManagerWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}

extension TaskManagerWindowController {
    var tableBackgroundColorForTesting: NSColor {
        tableBackgroundColor
    }
}
