import AppKit

@MainActor
final class LicensesWindowController: NSWindowController {
    private enum Layout {
        static let windowSize = NSSize(width: 760, height: 540)
    }

    private let licensesViewController: LicensesViewController

    init(
        catalog: ThirdPartyLicenseCatalog? = nil,
        appearance: NSAppearance? = nil,
        urlOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        let resolvedCatalog: ThirdPartyLicenseCatalog
        if let catalog {
            resolvedCatalog = catalog
        } else {
            do {
                resolvedCatalog = try ThirdPartyLicenseCatalog.load(from: .main)
            } catch {
                assertionFailure("Failed to load bundled third-party licenses: \(error)")
                resolvedCatalog = Self.unavailableCatalog(message: error.localizedDescription)
            }
        }
        let licensesViewController = LicensesViewController(catalog: resolvedCatalog, urlOpener: urlOpener)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Layout.windowSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Third-Party Licenses"
        window.isReleasedWhenClosed = false
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .automatic
        window.backgroundColor = .windowBackgroundColor
        window.appearance = appearance
        window.center()
        window.contentViewController = licensesViewController
        window.setContentSize(Layout.windowSize)
        window.contentMinSize = NSSize(width: 620, height: 420)

        self.licensesViewController = licensesViewController
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(sender: Any?) {
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applyAppearance(_ appearance: NSAppearance?) {
        window?.appearance = appearance
        licensesViewController.view.appearance = appearance
    }

    var entryCountForTesting: Int { licensesViewController.entryCountForTesting }
    var selectedEntryDisplayNameForTesting: String? {
        licensesViewController.selectedEntryDisplayNameForTesting
    }
    var selectedEntryLicenseNameForTesting: String? {
        licensesViewController.selectedEntryLicenseNameForTesting
    }
    var detailTextForTesting: String { licensesViewController.detailTextForTesting }
    var contentTopInsetForTesting: CGFloat { licensesViewController.contentTopInsetForTesting }
    var rowSelectionHorizontalInsetForTesting: CGFloat {
        licensesViewController.rowSelectionHorizontalInsetForTesting
    }
    var rowLabelHorizontalInsetForTesting: CGFloat { licensesViewController.rowLabelHorizontalInsetForTesting }

    func selectEntryForTesting(id: String) {
        licensesViewController.selectEntryForTesting(id: id)
    }

    private static func unavailableCatalog(message: String) -> ThirdPartyLicenseCatalog {
        ThirdPartyLicenseCatalog(entries: [
            ThirdPartyLicenseEntry(
                id: "licenses-unavailable",
                displayName: "License data unavailable",
                version: "Unavailable",
                licenseName: "Bundled data missing",
                spdxID: nil,
                sourceURLString: "https://github.com/dedene/zentty",
                homepageURLString: nil,
                fullText: """
                Zentty could not load its bundled third-party license catalog.

                Error: \(message)
                """
            ),
        ])
    }
}

@MainActor
private final class LicensesViewController: NSViewController {
    private enum Layout {
        static let sidebarWidth: CGFloat = 220
        static let topInset: CGFloat = 10
        static let horizontalInset: CGFloat = 18
        static let bottomInset: CGFloat = 18
        static let rowHeight: CGFloat = 34
        static let infoSpacing: CGFloat = 8
        static let rowSelectionHorizontalInset: CGFloat = 6
        static let rowSelectionVerticalInset: CGFloat = 2
        static let rowLabelHorizontalInset: CGFloat = 8
    }

    private let catalog: ThirdPartyLicenseCatalog
    private let urlOpener: (URL) -> Void

    private let tableScrollView = NSScrollView()
    private let tableView = NSTableView()
    private let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("licenseEntry"))
    private let emptyStateLabel = NSTextField(
        wrappingLabelWithString: "No bundled third-party licenses were found."
    )
    private let titleLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let licenseLabel = NSTextField(labelWithString: "")
    private let sourceButton = NSButton(title: "", target: nil, action: nil)
    private let homepageButton = NSButton(title: "", target: nil, action: nil)
    private let textScrollView = NSScrollView()
    private let textView = NSTextView()

    private var selectedEntry: ThirdPartyLicenseEntry? {
        didSet {
            updateDetail()
        }
    }

    init(catalog: ThirdPartyLicenseCatalog, urlOpener: @escaping (URL) -> Void) {
        self.catalog = catalog
        self.urlOpener = urlOpener
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = NSView()
        rootView.translatesAutoresizingMaskIntoConstraints = false

        let shellView = NSView()
        shellView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(shellView)

        let leftColumn = NSView()
        leftColumn.translatesAutoresizingMaskIntoConstraints = false
        shellView.addSubview(leftColumn)

        configureTableView()
        leftColumn.addSubview(tableScrollView)
        leftColumn.addSubview(emptyStateLabel)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        shellView.addSubview(divider)

        let rightColumn = NSView()
        rightColumn.translatesAutoresizingMaskIntoConstraints = false
        shellView.addSubview(rightColumn)

        let headerStack = NSStackView()
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = Layout.infoSpacing
        rightColumn.addSubview(headerStack)

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        headerStack.addArrangedSubview(titleLabel)

        versionLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        versionLabel.textColor = .secondaryLabelColor
        headerStack.addArrangedSubview(versionLabel)

        licenseLabel.font = .systemFont(ofSize: 13, weight: .medium)
        licenseLabel.textColor = .secondaryLabelColor
        headerStack.addArrangedSubview(licenseLabel)

        let linksStack = NSStackView(views: [sourceButton, homepageButton])
        linksStack.translatesAutoresizingMaskIntoConstraints = false
        linksStack.orientation = .horizontal
        linksStack.alignment = .centerY
        linksStack.spacing = 10
        rightColumn.addSubview(linksStack)

        configureLinkButton(sourceButton, title: "Open Source")
        configureLinkButton(homepageButton, title: "Homepage")

        configureTextView()
        rightColumn.addSubview(textScrollView)

        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.maximumNumberOfLines = 0
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.isHidden = !catalog.entries.isEmpty

        NSLayoutConstraint.activate([
            shellView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: Layout.topInset),
            shellView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: Layout.horizontalInset),
            shellView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -Layout.horizontalInset),
            shellView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -Layout.bottomInset),

            leftColumn.topAnchor.constraint(equalTo: shellView.topAnchor),
            leftColumn.leadingAnchor.constraint(equalTo: shellView.leadingAnchor),
            leftColumn.bottomAnchor.constraint(equalTo: shellView.bottomAnchor),
            leftColumn.widthAnchor.constraint(equalToConstant: Layout.sidebarWidth),

            tableScrollView.topAnchor.constraint(equalTo: leftColumn.topAnchor),
            tableScrollView.leadingAnchor.constraint(equalTo: leftColumn.leadingAnchor),
            tableScrollView.trailingAnchor.constraint(equalTo: leftColumn.trailingAnchor),
            tableScrollView.bottomAnchor.constraint(equalTo: leftColumn.bottomAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: leftColumn.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: leftColumn.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(equalTo: leftColumn.leadingAnchor, constant: 16),
            emptyStateLabel.trailingAnchor.constraint(equalTo: leftColumn.trailingAnchor, constant: -16),

            divider.topAnchor.constraint(equalTo: shellView.topAnchor),
            divider.leadingAnchor.constraint(equalTo: leftColumn.trailingAnchor, constant: 16),
            divider.bottomAnchor.constraint(equalTo: shellView.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            rightColumn.topAnchor.constraint(equalTo: shellView.topAnchor),
            rightColumn.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 16),
            rightColumn.trailingAnchor.constraint(equalTo: shellView.trailingAnchor),
            rightColumn.bottomAnchor.constraint(equalTo: shellView.bottomAnchor),

            headerStack.topAnchor.constraint(equalTo: rightColumn.topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: rightColumn.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: rightColumn.trailingAnchor),

            linksStack.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            linksStack.leadingAnchor.constraint(equalTo: rightColumn.leadingAnchor),
            linksStack.trailingAnchor.constraint(lessThanOrEqualTo: rightColumn.trailingAnchor),

            textScrollView.topAnchor.constraint(equalTo: linksStack.bottomAnchor, constant: 14),
            textScrollView.leadingAnchor.constraint(equalTo: rightColumn.leadingAnchor),
            textScrollView.trailingAnchor.constraint(equalTo: rightColumn.trailingAnchor),
            textScrollView.bottomAnchor.constraint(equalTo: rightColumn.bottomAnchor),
        ])

        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.reloadData()
        selectInitialEntryIfNeeded()
    }

    private func configureTableView() {
        tableColumn.title = "Component"
        tableColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(tableColumn)
        tableView.headerView = nil
        tableView.rowHeight = Layout.rowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.focusRingType = .none
        tableView.delegate = self
        tableView.dataSource = self

        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableScrollView.hasVerticalScroller = true
        tableScrollView.autohidesScrollers = true
        tableScrollView.borderType = .noBorder
        tableScrollView.documentView = tableView
    }

    private func configureLinkButton(_ button: NSButton, title: String) {
        button.title = title
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = self
        button.action = #selector(handleLinkButton(_:))
    }

    private func configureTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 0, height: 8)

        textScrollView.translatesAutoresizingMaskIntoConstraints = false
        textScrollView.hasVerticalScroller = true
        textScrollView.borderType = .bezelBorder
        textScrollView.documentView = textView
    }

    private func selectInitialEntryIfNeeded() {
        guard selectedEntry == nil, catalog.entries.isEmpty == false else {
            updateDetail()
            return
        }

        selectEntry(at: 0)
    }

    private func selectEntry(at row: Int) {
        guard catalog.entries.indices.contains(row) else {
            tableView.deselectAll(nil)
            selectedEntry = nil
            return
        }

        let indexSet = IndexSet(integer: row)
        tableView.selectRowIndexes(indexSet, byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        selectedEntry = catalog.entries[row]
    }

    private func updateDetail() {
        guard let selectedEntry else {
            titleLabel.stringValue = "Third-Party Licenses"
            versionLabel.stringValue = catalog.entries.isEmpty ? "No entries bundled" : "Select a component"
            licenseLabel.stringValue = ""
            sourceButton.isHidden = true
            homepageButton.isHidden = true
            textView.string = ""
            return
        }

        titleLabel.stringValue = selectedEntry.displayName
        versionLabel.stringValue = "Version \(selectedEntry.version)"

        if let spdxID = selectedEntry.spdxID, spdxID.isEmpty == false {
            licenseLabel.stringValue = "\(selectedEntry.licenseName) (\(spdxID))"
        } else {
            licenseLabel.stringValue = selectedEntry.licenseName
        }

        sourceButton.isHidden = selectedEntry.sourceURL == nil
        homepageButton.isHidden = selectedEntry.homepageURL == nil
        textView.string = selectedEntry.fullText
    }

    @objc
    private func handleLinkButton(_ sender: NSButton) {
        guard let selectedEntry else {
            return
        }

        let url: URL?
        if sender === sourceButton {
            url = selectedEntry.sourceURL
        } else if sender === homepageButton {
            url = selectedEntry.homepageURL
        } else {
            url = nil
        }

        guard let url else {
            return
        }

        urlOpener(url)
    }

    var entryCountForTesting: Int { catalog.entries.count }
    var selectedEntryDisplayNameForTesting: String? { selectedEntry?.displayName }
    var selectedEntryLicenseNameForTesting: String? { selectedEntry?.licenseName }
    var detailTextForTesting: String { textView.string }
    var contentTopInsetForTesting: CGFloat { Layout.topInset }
    var rowSelectionHorizontalInsetForTesting: CGFloat { Layout.rowSelectionHorizontalInset }
    var rowLabelHorizontalInsetForTesting: CGFloat { Layout.rowLabelHorizontalInset }

    func selectEntryForTesting(id: String) {
        guard let row = catalog.entries.firstIndex(where: { $0.id == id }) else {
            return
        }

        selectEntry(at: row)
    }
}

@MainActor
extension LicensesViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        catalog.entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("LicenseEntryCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCellView(identifier: identifier)

        cell.textField?.stringValue = catalog.entries[row].displayName
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("LicenseEntryRow")
        let rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? LicenseRowView
            ?? LicenseRowView(
                identifier: identifier,
                horizontalInset: Layout.rowSelectionHorizontalInset,
                verticalInset: Layout.rowSelectionVerticalInset
            )
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0 {
            selectedEntry = catalog.entries[row]
        } else {
            selectedEntry = nil
        }
    }

    private func makeCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        cell.textField = label
        cell.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Layout.rowLabelHorizontalInset),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Layout.rowLabelHorizontalInset),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }
}

private final class LicenseRowView: NSTableRowView {
    private let horizontalInset: CGFloat
    private let verticalInset: CGFloat

    init(identifier: NSUserInterfaceItemIdentifier, horizontalInset: CGFloat, verticalInset: CGFloat) {
        self.horizontalInset = horizontalInset
        self.verticalInset = verticalInset
        super.init(frame: .zero)
        self.identifier = identifier
        selectionHighlightStyle = .regular
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let selectionRect = bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        let path = NSBezierPath(roundedRect: selectionRect, xRadius: 8, yRadius: 8)
        let fillColor = isEmphasized ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor.withAlphaComponent(0.35)
        fillColor.setFill()
        path.fill()
    }
}
