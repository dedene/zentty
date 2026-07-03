import Foundation

struct WorkspaceTemplate: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Equatable, Sendable {
        case bookmark
        case preset
    }

    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var name: String
    var kind: Kind
    var title: String?
    var color: String?
    var projectRoot: String?
    var capturedReadableWidth: Double?
    var nextPaneNumber: Int
    var focusedColumnID: String?
    var columns: [Column]
    var pinned: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?

    init(
        schemaVersion: Int = WorkspaceTemplate.currentSchemaVersion,
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        title: String? = nil,
        color: String? = nil,
        projectRoot: String? = nil,
        capturedReadableWidth: Double? = nil,
        nextPaneNumber: Int = 1,
        focusedColumnID: String? = nil,
        columns: [Column] = [],
        pinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.kind = kind
        self.title = title
        self.color = color
        self.projectRoot = projectRoot
        self.capturedReadableWidth = capturedReadableWidth
        self.nextPaneNumber = nextPaneNumber
        self.focusedColumnID = focusedColumnID
        self.columns = columns
        self.pinned = pinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
    }

    struct Column: Codable, Equatable, Sendable {
        var id: String
        var width: Double
        var focusedPaneID: String?
        var lastFocusedPaneID: String?
        var paneHeights: [Double]
        var panes: [Pane]
    }

    struct Pane: Codable, Equatable, Sendable {
        var id: String
        var titleSeed: String?
        var workingDirectory: String?
        var command: String?
        var environment: [String: String]
        var wasUserEdited: Bool

        init(
            id: String,
            titleSeed: String? = nil,
            workingDirectory: String? = nil,
            command: String? = nil,
            environment: [String: String] = [:],
            wasUserEdited: Bool = false
        ) {
            self.id = id
            self.titleSeed = titleSeed
            self.workingDirectory = workingDirectory
            self.command = command
            self.environment = environment
            self.wasUserEdited = wasUserEdited
        }
    }

    var paneCount: Int {
        columns.reduce(0) { $0 + $1.panes.count }
    }

    var allPanes: [Pane] {
        columns.flatMap(\.panes)
    }

    func strippingWorkingDirectories() -> WorkspaceTemplate {
        var copy = self
        copy.kind = .preset
        copy.projectRoot = nil
        copy.columns = copy.columns.map { column in
            var column = column
            column.panes = column.panes.map { pane in
                var pane = pane
                pane.workingDirectory = nil
                return pane
            }
            return column
        }
        copy.updatedAt = Date()
        return copy
    }

    func strippingUnsafeEnvironment() -> WorkspaceTemplate {
        var copy = self
        copy.columns = copy.columns.map { column in
            var column = column
            column.panes = column.panes.map { pane in
                var pane = pane
                pane.environment = WorklaneSessionEnvironment.templateSafeOverrides(from: pane.environment)
                return pane
            }
            return column
        }
        copy.updatedAt = Date()
        return copy
    }
}

struct WorkspaceTemplateBundle: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var savedAt: Date
    var templates: [WorkspaceTemplate]

    init(
        schemaVersion: Int = WorkspaceTemplateBundle.currentSchemaVersion,
        savedAt: Date = Date(),
        templates: [WorkspaceTemplate] = []
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.templates = templates
    }
}
