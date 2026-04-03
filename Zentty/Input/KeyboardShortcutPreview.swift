import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum KeyboardPreviewGeometry: Equatable {
    case ansi
    case iso
    case jis
}

enum KeyboardPreviewLayoutMetrics {
    static let interKeySpacingUnits: CGFloat = 0.18
    static let arrowKeyWidth: CGFloat = 1.1
    static let arrowClusterSideInsetUnits: CGFloat =
        arrowKeyWidth + interKeySpacingUnits
}

enum KeyboardPreviewKeySlotKind: Equatable {
    case keycap
    case spacer
}

enum KeyboardPreviewRowAlignment: Equatable {
    case center
    case trailing
}

enum KeyboardPreviewHighlightStyle: Equatable {
    case none
    case secondary
    case primary
}

struct KeyboardPreviewKeySlot: Equatable {
    let keyCode: UInt16
    let widthUnits: CGFloat
    let label: String
    let kind: KeyboardPreviewKeySlotKind

    var isSpacer: Bool {
        kind == .spacer
    }
}

struct KeyboardPreviewRow: Equatable {
    let alignment: KeyboardPreviewRowAlignment
    let slots: [KeyboardPreviewKeySlot]
}

struct KeyboardShortcutPreviewModel: Equatable {
    let geometry: KeyboardPreviewGeometry
    let rows: [KeyboardPreviewRow]
    let primaryHighlightedKeyCode: UInt16?
    let modifierHighlightStylesByKeyCode: [UInt16: KeyboardPreviewHighlightStyle]

    var highlightedModifierKeyCodes: Set<UInt16> {
        Set(modifierHighlightStylesByKeyCode.keys)
    }

    var highlightedKeyCodes: Set<UInt16> {
        var result = highlightedModifierKeyCodes
        if let primaryHighlightedKeyCode {
            result.insert(primaryHighlightedKeyCode)
        }
        return result
    }

    func highlightStyle(for keyCode: UInt16) -> KeyboardPreviewHighlightStyle {
        if primaryHighlightedKeyCode == keyCode {
            return .primary
        }

        return modifierHighlightStylesByKeyCode[keyCode] ?? .none
    }
}

protocol KeyboardPreviewSourceProviding {
    func currentGeometry() -> KeyboardPreviewGeometry
    func output(for keyCode: UInt16, modifiers: Set<KeyboardModifier>) -> String?
    func displayLabel(for keyCode: UInt16) -> String?
}

struct SystemKeyboardPreviewSourceProvider: KeyboardPreviewSourceProviding {
    func currentGeometry() -> KeyboardPreviewGeometry {
        switch Int(KBGetLayoutType(Int16(LMGetKbdType()))) {
        case Int(kKeyboardISO):
            .iso
        case Int(kKeyboardJIS):
            .jis
        default:
            .ansi
        }
    }

    func output(for keyCode: UInt16, modifiers: Set<KeyboardModifier>) -> String? {
        guard let layoutData = currentUnicodeKeyLayoutData(),
              let keyLayoutBytes = CFDataGetBytePtr(layoutData) else {
            return nil
        }

        let keyLayout = UnsafePointer<UCKeyboardLayout>(OpaquePointer(keyLayoutBytes))
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let modifierState = carbonModifierState(for: modifiers)
        let status = UCKeyTranslate(
            keyLayout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            modifierState,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )

        guard status == noErr, length > 0 else {
            return nil
        }

        let string = String(utf16CodeUnits: characters, count: Int(length))
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func displayLabel(for keyCode: UInt16) -> String? {
        guard let output = output(for: keyCode, modifiers: []) else {
            return nil
        }

        guard output.count == 1 else {
            return output
        }

        return output.uppercased()
    }

    func currentInputSourceName() -> String? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return nil
        }

        guard let rawName = TISGetInputSourceProperty(inputSource, kTISPropertyLocalizedName) else {
            return nil
        }

        return unsafeBitCast(rawName, to: CFString.self) as String
    }

    private func currentUnicodeKeyLayoutData() -> CFData? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return nil
        }

        guard let rawLayoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        return unsafeBitCast(rawLayoutData, to: CFData.self)
    }

    private func carbonModifierState(for modifiers: Set<KeyboardModifier>) -> UInt32 {
        var state: UInt32 = 0

        if modifiers.contains(.shift) {
            state |= UInt32(shiftKey >> 8)
        }
        if modifiers.contains(.option) {
            state |= UInt32(optionKey >> 8)
        }
        if modifiers.contains(.control) {
            state |= UInt32(controlKey >> 8)
        }
        if modifiers.contains(.command) {
            state |= UInt32(cmdKey >> 8)
        }

        return state
    }
}

struct KeyboardLayoutPreviewResolver {
    private let sourceProvider: KeyboardPreviewSourceProviding

    init(sourceProvider: KeyboardPreviewSourceProviding = SystemKeyboardPreviewSourceProvider()) {
        self.sourceProvider = sourceProvider
    }

    func resolve(shortcut: KeyboardShortcut?) -> KeyboardShortcutPreviewModel {
        let geometry = sourceProvider.currentGeometry()
        let templateRows = KeyboardPreviewTemplate.rows(for: geometry)
        let rows = templateRows.map { row in
            KeyboardPreviewRow(
                alignment: row.alignment,
                slots: row.slots.map { templateKey in
                    KeyboardPreviewKeySlot(
                        keyCode: templateKey.keyCode,
                        widthUnits: templateKey.widthUnits,
                        label: label(for: templateKey),
                        kind: templateKey.kind
                    )
                }
            )
        }

        let primaryHighlightedKeyCode = shortcut.flatMap { primaryKeyCode(for: $0, templateRows: templateRows) }
        let modifierHighlightStylesByKeyCode = shortcut.map {
            modifierHighlightStyles(
                for: $0,
                primaryHighlightedKeyCode: primaryHighlightedKeyCode,
                templateRows: templateRows
            )
        } ?? [:]

        return KeyboardShortcutPreviewModel(
            geometry: geometry,
            rows: rows,
            primaryHighlightedKeyCode: primaryHighlightedKeyCode,
            modifierHighlightStylesByKeyCode: modifierHighlightStylesByKeyCode
        )
    }

    private func label(for templateKey: KeyboardPreviewTemplateKey) -> String {
        switch templateKey.label {
        case let .fixed(value):
            value
        case .blank:
            ""
        case let .translated(fallback):
            sourceProvider.displayLabel(for: templateKey.keyCode) ?? fallback ?? ""
        }
    }

    private func primaryKeyCode(
        for shortcut: KeyboardShortcut,
        templateRows: [KeyboardPreviewTemplateRow]
    ) -> UInt16? {
        switch shortcut.key {
        case .tab:
            return UInt16(kVK_Tab)
        case .leftArrow:
            return UInt16(kVK_LeftArrow)
        case .rightArrow:
            return UInt16(kVK_RightArrow)
        case .upArrow:
            return UInt16(kVK_UpArrow)
        case .downArrow:
            return UInt16(kVK_DownArrow)
        case .character(let value):
            let translatedKeys = templateRows
                .flatMap(\.slots)
                .filter { $0.label.isTranslated }
            let characterGeneratingModifiers = shortcut.modifiers.intersection([.shift, .option])

            if let keyCode = matchingKeyCode(
                for: value,
                modifiers: characterGeneratingModifiers,
                templateKeys: translatedKeys
            ) {
                return keyCode
            }

            if characterGeneratingModifiers.isEmpty == false {
                return matchingKeyCode(for: value, modifiers: [], templateKeys: translatedKeys)
            }

            return nil
        }
    }

    private func matchingKeyCode(
        for value: String,
        modifiers: Set<KeyboardModifier>,
        templateKeys: [KeyboardPreviewTemplateKey]
    ) -> UInt16? {
        let normalizedValue = value.lowercased()

        return templateKeys.first { templateKey in
            sourceProvider.output(for: templateKey.keyCode, modifiers: modifiers)?.lowercased() == normalizedValue
        }?.keyCode
    }

    private func modifierHighlightStyles(
        for shortcut: KeyboardShortcut,
        primaryHighlightedKeyCode: UInt16?,
        templateRows: [KeyboardPreviewTemplateRow]
    ) -> [UInt16: KeyboardPreviewHighlightStyle] {
        var styles: [UInt16: KeyboardPreviewHighlightStyle] = [:]
        let duplicatedModifiers = Set(duplicatedModifierPairs.map(\.modifier))

        for pair in duplicatedModifierPairs where shortcut.modifiers.contains(pair.modifier) {
            let pairStyles = modifierPairHighlightStyles(
                for: pair,
                primaryHighlightedKeyCode: primaryHighlightedKeyCode,
                templateRows: templateRows
            )
            styles[pair.leftKeyCode] = pairStyles.left
            styles[pair.rightKeyCode] = pairStyles.right
        }

        for modifier in shortcut.modifiers.subtracting(duplicatedModifiers) {
            if let keyCode = singleSidedModifierKeyCode(for: modifier) {
                styles[keyCode] = .primary
            }
        }

        return styles
    }

    private func singleSidedModifierKeyCode(for modifier: KeyboardModifier) -> UInt16? {
        switch modifier {
        case .control:
            UInt16(kVK_Control)
        case .command, .option, .shift:
            nil
        }
    }

    private func modifierPairHighlightStyles(
        for pair: DuplicatedModifierPair,
        primaryHighlightedKeyCode: UInt16?,
        templateRows: [KeyboardPreviewTemplateRow]
    ) -> (left: KeyboardPreviewHighlightStyle, right: KeyboardPreviewHighlightStyle) {
        guard let primaryHighlightedKeyCode,
              let primaryCenter = keyCenter(for: primaryHighlightedKeyCode, in: templateRows),
              let leftCenter = keyCenter(for: pair.leftKeyCode, in: templateRows),
              let rightCenter = keyCenter(for: pair.rightKeyCode, in: templateRows) else {
            return (.primary, .primary)
        }

        let leftDistance = squaredDistance(from: leftCenter, to: primaryCenter)
        let rightDistance = squaredDistance(from: rightCenter, to: primaryCenter)

        if abs(leftDistance - rightDistance) <= 0.001 {
            return (.primary, .secondary)
        }

        return leftDistance < rightDistance
            ? (.primary, .secondary)
            : (.secondary, .primary)
    }

    private func keyCenter(
        for keyCode: UInt16,
        in templateRows: [KeyboardPreviewTemplateRow]
    ) -> CGPoint? {
        let maxRowWidth = templateRows.map { templateRowSpanUnits(for: $0.slots) }.max() ?? 0

        for (rowIndex, row) in templateRows.enumerated() {
            let rowWidth = templateRowSpanUnits(for: row.slots)
            let startX: CGFloat
            switch row.alignment {
            case .center:
                startX = (maxRowWidth - rowWidth) / 2
            case .trailing:
                startX = maxRowWidth - rowWidth
            }

            var cursorX = startX
            for (index, key) in row.slots.enumerated() {
                let keyStart = cursorX
                let keyEnd = keyStart + key.widthUnits
                if key.kind == .keycap, key.keyCode == keyCode {
                    return CGPoint(x: (keyStart + keyEnd) / 2, y: CGFloat(rowIndex))
                }

                cursorX = keyEnd
                if index < row.slots.count - 1,
                   key.kind == .keycap,
                   row.slots[index + 1].kind == .keycap {
                    cursorX += KeyboardPreviewLayoutMetrics.interKeySpacingUnits
                }
            }
        }

        return nil
    }

    private func templateRowSpanUnits(for row: [KeyboardPreviewTemplateKey]) -> CGFloat {
        let widths = row.reduce(CGFloat.zero) { $0 + $1.widthUnits }
        let adjacencyCount = zip(row, row.dropFirst()).reduce(0) { count, pair in
            count + (pair.0.kind == .keycap && pair.1.kind == .keycap ? 1 : 0)
        }

        return widths + (CGFloat(adjacencyCount) * KeyboardPreviewLayoutMetrics.interKeySpacingUnits)
    }

    private func squaredDistance(from first: CGPoint, to second: CGPoint) -> CGFloat {
        let deltaX = first.x - second.x
        let deltaY = first.y - second.y
        return (deltaX * deltaX) + (deltaY * deltaY)
    }

    private let duplicatedModifierPairs: [DuplicatedModifierPair] = [
        .init(modifier: .command, leftKeyCode: UInt16(kVK_Command), rightKeyCode: UInt16(kVK_RightCommand)),
        .init(modifier: .option, leftKeyCode: UInt16(kVK_Option), rightKeyCode: UInt16(kVK_RightOption)),
        .init(modifier: .shift, leftKeyCode: UInt16(kVK_Shift), rightKeyCode: UInt16(kVK_RightShift)),
    ]
}

private struct DuplicatedModifierPair {
    let modifier: KeyboardModifier
    let leftKeyCode: UInt16
    let rightKeyCode: UInt16
}

private enum KeyboardPreviewTemplateLabel: Equatable {
    case translated(fallback: String?)
    case fixed(String)
    case blank

    var isTranslated: Bool {
        if case .translated = self {
            return true
        }
        return false
    }
}

private struct KeyboardPreviewTemplateKey: Equatable {
    let keyCode: UInt16
    let widthUnits: CGFloat
    let label: KeyboardPreviewTemplateLabel
    let kind: KeyboardPreviewKeySlotKind
}

private struct KeyboardPreviewTemplateRow: Equatable {
    let alignment: KeyboardPreviewRowAlignment
    let slots: [KeyboardPreviewTemplateKey]
}

private enum KeyboardPreviewTemplate {
    static func rows(for geometry: KeyboardPreviewGeometry) -> [KeyboardPreviewTemplateRow] {
        switch geometry {
        case .ansi:
            stretchedLeadingRows(ansiRows)
        case .iso:
            stretchedLeadingRows(isoRows)
        case .jis:
            stretchedLeadingRows(jisRows)
        }
    }

    private static let topRow: KeyboardPreviewTemplateRow = trailingRow([
        translated(kVK_ANSI_Grave),
        translated(kVK_ANSI_1),
        translated(kVK_ANSI_2),
        translated(kVK_ANSI_3),
        translated(kVK_ANSI_4),
        translated(kVK_ANSI_5),
        translated(kVK_ANSI_6),
        translated(kVK_ANSI_7),
        translated(kVK_ANSI_8),
        translated(kVK_ANSI_9),
        translated(kVK_ANSI_0),
        translated(kVK_ANSI_Minus),
        translated(kVK_ANSI_Equal),
        fixed(kVK_Delete, "delete", width: 1.7),
    ])

    private static let ansiRows: [KeyboardPreviewTemplateRow] = [
        topRow,
        trailingRow([
            fixed(kVK_Tab, "tab", width: 1.5),
            translated(kVK_ANSI_Q),
            translated(kVK_ANSI_W),
            translated(kVK_ANSI_E),
            translated(kVK_ANSI_R),
            translated(kVK_ANSI_T),
            translated(kVK_ANSI_Y),
            translated(kVK_ANSI_U),
            translated(kVK_ANSI_I),
            translated(kVK_ANSI_O),
            translated(kVK_ANSI_P),
            translated(kVK_ANSI_LeftBracket),
            translated(kVK_ANSI_RightBracket),
            translated(kVK_ANSI_Backslash, fallback: "\\"),
        ]),
        trailingRow([
            fixed(kVK_CapsLock, "caps", width: 1.8),
            translated(kVK_ANSI_A),
            translated(kVK_ANSI_S),
            translated(kVK_ANSI_D),
            translated(kVK_ANSI_F),
            translated(kVK_ANSI_G),
            translated(kVK_ANSI_H),
            translated(kVK_ANSI_J),
            translated(kVK_ANSI_K),
            translated(kVK_ANSI_L),
            translated(kVK_ANSI_Semicolon),
            translated(kVK_ANSI_Quote),
            fixed(kVK_Return, "return", width: 1.9),
        ]),
        trailingRow([
            fixed(kVK_Shift, "shift", width: 2.1),
            translated(kVK_ANSI_Z),
            translated(kVK_ANSI_X),
            translated(kVK_ANSI_C),
            translated(kVK_ANSI_V),
            translated(kVK_ANSI_B),
            translated(kVK_ANSI_N),
            translated(kVK_ANSI_M),
            translated(kVK_ANSI_Comma),
            translated(kVK_ANSI_Period),
            translated(kVK_ANSI_Slash),
            fixed(kVK_RightShift, "shift", width: 2.35),
        ]),
        centeredRow(upperBottomRow(includeJISModeKeys: false)),
        centeredRow(lowerBottomRow(includeJISModeKeys: false)),
    ]

    private static let isoRows: [KeyboardPreviewTemplateRow] = [
        topRow,
        trailingRow([
            fixed(kVK_Tab, "tab", width: 1.5),
            translated(kVK_ANSI_Q),
            translated(kVK_ANSI_W),
            translated(kVK_ANSI_E),
            translated(kVK_ANSI_R),
            translated(kVK_ANSI_T),
            translated(kVK_ANSI_Y),
            translated(kVK_ANSI_U),
            translated(kVK_ANSI_I),
            translated(kVK_ANSI_O),
            translated(kVK_ANSI_P),
            translated(kVK_ANSI_LeftBracket),
            translated(kVK_ANSI_RightBracket),
        ]),
        trailingRow([
            fixed(kVK_CapsLock, "caps", width: 1.8),
            translated(kVK_ANSI_A),
            translated(kVK_ANSI_S),
            translated(kVK_ANSI_D),
            translated(kVK_ANSI_F),
            translated(kVK_ANSI_G),
            translated(kVK_ANSI_H),
            translated(kVK_ANSI_J),
            translated(kVK_ANSI_K),
            translated(kVK_ANSI_L),
            translated(kVK_ANSI_Semicolon),
            translated(kVK_ANSI_Quote),
            fixed(kVK_Return, "return", width: 2.4),
        ]),
        trailingRow([
            fixed(kVK_Shift, "shift", width: 1.45),
            translated(kVK_ISO_Section),
            translated(kVK_ANSI_Z),
            translated(kVK_ANSI_X),
            translated(kVK_ANSI_C),
            translated(kVK_ANSI_V),
            translated(kVK_ANSI_B),
            translated(kVK_ANSI_N),
            translated(kVK_ANSI_M),
            translated(kVK_ANSI_Comma),
            translated(kVK_ANSI_Period),
            translated(kVK_ANSI_Slash),
            fixed(kVK_RightShift, "shift", width: 2.0),
        ]),
        centeredRow(upperBottomRow(includeJISModeKeys: false)),
        centeredRow(lowerBottomRow(includeJISModeKeys: false)),
    ]

    private static let jisRows: [KeyboardPreviewTemplateRow] = [
        trailingRow([
            translated(kVK_ANSI_Grave),
            translated(kVK_ANSI_1),
            translated(kVK_ANSI_2),
            translated(kVK_ANSI_3),
            translated(kVK_ANSI_4),
            translated(kVK_ANSI_5),
            translated(kVK_ANSI_6),
            translated(kVK_ANSI_7),
            translated(kVK_ANSI_8),
            translated(kVK_ANSI_9),
            translated(kVK_ANSI_0),
            translated(kVK_ANSI_Minus),
            translated(kVK_ANSI_Equal),
            translated(kVK_JIS_Yen, fallback: "¥"),
            fixed(kVK_Delete, "delete", width: 1.5),
        ]),
        trailingRow([
            fixed(kVK_Tab, "tab", width: 1.5),
            translated(kVK_ANSI_Q),
            translated(kVK_ANSI_W),
            translated(kVK_ANSI_E),
            translated(kVK_ANSI_R),
            translated(kVK_ANSI_T),
            translated(kVK_ANSI_Y),
            translated(kVK_ANSI_U),
            translated(kVK_ANSI_I),
            translated(kVK_ANSI_O),
            translated(kVK_ANSI_P),
            translated(kVK_ANSI_LeftBracket),
            translated(kVK_ANSI_RightBracket),
        ]),
        trailingRow([
            fixed(kVK_CapsLock, "caps", width: 1.8),
            translated(kVK_ANSI_A),
            translated(kVK_ANSI_S),
            translated(kVK_ANSI_D),
            translated(kVK_ANSI_F),
            translated(kVK_ANSI_G),
            translated(kVK_ANSI_H),
            translated(kVK_ANSI_J),
            translated(kVK_ANSI_K),
            translated(kVK_ANSI_L),
            translated(kVK_ANSI_Semicolon),
            translated(kVK_ANSI_Quote),
            translated(kVK_JIS_Underscore, fallback: "_"),
            fixed(kVK_Return, "return", width: 1.6),
        ]),
        trailingRow([
            fixed(kVK_Shift, "shift", width: 2.1),
            translated(kVK_ANSI_Z),
            translated(kVK_ANSI_X),
            translated(kVK_ANSI_C),
            translated(kVK_ANSI_V),
            translated(kVK_ANSI_B),
            translated(kVK_ANSI_N),
            translated(kVK_ANSI_M),
            translated(kVK_ANSI_Comma),
            translated(kVK_ANSI_Period),
            translated(kVK_ANSI_Slash),
            fixed(kVK_RightShift, "shift", width: 2.35),
        ]),
        centeredRow(upperBottomRow(includeJISModeKeys: true)),
        centeredRow(lowerBottomRow(includeJISModeKeys: true)),
    ]

    private static func upperBottomRow(includeJISModeKeys: Bool) -> [KeyboardPreviewTemplateKey] {
        bottomModifierKeys(includeJISModeKeys: includeJISModeKeys) + [
            spacer(width: KeyboardPreviewLayoutMetrics.arrowClusterSideInsetUnits),
            fixed(kVK_UpArrow, "↑", width: KeyboardPreviewLayoutMetrics.arrowKeyWidth),
            spacer(width: KeyboardPreviewLayoutMetrics.arrowClusterSideInsetUnits),
        ]
    }

    private static func lowerBottomRow(includeJISModeKeys: Bool) -> [KeyboardPreviewTemplateKey] {
        let leadingSpacerWidth = rowSpanUnits(for: bottomModifierKeys(includeJISModeKeys: includeJISModeKeys))

        return [
            spacer(width: leadingSpacerWidth),
            fixed(kVK_LeftArrow, "←", width: KeyboardPreviewLayoutMetrics.arrowKeyWidth),
            fixed(kVK_DownArrow, "↓", width: KeyboardPreviewLayoutMetrics.arrowKeyWidth),
            fixed(kVK_RightArrow, "→", width: KeyboardPreviewLayoutMetrics.arrowKeyWidth),
        ]
    }

    private static func bottomModifierKeys(includeJISModeKeys: Bool) -> [KeyboardPreviewTemplateKey] {
        var row: [KeyboardPreviewTemplateKey] = [
            fixed(kVK_Control, "⌃", width: 1.2),
            fixed(kVK_Option, "⌥", width: 1.2),
            fixed(kVK_Command, "⌘", width: 1.5),
        ]

        if includeJISModeKeys {
            row.append(fixed(kVK_JIS_Eisu, "英数", width: 1.15))
        }

        row.append(blank(width: 4.7, keyCode: kVK_Space))

        if includeJISModeKeys {
            row.append(fixed(kVK_JIS_Kana, "かな", width: 1.15))
        }

        row.append(contentsOf: [
            fixed(kVK_RightCommand, "⌘", width: 1.5),
            fixed(kVK_RightOption, "⌥", width: 1.2),
        ])

        return row
    }

    private static func rowSpanUnits(for row: [KeyboardPreviewTemplateKey]) -> CGFloat {
        let widths = row.reduce(CGFloat.zero) { $0 + $1.widthUnits }
        let adjacencyCount = zip(row, row.dropFirst()).reduce(0) { count, pair in
            count + (pair.0.kind == .keycap && pair.1.kind == .keycap ? 1 : 0)
        }

        return widths + (CGFloat(adjacencyCount) * KeyboardPreviewLayoutMetrics.interKeySpacingUnits)
    }

    private static func stretchedLeadingRows(_ rows: [KeyboardPreviewTemplateRow]) -> [KeyboardPreviewTemplateRow] {
        let alignedRowIndices = rows.indices.filter { $0 <= 4 }
        let targetSpan = alignedRowIndices
            .map { rowSpanUnits(for: rows[$0].slots) }
            .max() ?? 0
        var pendingCenteredArrowSpacerDeficit: CGFloat = 0

        return rows.enumerated().map { index, row in
            if pendingCenteredArrowSpacerDeficit > 0.001,
               index == 5,
               row.alignment == .center,
               row.slots.first?.kind == .spacer {
                var adjustedSlots = row.slots
                let leadingSpacer = adjustedSlots[0]
                adjustedSlots[0] = KeyboardPreviewTemplateKey(
                    keyCode: leadingSpacer.keyCode,
                    widthUnits: leadingSpacer.widthUnits + pendingCenteredArrowSpacerDeficit,
                    label: leadingSpacer.label,
                    kind: leadingSpacer.kind
                )
                pendingCenteredArrowSpacerDeficit = 0
                return KeyboardPreviewTemplateRow(alignment: row.alignment, slots: adjustedSlots)
            }

            guard alignedRowIndices.contains(index) else {
                return row
            }

            let deficit = targetSpan - rowSpanUnits(for: row.slots)
            guard deficit > 0.001,
                  let firstVisibleKeyIndex = row.slots.firstIndex(where: { $0.kind == .keycap }) else {
                return row
            }

            var stretchedSlots = row.slots
            let firstKey = stretchedSlots[firstVisibleKeyIndex]
            stretchedSlots[firstVisibleKeyIndex] = KeyboardPreviewTemplateKey(
                keyCode: firstKey.keyCode,
                widthUnits: firstKey.widthUnits + deficit,
                label: firstKey.label,
                kind: firstKey.kind
            )

            if index == 4 {
                pendingCenteredArrowSpacerDeficit = deficit
            }

            return KeyboardPreviewTemplateRow(alignment: row.alignment, slots: stretchedSlots)
        }
    }

    private static func trailingRow(_ slots: [KeyboardPreviewTemplateKey]) -> KeyboardPreviewTemplateRow {
        KeyboardPreviewTemplateRow(alignment: .trailing, slots: slots)
    }

    private static func centeredRow(_ slots: [KeyboardPreviewTemplateKey]) -> KeyboardPreviewTemplateRow {
        KeyboardPreviewTemplateRow(alignment: .center, slots: slots)
    }

    private static func translated(
        _ keyCode: Int,
        fallback: String? = nil,
        width: CGFloat = 1.0
    ) -> KeyboardPreviewTemplateKey {
        KeyboardPreviewTemplateKey(
            keyCode: UInt16(keyCode),
            widthUnits: width,
            label: .translated(fallback: fallback),
            kind: .keycap
        )
    }

    private static func fixed(_ keyCode: Int, _ label: String, width: CGFloat = 1.0) -> KeyboardPreviewTemplateKey {
        KeyboardPreviewTemplateKey(
            keyCode: UInt16(keyCode),
            widthUnits: width,
            label: .fixed(label),
            kind: .keycap
        )
    }

    private static func blank(width: CGFloat, keyCode: Int) -> KeyboardPreviewTemplateKey {
        KeyboardPreviewTemplateKey(
            keyCode: UInt16(keyCode),
            widthUnits: width,
            label: .blank,
            kind: .keycap
        )
    }

    private static func spacer(width: CGFloat) -> KeyboardPreviewTemplateKey {
        KeyboardPreviewTemplateKey(
            keyCode: 0,
            widthUnits: width,
            label: .blank,
            kind: .spacer
        )
    }
}
