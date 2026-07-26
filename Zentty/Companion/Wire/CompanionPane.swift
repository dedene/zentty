import Foundation

// MARK: - pane.*

/// `pane.watch` (phone → mac).
struct CompanionPaneWatch: CompanionMessagePayload {
    static let messageType = "pane.watch"

    var paneId: String
}

/// `pane.unwatch` (phone → mac).
struct CompanionPaneUnwatch: CompanionMessagePayload {
    static let messageType = "pane.unwatch"

    var paneId: String
}

/// `pane.text` (mac → phone) — full viewport text per debounced change.
struct CompanionPaneText: CompanionMessagePayload {
    static let messageType = "pane.text"

    var paneId: String
    var seq: Int
    var viewport: String
    var cursorRow: Int?
    var gridCols: Int
    var gridRows: Int
    var truncatedScrollback: Bool
}

/// `pane.scrollback` — a request/reply pair sharing one `type`. The request half
/// carries `lineLimit`; the reply half carries `text`. At least one must be
/// present.
struct CompanionPaneScrollback: CompanionMessagePayload {
    static let messageType = "pane.scrollback"

    var paneId: String
    var lineLimit: Int?
    var text: String?

    private enum CodingKeys: String, CodingKey {
        case paneId
        case lineLimit
        case text
    }

    init(paneId: String, lineLimit: Int? = nil, text: String? = nil) {
        self.paneId = paneId
        self.lineLimit = lineLimit
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneId = try container.decode(String.self, forKey: .paneId)
        lineLimit = try container.decodeIfPresent(Int.self, forKey: .lineLimit)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        guard lineLimit != nil || text != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .paneId,
                in: container,
                debugDescription: "pane.scrollback requires lineLimit (request) or text (reply)"
            )
        }
    }
}
