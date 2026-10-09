import Foundation
import SQLite3

/// Just enough SQLite for the memory index. Not thread-safe: owned by one actor.
final class SQLite {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    enum Value {
        case int(Int64), double(Double), text(String), blob(Data), null
    }

    private var db: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw Failure(description: "can't open \(path)")
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
    }

    deinit { sqlite3_close_v2(db) }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            defer { sqlite3_free(error) }
            throw Failure(description: error.map { String(cString: $0) } ?? "sqlite error")
        }
    }

    @discardableResult
    func run(_ sql: String, _ params: [Value] = []) throws -> Int64 {
        try withStatement(sql, params) { statement in
            let rc = sqlite3_step(statement)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw Failure(description: lastError) }
        }
        return sqlite3_last_insert_rowid(db)
    }

    func query(_ sql: String, _ params: [Value] = []) throws -> [[Value]] {
        try withStatement(sql, params) { statement in
            var rows: [[Value]] = []
            while true {
                let rc = sqlite3_step(statement)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw Failure(description: lastError) }
                rows.append((0..<sqlite3_column_count(statement)).map { column(statement, $0) })
            }
            return rows
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private var lastError: String { String(cString: sqlite3_errmsg(db)) }

    private func withStatement<T>(_ sql: String, _ params: [Value], _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(description: lastError)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, param) in params.enumerated() {
            let index = Int32(i + 1)
            switch param {
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .double(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, transient)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(v.count), transient) }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return try body(statement)
    }

    private func column(_ statement: OpaquePointer, _ i: Int32) -> Value {
        switch sqlite3_column_type(statement, i) {
        case SQLITE_INTEGER: .int(sqlite3_column_int64(statement, i))
        case SQLITE_FLOAT: .double(sqlite3_column_double(statement, i))
        case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, i)))
        case SQLITE_BLOB:
            .blob(Data(bytes: sqlite3_column_blob(statement, i), count: Int(sqlite3_column_bytes(statement, i))))
        default: .null
        }
    }
}

extension SQLite.Value {
    var text: String? { if case .text(let s) = self { s } else { nil } }
    var int: Int64? { if case .int(let n) = self { n } else { nil } }
    var double: Double? {
        switch self {
        case .double(let d): d
        case .int(let n): Double(n)
        default: nil
        }
    }
    var blob: Data? { if case .blob(let d) = self { d } else { nil } }
}
