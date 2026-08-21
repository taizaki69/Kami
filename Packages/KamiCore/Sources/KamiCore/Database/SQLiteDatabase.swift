import Foundation
import SQLite3

#if canImport(SQLite3)

/// Thin SQLite3 wrapper (system library; no third-party dependency).
/// Thread-safety: one instance per queue; callers serialize via the Database
/// actor in Services.
public final class SQLiteDatabase {
    public enum SQLiteError: Error, CustomStringConvertible {
        case open(String)
        case prepare(String, sql: String)
        case step(String, sql: String)

        public var description: String {
            switch self {
            case let .open(msg): return "sqlite open failed: \(msg)"
            case let .prepare(msg, sql): return "sqlite prepare failed: \(msg) [\(sql)]"
            case let .step(msg, sql): return "sqlite step failed: \(msg) [\(sql)]"
            }
        }
    }

    private var handle: OpaquePointer?

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteError.open(msg)
        }
        handle = db
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    public func execute(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw SQLiteError.step(msg, sql: sql)
        }
    }

    public struct Row {
        fileprivate var values: [String: SQLiteValue] = [:]
        public func string(_ column: String) -> String? {
            if case let .string(v)? = values[column] { return v }
            return nil
        }
        public func int(_ column: String) -> Int? {
            if case let .int(v)? = values[column] { return v }
            return nil
        }
        public func int64(_ column: String) -> Int64? {
            if case let .int(v)? = values[column] { return v }
            return nil
        }
        public func double(_ column: String) -> Double? {
            if case let .double(v)? = values[column] { return v }
            return nil
        }
        public func bool(_ column: String) -> Bool { int(column) == 1 }
    }

    enum SQLiteValue {
        case int(Int64)
        case double(Double)
        case string(String)
        case blob([UInt8])
        case null
    }

    public func query(_ sql: String, _ params: [SQLiteBindable] = []) throws -> [Row] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row = Row()
            let count = sqlite3_column_count(stmt)
            for i in 0..<Int(count) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row.values[name] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row.values[name] = .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: row.values[name] = .string(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(stmt, i) {
                        let len = Int(sqlite3_column_bytes(stmt, i))
                        row.values[name] = .blob(Array(UnsafeRawBufferPointer(start: bytes, count: len)))
                    } else {
                        row.values[name] = .blob([])
                    }
                default: row.values[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func run(_ sql: String, _ params: [SQLiteBindable] = []) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteError.step(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
    }

    @discardableResult
    public func insert(_ sql: String, _ params: [SQLiteBindable] = []) throws -> Int64 {
        try run(sql, params)
        return sqlite3_last_insert_rowid(handle)
    }

    private func prepare(_ sql: String, _ params: [SQLiteBindable]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let .int(v): sqlite3_bind_int64(stmt, idx, v)
            case let .double(v): sqlite3_bind_double(stmt, idx, v)
            case let .text(v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let .blob(v): v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }
}

public enum SQLiteBindable {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob([UInt8])
    case null

    public static func int(_ v: Int) -> SQLiteBindable { .int(Int64(v)) }
    public static func bool(_ v: Bool) -> SQLiteBindable { .int(v ? 1 : 0) }
}

#endif