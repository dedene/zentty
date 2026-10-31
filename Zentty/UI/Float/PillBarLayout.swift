import CoreGraphics
import Foundation

/// One minimized float as the pill bar shows it.
struct PillBarItem: Equatable {
    let paneID: PaneID
    let name: String
    /// Muted short cwd (last path component, `~`, or the remote host).
    let subtitle: String?
    let attention: WorklaneAttentionState?

    /// Status word for VoiceOver and the overflow menu, nil when idle.
    var statusWord: String? {
        switch attention {
        case .running: "Working"
        case .needsInput: "Needs input"
        case .ready: "Done"
        case .unresolvedStop: "Stopped"
        case .checkBack: "Check back"
        case nil: nil
        }
    }

    /// "<name>, <status>, minimized" (UX spec §15).
    var accessibilityLabel: String {
        [name, statusWord, "minimized"].compactMap { $0 }.joined(separator: ", ")
    }
}

/// What the pill bar shows for the active worklane: its minimized floats,
/// oldest first (newest rightmost).
struct PillBarContent: Equatable {
    var items: [PillBarItem]

    static let empty = PillBarContent(items: [])

    init(items: [PillBarItem]) {
        self.items = items
    }

    init(worklane: WorklaneState) {
        let minimized = worklane.floatingPanes.compactMap { float -> (order: Int, float: FloatingPaneState)? in
            guard case .minimized(let order) = float.mode else { return nil }
            return (order, float)
        }
        .sorted { $0.order < $1.order }
        .map(\.float)

        self.items = minimized.map { float in
            let auxiliaryState = worklane.auxiliaryStateByPaneID[float.pane.id]
            let name = FloatDisplayName.resolve(
                pane: float.pane,
                presentation: auxiliaryState?.presentation,
                metadata: auxiliaryState?.metadata
            ) ?? Self.fallbackName(for: float.pane)
            return PillBarItem(
                paneID: float.pane.id,
                name: name,
                subtitle: Self.shortLocation(auxiliaryState?.shellContext, name: name),
                attention: auxiliaryState.flatMap {
                    WorklaneAttentionSummaryBuilder.attentionState(for: $0.presentation)
                }
            )
        }
    }

    var isEmpty: Bool {
        items.isEmpty
    }

    private static func fallbackName(for pane: PaneState) -> String {
        let title = pane.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Terminal" : title
    }

    /// Last component of the compact local path (`~` stays `~`), or the
    /// remote host. Nil when it would repeat the name.
    static func shortLocation(_ context: PaneShellContext?, name: String) -> String? {
        guard let context else { return nil }
        let location: String?
        switch context.scope {
        case .local:
            location = context.compactPathLabel.map { path in
                path == "~" || path == "/" ? path : (path as NSString).lastPathComponent
            }
        case .remote:
            location = context.remoteHostLabel
        }
        guard let location, !location.isEmpty, location != name else { return nil }
        return location
    }
}

/// Pure geometry of the pill bar. Coordinates are the bar's y-up space.
/// Pills are right-aligned, newest rightmost. When they don't fit they
/// compress to dot + short name; when that still doesn't fit, the oldest
/// ones go into a "+N" overflow menu on the left.
enum PillBarLayout {
    /// Room the bar takes from the strip (8pt margin above a 38pt row).
    static let barHeight: CGFloat = 46
    static let pillHeight: CGFloat = 28
    /// Gap between the pill and the bar's bottom edge.
    static let pillBottomInset: CGFloat = 5
    static let spacing: CGFloat = 6
    static let horizontalInset: CGFloat = 12
    static let overflowWidth: CGFloat = 40
    /// A pill dragged this far above the bar becomes a PiP on release.
    static let promoteDistance: CGFloat = 40
    /// Movement before a press on a pill turns into a drag.
    static let dragThreshold: CGFloat = 5

    enum Style: Equatable {
        case full
        case compact
    }

    struct Result: Equatable {
        var style: Style
        /// Frames of the shown pills, by index into the input (oldest first).
        var frames: [Int: CGRect]
        /// Indices in the overflow menu, oldest first.
        var overflow: [Int]
        var overflowFrame: CGRect?
    }

    /// `fullWidths[i]` / `compactWidths[i]`: pill `i` (oldest first) with
    /// its whole label, or as dot + short name.
    static func layout(fullWidths: [CGFloat], compactWidths: [CGFloat], in bounds: CGRect) -> Result {
        let count = min(fullWidths.count, compactWidths.count)
        guard count > 0 else {
            return Result(style: .full, frames: [:], overflow: [], overflowFrame: nil)
        }
        let available = max(0, bounds.width - horizontalInset * 2)

        if rowWidth(Array(fullWidths.prefix(count))) <= available {
            return place(Array(fullWidths.prefix(count)), from: 0, style: .full, overflow: [], in: bounds)
        }
        let compact = Array(compactWidths.prefix(count))
        if rowWidth(compact) <= available {
            return place(compact, from: 0, style: .compact, overflow: [], in: bounds)
        }

        // Keep as many of the newest as fit next to the overflow button.
        var kept = 0
        var used = overflowWidth
        for width in compact.reversed() {
            let next = used + spacing + width
            guard next <= available else { break }
            used = next
            kept += 1
        }
        let firstKept = count - kept
        return place(
            Array(compact.suffix(kept)),
            from: firstKept,
            style: .compact,
            overflow: Array(0..<firstKept),
            in: bounds
        )
    }

    /// Whether a pill released at `point` (bar coordinates) leaves the bar
    /// far enough to become a PiP.
    static func promotesToPip(releasePoint point: CGPoint, barBounds: CGRect) -> Bool {
        point.y >= barBounds.maxY + promoteDistance
    }

    private static func rowWidth(_ widths: [CGFloat]) -> CGFloat {
        widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
    }

    private static func place(
        _ widths: [CGFloat],
        from firstIndex: Int,
        style: Style,
        overflow: [Int],
        in bounds: CGRect
    ) -> Result {
        var frames: [Int: CGRect] = [:]
        var maxX = bounds.maxX - horizontalInset
        let y = bounds.minY + pillBottomInset
        for (offset, width) in widths.enumerated().reversed() {
            let frame = CGRect(x: maxX - width, y: y, width: width, height: pillHeight)
            frames[firstIndex + offset] = frame
            maxX = frame.minX - spacing
        }
        let overflowFrame = overflow.isEmpty
            ? nil
            : CGRect(x: maxX - overflowWidth, y: y, width: overflowWidth, height: pillHeight)
        return Result(style: style, frames: frames, overflow: overflow, overflowFrame: overflowFrame)
    }
}

extension FloatLayout {
    /// The canvas corner nearest to `point` (its quadrant). y-up.
    static func nearestCorner(to point: CGPoint, in canvas: CGRect) -> FloatCorner {
        let isTop = point.y >= canvas.midY
        let isLeft = point.x < canvas.midX
        switch (isTop, isLeft) {
        case (true, true): return .topLeft
        case (true, false): return .topRight
        case (false, true): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }
}
