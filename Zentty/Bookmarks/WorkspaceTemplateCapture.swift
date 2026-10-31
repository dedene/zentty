import Foundation

enum WorkspaceTemplateCapture {
    typealias ProcessTreeProvider = (Int32) -> TaskManagerProcessTree?

    private static let shellProcessNames: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh",
        "-zsh", "-bash", "-sh", "-fish", "-dash", "-ksh", "-tcsh", "-csh",
        "login",
    ]

    /// Templates do not model floats (v1): persistent floats are captured as
    /// tiles, each in its own column, so a bookmark update never drops a
    /// floated pane and a float-only worklane still yields panes.
    static func capture(
        worklane: WorklaneState,
        kind: WorkspaceTemplate.Kind,
        name: String,
        capturedReadableWidth: Double? = nil,
        processTreeProvider: ProcessTreeProvider? = nil
    ) -> WorkspaceTemplate {
        let makeTemplatePane = { (pane: PaneState) -> WorkspaceTemplate.Pane in
            makePane(
                pane: pane,
                auxiliary: worklane.auxiliaryStateByPaneID[pane.id],
                kind: kind,
                processTreeProvider: processTreeProvider
            )
        }
        var columns = worklane.paneStripState.columns.map { column -> WorkspaceTemplate.Column in
            WorkspaceTemplate.Column(
                id: column.id.rawValue,
                width: Double(column.width),
                focusedPaneID: column.focusedPaneID?.rawValue,
                lastFocusedPaneID: column.lastFocusedPaneID?.rawValue,
                paneHeights: column.paneHeights.map(Double.init),
                panes: column.panes.map(makeTemplatePane)
            )
        }
        let floatColumnIDs = insertFloatColumns(
            from: worklane,
            into: &columns,
            makePane: makeTemplatePane
        )
        let focusedColumnID = worklane.paneStripState.focusedColumnID?.rawValue
            ?? worklane.focusedFloatID.flatMap { floatColumnIDs[$0] }
            ?? columns.first?.id

        let cwds = columns
            .flatMap(\.panes)
            .compactMap(\.workingDirectory)
        let projectRoot = kind == .bookmark ? longestCommonAncestor(of: cwds) : nil

        return WorkspaceTemplate(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            title: WorklaneContextFormatter.trimmed(worklane.title),
            color: worklane.color?.rawValue,
            projectRoot: projectRoot,
            capturedReadableWidth: capturedReadableWidth,
            nextPaneNumber: worklane.nextPaneNumber,
            focusedColumnID: focusedColumnID,
            columns: columns
        )
    }

    /// Adds each persistent float to `columns` as a one-pane column: at its
    /// `FloatOrigin` index when known (newest first, so floats lifted from
    /// the same index come back in their old strip order), else at the end
    /// in creation order. Returns the column ID given to each float.
    private static func insertFloatColumns(
        from worklane: WorklaneState,
        into columns: inout [WorkspaceTemplate.Column],
        makePane: (PaneState) -> WorkspaceTemplate.Pane
    ) -> [PaneID: String] {
        let floats = FloatingPaneState.bySequence(worklane.floatingPanes)
            .filter { worklane.isPersistent($0.pane.id) }
        var usedIDs = Set(columns.map(\.id))
        var columnIDByPaneID: [PaneID: String] = [:]
        func makeColumn(_ float: FloatingPaneState) -> WorkspaceTemplate.Column {
            var id = "float-\(float.pane.id.rawValue)"
            var suffix = 2
            while !usedIDs.insert(id).inserted {
                id = "float-\(float.pane.id.rawValue)-\(suffix)"
                suffix += 1
            }
            columnIDByPaneID[float.pane.id] = id
            return WorkspaceTemplate.Column(
                id: id,
                width: Double(float.pane.width),
                focusedPaneID: float.pane.id.rawValue,
                lastFocusedPaneID: float.pane.id.rawValue,
                paneHeights: [],
                panes: [makePane(float.pane)]
            )
        }
        for float in floats.reversed() {
            guard let columnIndex = float.origin?.columnIndex else {
                continue
            }
            columns.insert(makeColumn(float), at: min(max(columnIndex, 0), columns.count))
        }
        for float in floats where float.origin == nil {
            columns.append(makeColumn(float))
        }
        return columnIDByPaneID
    }

    static func bookmarkWorkingDirectory(
        pane: PaneState,
        auxiliary: PaneAuxiliaryState?
    ) -> String? {
        let terminalLocation = PaneTerminalLocationResolver.snapshot(
            metadata: auxiliary?.metadata,
            shellContext: auxiliary?.shellContext,
            requestWorkingDirectory: pane.sessionRequest.inheritFromPaneID == nil
                ? trimmed(pane.sessionRequest.workingDirectory)
                : nil
        )
        guard terminalLocation.scope != .remote else {
            return nil
        }
        return trimmed(terminalLocation.workingDirectory)
            ?? trimmed(auxiliary?.presentation.cwd)
            ?? trimmed(pane.sessionRequest.workingDirectory)
    }

    private static func makePane(
        pane: PaneState,
        auxiliary: PaneAuxiliaryState?,
        kind: WorkspaceTemplate.Kind,
        processTreeProvider: ProcessTreeProvider?
    ) -> WorkspaceTemplate.Pane {
        let workingDirectory: String? = kind == .bookmark
            ? bookmarkWorkingDirectory(pane: pane, auxiliary: auxiliary)
            : nil

        return WorkspaceTemplate.Pane(
            id: pane.id.rawValue,
            customTitle: trimmed(pane.customTitle),
            titleSeed: trimmed(auxiliary?.presentation.rememberedTitle) ?? trimmed(pane.title),
            workingDirectory: workingDirectory,
            command: detectedCommand(auxiliary: auxiliary, processTreeProvider: processTreeProvider),
            environment: WorklaneSessionEnvironment.templateSafeOverrides(
                from: pane.sessionRequest.environmentVariables
            ),
            wasUserEdited: false
        )
    }

    private static func detectedCommand(
        auxiliary: PaneAuxiliaryState?,
        processTreeProvider: ProcessTreeProvider?
    ) -> String? {
        let processName = trimmed(auxiliary?.metadata?.processName)
        if let processName, !isShellProcessName(processName) {
            return processName
        }

        guard auxiliary?.shellActivityState == .commandRunning else {
            return nil
        }

        return runningCommandTitle(auxiliary: auxiliary)
            ?? runningChildProcessName(auxiliary: auxiliary, processTreeProvider: processTreeProvider)
    }

    private static func runningCommandTitle(auxiliary: PaneAuxiliaryState?) -> String? {
        guard let title = trimmed(auxiliary?.metadata?.title),
              !isShellProcessName(title),
              title != trimmed(auxiliary?.metadata?.currentWorkingDirectory)
        else {
            return nil
        }
        return title
    }

    private static func runningChildProcessName(
        auxiliary: PaneAuxiliaryState?,
        processTreeProvider: ProcessTreeProvider?
    ) -> String? {
        guard let rootPID = auxiliary?.raw.paneRootPID,
              let processTree = processTreeProvider?(rootPID) else {
            return nil
        }

        let descendants = processTree.processes
            .filter { $0.pid != rootPID && !isShellProcessName($0.name) }
            .sorted { $0.pid < $1.pid }

        return descendants.first { $0.parentPID == rootPID }?.name
            ?? descendants.first?.name
    }

    private static func isShellProcessName(_ value: String) -> Bool {
        shellProcessNames.contains(value.lowercased())
    }

    static func longestCommonAncestor(of paths: [String]) -> String? {
        let normalized = paths
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { !$0.isEmpty }
        guard let first = normalized.first else {
            return nil
        }
        if normalized.count == 1 {
            return first
        }

        let firstComponents = pathComponents(first)
        var commonPrefixLength = firstComponents.count
        for path in normalized.dropFirst() {
            let components = pathComponents(path)
            commonPrefixLength = min(commonPrefixLength, components.count)
            var matched = 0
            while matched < commonPrefixLength && firstComponents[matched] == components[matched] {
                matched += 1
            }
            commonPrefixLength = matched
            if commonPrefixLength == 0 {
                return nil
            }
        }

        guard commonPrefixLength > 0 else {
            return nil
        }
        let prefix = Array(firstComponents.prefix(commonPrefixLength))
        let joined = "/" + prefix.joined(separator: "/")
        return joined.isEmpty ? "/" : joined
    }

    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
