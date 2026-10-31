import CoreGraphics

/// Stable key a float is remembered under (inferred from its first non-shell command).
struct FloatName: Hashable, Sendable {
    let value: String
}

/// The four canvas corners a picture-in-picture float can sit in.
enum FloatCorner: String, Equatable, Sendable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}
