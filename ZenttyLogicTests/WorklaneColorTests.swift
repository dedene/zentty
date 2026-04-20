import AppKit
import XCTest
@testable import Zentty

final class WorklaneColorTests: XCTestCase {
    func test_every_case_has_a_non_empty_localized_name() {
        for color in WorklaneColor.allCases {
            XCTAssertFalse(color.localizedName.isEmpty, "Missing localized name for \(color.rawValue)")
        }
    }

    func test_every_case_round_trips_through_raw_value() throws {
        for color in WorklaneColor.allCases {
            let decoded = try XCTUnwrap(WorklaneColor(rawValue: color.rawValue))
            XCTAssertEqual(decoded, color)
        }
    }

    func test_every_case_round_trips_through_json() throws {
        for color in WorklaneColor.allCases {
            let data = try JSONEncoder().encode(color)
            let decoded = try JSONDecoder().decode(WorklaneColor.self, from: data)
            XCTAssertEqual(decoded, color)
        }
    }

    func test_tint_preserves_requested_alpha() {
        let alphas: [CGFloat] = [
            WorklaneColor.Alpha.inactive,
            WorklaneColor.Alpha.hover,
            WorklaneColor.Alpha.active,
        ]
        for color in WorklaneColor.allCases {
            for alpha in alphas {
                let nsColor = color.tint(alpha: alpha).usingColorSpace(.sRGB)
                XCTAssertEqual(nsColor?.alphaComponent ?? -1, alpha, accuracy: 0.001,
                               "Alpha mismatch for \(color.rawValue) at \(alpha)")
            }
        }
    }

    func test_unknown_raw_value_decodes_to_nil() {
        XCTAssertNil(WorklaneColor(rawValue: "chartreuse"))
        XCTAssertNil(WorklaneColor(rawValue: ""))
    }
}
