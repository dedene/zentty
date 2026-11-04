import Foundation

/// Hand-rolled ISO 8601 parsing for transcript timestamps (much cheaper than a formatter per line).
///
/// Accepts `YYYY-MM-DD[T| ]hh:mm[:ss[.f…]](Z|±hh:mm|±hhmm|±hh)` with 0–9 fractional digits
/// (truncated to milliseconds). A time zone is required; anything else is nil.
enum AgentHistoryTimestamp {
    static func milliseconds(iso8601 text: String) -> Int64? {
        var scanner = Scanner(Array(text.utf8))
        guard
            let year = scanner.digits(4), scanner.take(UInt8(ascii: "-")),
            let month = scanner.digits(2), scanner.take(UInt8(ascii: "-")),
            let day = scanner.digits(2),
            scanner.takeAny([UInt8(ascii: "T"), UInt8(ascii: "t"), UInt8(ascii: " ")]),
            let hour = scanner.digits(2), scanner.take(UInt8(ascii: ":")),
            let minute = scanner.digits(2)
        else {
            return nil
        }

        var second: Int64 = 0
        var millisecond: Int64 = 0
        if scanner.take(UInt8(ascii: ":")) {
            guard let value = scanner.digits(2) else {
                return nil
            }
            second = value
            if scanner.take(UInt8(ascii: ".")) || scanner.take(UInt8(ascii: ",")) {
                guard let fraction = scanner.fractionMilliseconds() else {
                    return nil
                }
                millisecond = fraction
            }
        }

        guard let offsetSeconds = scanner.zoneOffsetSeconds(), scanner.isAtEnd else {
            return nil
        }
        guard
            (1...12).contains(month),
            (1...daysInMonth(year: year, month: month)).contains(day),
            (0...23).contains(hour),
            (0...59).contains(minute),
            (0...60).contains(second)
        else {
            return nil
        }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offsetSeconds
        return seconds * 1_000 + millisecond
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    private static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let shiftedMonth = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func daysInMonth(year: Int64, month: Int64) -> Int64 {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var position = 0

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        var isAtEnd: Bool { position == bytes.count }

        mutating func take(_ byte: UInt8) -> Bool {
            guard position < bytes.count, bytes[position] == byte else {
                return false
            }
            position += 1
            return true
        }

        mutating func takeAny(_ choices: [UInt8]) -> Bool {
            guard position < bytes.count, choices.contains(bytes[position]) else {
                return false
            }
            position += 1
            return true
        }

        mutating func digits(_ count: Int) -> Int64? {
            guard position + count <= bytes.count else {
                return nil
            }
            var value: Int64 = 0
            for index in position..<(position + count) {
                let byte = bytes[index]
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
                    return nil
                }
                value = value * 10 + Int64(byte - UInt8(ascii: "0"))
            }
            position += count
            return value
        }

        /// 1–9 digits after the separator, truncated to milliseconds.
        mutating func fractionMilliseconds() -> Int64? {
            var count = 0
            var millis: Int64 = 0
            while position < bytes.count, bytes[position] >= UInt8(ascii: "0"), bytes[position] <= UInt8(ascii: "9") {
                if count < 3 {
                    millis = millis * 10 + Int64(bytes[position] - UInt8(ascii: "0"))
                }
                count += 1
                position += 1
            }
            guard (1...9).contains(count) else {
                return nil
            }
            var scaled = count
            while scaled < 3 {
                millis *= 10
                scaled += 1
            }
            return millis
        }

        /// `Z`, `±hh:mm`, `±hhmm` or `±hh` → seconds east of UTC.
        mutating func zoneOffsetSeconds() -> Int64? {
            if take(UInt8(ascii: "Z")) || take(UInt8(ascii: "z")) {
                return 0
            }
            let sign: Int64
            if take(UInt8(ascii: "+")) {
                sign = 1
            } else if take(UInt8(ascii: "-")) {
                sign = -1
            } else {
                return nil
            }
            guard let hours = digits(2), hours <= 23 else {
                return nil
            }
            var minutes: Int64 = 0
            if take(UInt8(ascii: ":")) {
                guard let value = digits(2) else {
                    return nil
                }
                minutes = value
            } else if !isAtEnd {
                guard let value = digits(2) else {
                    return nil
                }
                minutes = value
            }
            guard minutes <= 59 else {
                return nil
            }
            return sign * (hours * 3_600 + minutes * 60)
        }
    }
}
