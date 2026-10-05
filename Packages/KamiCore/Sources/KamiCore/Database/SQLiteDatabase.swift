import Foundation

#if canImport(SQLite3)
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
            if case let .int(v)? = values[column] { return Int(v) }
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

        // Archive reads select text as bounded BLOBs so invalid UTF-8 or an
        // embedded NUL cannot be silently replaced/truncated by C-string APIs.
        func bytes(_ column: String) -> [UInt8]? {
            if case let .blob(value)? = values[column] { return value }
            return nil
        }

        func isNull(_ column: String) -> Bool {
            if case .null? = values[column] { return true }
            return false
        }
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
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            var row = Row()
            for index in 0..<Int(sqlite3_column_count(stmt)) {
                let column = Int32(index)
                let name = String(cString: sqlite3_column_name(stmt, column))
                switch sqlite3_column_type(stmt, column) {
                case SQLITE_INTEGER: row.values[name] = .int(sqlite3_column_int64(stmt, column))
                case SQLITE_FLOAT: row.values[name] = .double(sqlite3_column_double(stmt, column))
                case SQLITE_TEXT: row.values[name] = .string(String(cString: sqlite3_column_text(stmt, column)))
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(stmt, column) {
                        let len = Int(sqlite3_column_bytes(stmt, column))
                        row.values[name] = .blob(Array(UnsafeRawBufferPointer(start: bytes, count: len)))
                    } else {
                        row.values[name] = .blob([])
                    }
                default: row.values[name] = .null
                }
            }
            rows.append(row)
            stepResult = sqlite3_step(stmt)
        }
        guard stepResult == SQLITE_DONE else {
            throw SQLiteError.step(String(cString: sqlite3_errmsg(handle)), sql: sql)
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

    /// Connection-local writes (including rolled-back writes) and commits by
    /// other connections invalidate a retained restore preview, including ABA.
    func restoreChangeStamp() throws -> [Int64] {
        guard let version = try query("PRAGMA data_version").first?.int64("data_version") else {
            throw LibraryRestoreError.invalidStoredData
        }
        return [sqlite3_total_changes64(handle), version]
    }

    /// Fixed internal projections only. Bounds precede value copies; types and
    /// byte lengths delimit values so neither Unicode folding nor C-string
    /// truncation can erase a dependency from a restore fingerprint.
    func restoreDependencyBytes(_ sql: String, maximumRows: Int,
                                maximumColumnBytes: Int, maximumBytes: Int) throws -> [UInt8] {
        let stmt = try prepare(sql, [])
        defer { sqlite3_finalize(stmt) }
        var output: [UInt8] = [], rows = 0
        func append(_ bytes: [UInt8]) throws {
            guard bytes.count <= maximumBytes - output.count else { throw LibraryRestoreError.resultLimitExceeded }
            output.append(contentsOf: bytes)
        }
        func word(_ value: UInt64) throws {
            var value = value.bigEndian
            try withUnsafeBytes(of: &value) { try append(Array($0)) }
        }
        let columns = sqlite3_column_count(stmt)
        guard columns > 0, columns <= 32 else { throw LibraryRestoreError.invalidStoredData }
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            try Task.checkCancellation()
            guard rows < maximumRows else { throw LibraryRestoreError.resultLimitExceeded }
            rows += 1
            try append([0xFE])
            for column in 0..<columns {
                let type = sqlite3_column_type(stmt, column)
                try append([UInt8(type)])
                switch type {
                case SQLITE_INTEGER: try word(UInt64(bitPattern: sqlite3_column_int64(stmt, column)))
                case SQLITE_FLOAT:
                    let value = sqlite3_column_double(stmt, column)
                    guard value.isFinite else { throw LibraryRestoreError.invalidStoredData }
                    try word(value.bitPattern)
                case SQLITE_TEXT, SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(stmt, column))
                    guard length <= maximumColumnBytes, length <= maximumBytes - output.count - 8 else {
                        throw LibraryRestoreError.resultLimitExceeded
                    }
                    let bytes: [UInt8]
                    if let pointer = sqlite3_column_blob(stmt, column) {
                        bytes = Array(UnsafeRawBufferPointer(start: pointer, count: length))
                    } else {
                        guard length == 0 else { throw LibraryRestoreError.invalidStoredData }
                        bytes = []
                    }
                    if type == SQLITE_TEXT {
                        guard !bytes.contains(0), String(bytes: bytes, encoding: .utf8) != nil else {
                            throw LibraryRestoreError.invalidStoredData
                        }
                    }
                    try word(UInt64(length)); try append(bytes)
                case SQLITE_NULL: break
                default: throw LibraryRestoreError.invalidStoredData
                }
            }
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else {
            throw SQLiteError.step(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        try append([0xFF])
        return output
    }

    private func prepare(_ sql: String, _ params: [SQLiteBindable]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let result: Int32
            switch p {
            case let .int(v): result = sqlite3_bind_int64(stmt, idx, v)
            case let .double(v): result = sqlite3_bind_double(stmt, idx, v)
            case let .text(v): result = sqlite3_bind_text(stmt, idx, v, -1, sqliteTransient)
            case let .blob(v):
                result = v.withUnsafeBytes {
                    sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), sqliteTransient)
                }
            case .null: result = sqlite3_bind_null(stmt, idx)
            }
            guard result == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(handle))
                sqlite3_finalize(stmt)
                throw SQLiteError.prepare(message, sql: sql)
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
