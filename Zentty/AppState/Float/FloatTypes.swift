import CoreGraphics

/// Stable key a float is remembered under (inferred from its first non-shell command).
struct FloatName: Hashable, Sendable {
    let value: String
}

/// The four canvas corners a picture-in-picture float can sit in.
enum FloatCorner: String, Equatable, Sendable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

/// A rect stored as fractions of the canvas, so a float keeps its relative
/// position and size across window resizes and relaunch.
struct NormalizedRect: Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Normalizes `rect` against `canvas`. A degenerate canvas axis maps to 0
    /// rather than producing NaN/inf.
    init(rect: CGRect, in canvas: CGRect) {
        let canvasWidth = Double(canvas.width)
        let canvasHeight = Double(canvas.height)
        self.x = canvasWidth > 0 ? Double(rect.minX - canvas.minX) / canvasWidth : 0
        self.y = canvasHeight > 0 ? Double(rect.minY - canvas.minY) / canvasHeight : 0
        self.width = canvasWidth > 0 ? Double(rect.width) / canvasWidth : 0
        self.height = canvasHeight > 0 ? Double(rect.height) / canvasHeight : 0
    }

    func resolved(in canvas: CGRect) -> CGRect {
        CGRect(
            x: canvas.minX + CGFloat(x) * canvas.width,
            y: canvas.minY + CGFloat(y) * canvas.height,
            width: CGFloat(width) * canvas.width,
            height: CGFloat(height) * canvas.height
        )
    }
}

/// Where a float came from in the strip, so "dock to origin" can return it.
struct FloatOrigin: Equatable, Sendable {
    var columnIndex: Int
}

/// How a pane that left the strip is presented.
enum FloatingPaneMode: Equatable, Sendable {
    case floating
    /// Picture-in-picture; `order` is dense per corner (0 = closest to the corner).
    case pip(corner: FloatCorner, order: Int)
    /// Put away as a pill; `order` is dense across minimized floats.
    case minimized(order: Int)

    var isFloating: Bool {
        if case .floating = self { return true }
        return false
    }

    /// Stable wire name (`floating`, `pip`, `minimized`) for IPC and CLI output.
    var wireName: String {
        switch self {
        case .floating: "floating"
        case .pip: "pip"
        case .minimized: "minimized"
        }
    }
}

/// A pane that lives outside the strip. Owns its `PaneState`; the pane's
/// auxiliary state stays in `WorklaneState.auxiliaryStateByPaneID`.
struct FloatingPaneState: Equatable, Sendable {
    var pane: PaneState
    var mode: FloatingPaneMode
    /// Frame while `.floating` (also the size a PiP/pill restores to).
    var floatFrame: NormalizedRect
    /// Z-order among floats; higher is in front. Raising changes it, so
    /// never number or list floats by it (see `sequence`).
    var stackOrder: Int
    var origin: FloatOrigin?
    /// Creation order within the worklane; never changes while the pane
    /// stays a float. `WorklaneState.allPanes` (CLI numbering, tmux
    /// topology, sidebar order) lists floats by it, so a click that raises a
    /// float does not renumber the others.
    var sequence: Int = 0
}

extension FloatingPaneState {
    /// `floats` back to front: by `stackOrder`, stored order on ties.
    static func byStackOrder(_ floats: [FloatingPaneState]) -> [FloatingPaneState] {
        sorted(floats, by: \.stackOrder)
    }

    /// `floats` in creation order: by `sequence`, stored order on ties.
    static func bySequence(_ floats: [FloatingPaneState]) -> [FloatingPaneState] {
        sorted(floats, by: \.sequence)
    }

    private static func sorted(
        _ floats: [FloatingPaneState],
        by key: KeyPath<FloatingPaneState, Int>
    ) -> [FloatingPaneState] {
        floats.enumerated()
            .sorted { lhs, rhs in
                lhs.element[keyPath: key] == rhs.element[keyPath: key]
                    ? lhs.offset < rhs.offset
                    : lhs.element[keyPath: key] < rhs.element[keyPath: key]
            }
            .map(\.element)
    }
}

/// Where a temporary (overlay-style) pane is anchored: `worklane` re-anchors
/// to the focused pane when its owner closes; `pane` follows its owner and
/// closes with it. Wire names are the `zentty overlay open --placement` values.
enum OverlayPlacement: String, Equatable, Sendable, CaseIterable {
    case worklane
    case pane
}

/// Whether a pane outlives its command.
enum PaneLifetime: Equatable, Sendable {
    case persistent
    case temporary(owner: PaneID?, placement: OverlayPlacement, waitAfterCommand: Bool)
}
