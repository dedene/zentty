import Foundation
import SQLite3

/// A value bound to, or read from, a SQLite statement.
enum AgentHistoryValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    // Optional helpers are static functions, not initializers, so `nil` literals stay unambiguous.
    static func of(_ value: Int64?) -> AgentHistoryValue { value.map { .integer($0) } ?? .null }
    static func of(_ value: Int?) -> AgentHistoryValue { value.map { .integer(Int64($0)) } ?? .null }
    static func of(_ value: String?) -> AgentHistoryValue { value.map { .text($0) } ?? .null }
    static func of(_ value: Bool?) -> AgentHistoryValue { value.map { .integer($0 ? 1 : 0) } ?? .null }
    static func of(_ value: Double?) -> AgentHistoryValue { value.map { .real($0) } ?? .null }
    static func of(_ value: Data?) -> AgentHistoryValue { value.map { .blob($0) } ?? .null }
}

extension AgentHistoryValue: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral, ExpressibleByNilLiteral {
    init(integerLiteral value: Int64) { self = .integer(value) }
    init(stringLiteral value: String) { self = .text(value) }
    init(nilLiteral: ()) { self = .null }
}

/// Column reader for the row a statement is currently positioned on.
///
/// Valid only inside the `map` closure of `AgentHistoryDatabase.query` (it borrows the
/// stepped statement). Must not escape.
struct AgentHistoryRow {
    let statement: OpaquePointer

    var columnCount: Int32 { sqlite3_column_count(statement) }

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func optionalInt64(_ column: Int32) -> Int64? {
        isNull(column) ? nil : int64(column)
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    func bool(_ column: Int32) -> Bool {
        int64(column) != 0
    }

    /// Decodes the column's UTF-8 bytes (embedded NUL safe). NULL reads as "".
    func string(_ column: Int32) -> String {
        withUTF8Bytes(column) { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func optionalString(_ column: Int32) -> String? {
        withUTF8Bytes(column) { String(decoding: $0, as: UTF8.self) }
    }

    /// NULL reads as empty data.
    func data(_ column: Int32) -> Data {
        optionalData(column) ?? Data()
    }

    func optionalData(_ column: Int32) -> Data? {
        guard !isNull(column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    func value(_ column: Int32) -> AgentHistoryValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return .integer(int64(column))
        case SQLITE_FLOAT: return .real(double(column))
        case SQLITE_TEXT: return .text(string(column))
        case SQLITE_BLOB: return .blob(data(column))
        default: return .null
        }
    }

    /// Hands the column's UTF-8 text bytes to `body` without copying. Returns nil for NULL.
    func withUTF8Bytes<T>(_ column: Int32, _ body: (UnsafeBufferPointer<UInt8>) throws -> T) rethrows -> T? {
        guard !isNull(column) else { return nil }
        let pointer = sqlite3_column_text(statement, column)
        let count = Int(sqlite3_column_bytes(statement, column))
        return try body(UnsafeBufferPointer(start: pointer, count: pointer == nil ? 0 : count))
    }
}

/// A SQLite failure. `message` comes from `sqlite3_errmsg` and may contain SQL fragments or
/// values: it is never part of `description`, and must only be logged with `privacy: .private`.
struct AgentHistoryDatabaseError: Error, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case corrupt, notADatabase, full, busy, readOnly, cantOpen, constraint, interrupted
        case schemaTooNew(found: Int32)
        case misuse, other
    }

    let kind: Kind
    let code: Int32
    let extendedCode: Int32
    let message: String

    var isCorruption: Bool { kind == .corrupt || kind == .notADatabase }

    static func from(code: Int32, db: OpaquePointer?) -> AgentHistoryDatabaseError {
        let primary = code & 0xFF
        var extended = code
        var message: String
        if let db {
            let dbExtended = sqlite3_extended_errcode(db)
            if dbExtended & 0xFF == primary { extended = dbExtended }
            message = sqlite3_errmsg(db).map { String(cString: $0) } ?? ""
        } else {
            message = ""
        }
        if message.isEmpty, let text = sqlite3_errstr(code) {
            message = String(cString: text)
        }
        return AgentHistoryDatabaseError(kind: kind(forPrimaryCode: primary), code: primary,
                                         extendedCode: extended, message: message)
    }

    static func kind(forPrimaryCode code: Int32) -> Kind {
        switch code {
        case SQLITE_CORRUPT: return .corrupt
        case SQLITE_NOTADB: return .notADatabase
        case SQLITE_FULL: return .full
        case SQLITE_BUSY, SQLITE_LOCKED: return .busy
        case SQLITE_READONLY: return .readOnly
        case SQLITE_CANTOPEN: return .cantOpen
        case SQLITE_CONSTRAINT: return .constraint
        case SQLITE_INTERRUPT: return .interrupted
        case SQLITE_MISUSE: return .misuse
        default: return .other
        }
    }

    static func closed() -> AgentHistoryDatabaseError {
        AgentHistoryDatabaseError(kind: .misuse, code: SQLITE_MISUSE, extendedCode: SQLITE_MISUSE,
                                  message: "database connection is closed")
    }
}

extension AgentHistoryDatabaseError: CustomStringConvertible, LocalizedError {
    var description: String {
        "SQLite \(Self.kindName(kind)) (\(code)/\(extendedCode))"
    }

    var errorDescription: String? { description }

    private static func kindName(_ kind: Kind) -> String {
        switch kind {
        case .corrupt: return "corrupt"
        case .notADatabase: return "notADatabase"
        case .full: return "full"
        case .busy: return "busy"
        case .readOnly: return "readOnly"
        case .cantOpen: return "cantOpen"
        case .constraint: return "constraint"
        case .interrupted: return "interrupted"
        case .schemaTooNew(let found): return "schemaTooNew(\(found))"
        case .misuse: return "misuse"
        case .other: return "other"
        }
    }
}
