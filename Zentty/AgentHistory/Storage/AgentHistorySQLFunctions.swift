import Foundation
import SQLite3

/// Deterministic SQL functions registered on every Agent History index connection, so the
/// content tier's SQL folds `repo:` / `branch:` values exactly like the metadata tier's Swift
/// (`HistoryFilterFolding`). SQLite's built-in `lower()` and `LIKE` fold ASCII only.
///
/// Both are per-row scalar filters: they never change the query plan, so the ordered FTS scan
/// stays the outer loop and no temp B-tree appears.
enum AgentHistorySQLFunctions {
    /// `zentty_fold(text)`: `HistoryFilterFolding.fold`; NULL stays NULL.
    static let fold = "zentty_fold"
    /// `zentty_folded_basename(path)`: `HistoryFilterFolding.foldedBasename`; NULL when there is none.
    static let foldedBasename = "zentty_folded_basename"

    /// Registers both functions on `db`; returns the first non-OK SQLite code, or `SQLITE_OK`.
    static func register(on db: OpaquePointer) -> Int32 {
        let flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS
        let functions: [(String, SQLiteScalarFunction)] = [(fold, foldFunction), (foldedBasename, foldedBasenameFunction)]
        for (name, function) in functions {
            let code = sqlite3_create_function_v2(db, name, 1, flags, nil, function, nil, nil, nil)
            guard code == SQLITE_OK else { return code }
        }
        return SQLITE_OK
    }
}

private typealias SQLiteScalarFunction = @convention(c) (
    OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?
) -> Void

private let foldFunction: SQLiteScalarFunction = { context, _, arguments in
    setTextResult(context, textArgument(arguments).map(HistoryFilterFolding.fold))
}

private let foldedBasenameFunction: SQLiteScalarFunction = { context, _, arguments in
    setTextResult(context, HistoryFilterFolding.foldedBasename(textArgument(arguments)))
}

/// The first argument as text; nil for SQL NULL.
private func textArgument(_ arguments: UnsafeMutablePointer<OpaquePointer?>?) -> String? {
    guard let value = arguments?[0], sqlite3_value_type(value) != SQLITE_NULL,
          let text = sqlite3_value_text(value) else {
        return nil
    }
    // `sqlite3_value_bytes` after `sqlite3_value_text`, so the count is of the UTF-8 form.
    let count = Int(sqlite3_value_bytes(value))
    return String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self)
}

private func setTextResult(_ context: OpaquePointer?, _ result: String?) {
    guard var result else {
        sqlite3_result_null(context)
        return
    }
    result.withUTF8 { bytes in
        bytes.withMemoryRebound(to: CChar.self) { chars in
            if let base = chars.baseAddress, !chars.isEmpty {
                sqlite3_result_text(context, base, Int32(chars.count), AgentHistoryDatabase.transientDestructor())
            } else {
                sqlite3_result_text(context, "", 0, nil)
            }
        }
    }
}
