import AppKit
import Foundation

enum WorklaneColor: String, CaseIterable, Codable, Sendable {
    case red
    case orange
    case amber
    case yellow
    case lime
    case green
    case teal
    case cyan
    case blue
    case indigo
    case purple
    case pink

    enum Alpha {
        static let inactive: CGFloat = 0.12
        static let hover: CGFloat = 0.18
        static let active: CGFloat = 0.22
    }

    var localizedName: String {
        switch self {
        case .red: return NSLocalizedString("Red", comment: "Worklane color")
        case .orange: return NSLocalizedString("Orange", comment: "Worklane color")
        case .amber: return NSLocalizedString("Amber", comment: "Worklane color")
        case .yellow: return NSLocalizedString("Yellow", comment: "Worklane color")
        case .lime: return NSLocalizedString("Lime", comment: "Worklane color")
        case .green: return NSLocalizedString("Green", comment: "Worklane color")
        case .teal: return NSLocalizedString("Teal", comment: "Worklane color")
        case .cyan: return NSLocalizedString("Cyan", comment: "Worklane color")
        case .blue: return NSLocalizedString("Blue", comment: "Worklane color")
        case .indigo: return NSLocalizedString("Indigo", comment: "Worklane color")
        case .purple: return NSLocalizedString("Purple", comment: "Worklane color")
        case .pink: return NSLocalizedString("Pink", comment: "Worklane color")
        }
    }

    private struct Hex {
        let dark: UInt32
        let light: UInt32
    }

    private var hex: Hex {
        switch self {
        case .red: return Hex(dark: 0xF56565, light: 0xE53E3E)
        case .orange: return Hex(dark: 0xED8936, light: 0xDD6B20)
        case .amber: return Hex(dark: 0xD69E2E, light: 0xB7791F)
        case .yellow: return Hex(dark: 0xECC94B, light: 0xD69E2E)
        case .lime: return Hex(dark: 0x9AE6B4, light: 0x68D391)
        case .green: return Hex(dark: 0x48BB78, light: 0x38A169)
        case .teal: return Hex(dark: 0x38B2AC, light: 0x319795)
        case .cyan: return Hex(dark: 0x4FD1C5, light: 0x0BC5EA)
        case .blue: return Hex(dark: 0x4299E1, light: 0x3182CE)
        case .indigo: return Hex(dark: 0x667EEA, light: 0x5A67D8)
        case .purple: return Hex(dark: 0x9F7AEA, light: 0x805AD5)
        case .pink: return Hex(dark: 0xED64A6, light: 0xD53F8C)
        }
    }

    func tint(alpha: CGFloat) -> NSColor {
        let hex = self.hex
        let rawValue = self.rawValue
        return NSColor(name: NSColor.Name("worklaneColor.\(rawValue)")) { appearance in
            let packed: UInt32
            if appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil {
                packed = hex.dark
            } else {
                packed = hex.light
            }
            let r = CGFloat((packed >> 16) & 0xFF) / 255.0
            let g = CGFloat((packed >> 8) & 0xFF) / 255.0
            let b = CGFloat(packed & 0xFF) / 255.0
            return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
        }
    }
}
