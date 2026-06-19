import Foundation
import GhosttyKit
@testable import Zentty

extension ghostty_input_mouse_button_e: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.rawValue)
    }
}
