import Foundation
import SQLite3

enum LocalSQLiteError: Error, Equatable, Sendable {
    case sqlite(String)
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private let sqliteStatic = unsafeBitCast(0, to: sqlite3_destructor_type.self)

final class SQLiteConnection: @unchecked Sendable {
    private var db: OpaquePointer?
    private var terminalError: (any Error)?
    let url: URL

    init(fileURL: URL) {
        url = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        if sqlite3_open(fileURL.path, &handle) == SQLITE_OK {
            db = handle
            sqlite3_busy_timeout(handle, 5000)
            try? exec("PRAGMA foreign_keys = ON")
            try? exec("PRAGMA journal_mode = WAL")
        } else {
            if let handle { sqlite3_close(handle) }
            db = nil
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// A schema-open failure is terminal for this store instance. Keeping the
    /// guard at the connection boundary also covers repository methods that do
    /// not call the schema applicator themselves.
    func failClosed(with error: any Error) {
        if terminalError == nil { terminalError = error }
    }

    func exec(_ sql: String) throws {
        try ensureAvailable()
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if let errorMessage {
            let text = String(cString: errorMessage)
            sqlite3_free(errorMessage)
            if status != SQLITE_OK {
                throw LocalSQLiteError.sqlite("\(sql): \(text)")
            }
        } else if status != SQLITE_OK {
            throw LocalSQLiteError.sqlite("\(sql): \(errmsg())")
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        try ensureAvailable()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw LocalSQLiteError.sqlite("prepare \(sql): \(errmsg())")
        }
        return stmt
    }

    func query(_ sql: String, bind: ((OpaquePointer) throws -> Void)? = nil) throws -> [[String: String]] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind?(stmt)
        var rows: [[String: String]] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw LocalSQLiteError.sqlite("query \(sql): \(errmsg())")
            }
            var row: [String: String] = [:]
            let cols = sqlite3_column_count(stmt)
            for index in 0..<cols {
                let name = String(cString: sqlite3_column_name(stmt, index))
                if sqlite3_column_type(stmt, index) != SQLITE_NULL,
                   let cstr = sqlite3_column_text(stmt, index) {
                    row[name] = String(cString: cstr)
                }
            }
            rows.append(row)
        }
        return rows
    }

    func run(_ sql: String, bind: (OpaquePointer) throws -> Void) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LocalSQLiteError.sqlite("run \(sql): \(errmsg())")
        }
    }

    func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        let bytes = Array(value.utf8)
        if bytes.isEmpty {
            sqlite3_bind_text(stmt, index, "", 0, sqliteStatic)
            return
        }
        _ = bytes.withUnsafeBytes { raw in
            sqlite3_bind_text(
                stmt,
                index,
                raw.baseAddress?.assumingMemoryBound(to: Int8.self),
                Int32(bytes.count),
                sqliteTransient
            )
        }
    }

    static func validateIdentifier(_ value: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw LocalSQLiteError.sqlite("invalid identifier \(value)")
        }
    }

    func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(stmt, index, value)
    }

    func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: Int) {
        sqlite3_bind_int64(stmt, index, sqlite3_int64(value))
    }

    func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int64(stmt, index, sqlite3_int64(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: Bool?) {
        if let value {
            sqlite3_bind_int(stmt, index, value ? 1 : 0)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    func bindDate(_ stmt: OpaquePointer, _ index: Int32, _ value: Date?) {
        bind(stmt, index, value.map(\.timeIntervalSince1970))
    }

    func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: Data) {
        if value.isEmpty {
            sqlite3_bind_blob(stmt, index, nil, 0, sqliteStatic)
            return
        }
        _ = value.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(value.count), sqliteTransient)
        }
    }

    private func errmsg() -> String {
        db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
    }

    private func ensureAvailable() throws {
        if let terminalError { throw terminalError }
        guard db != nil else { throw LocalSQLiteError.sqlite("closed") }
    }

    var totalChangeCount: Int {
        db.map { Int(sqlite3_total_changes($0)) } ?? 0
    }
}

enum LocalJSON {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encode<Value: Encodable>(_ value: Value) throws -> String {
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LocalSQLiteError.sqlite("utf8 encode")
        }
        return text
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from text: String) throws -> Value {
        try decoder.decode(type, from: Data(text.utf8))
    }
}

extension Dictionary where Key == String, Value == String {
    func string(_ key: String) -> String? { self[key] }

    func required(_ key: String) throws -> String {
        guard let value = self[key] else {
            throw LocalSQLiteError.sqlite("missing column \(key)")
        }
        return value
    }

    func int(_ key: String) -> Int {
        self[key].flatMap { Int($0) } ?? Int(double(key))
    }

    func double(_ key: String) -> Double {
        self[key].flatMap { Double($0) } ?? 0
    }

    func optionalDouble(_ key: String) -> Double? {
        self[key].flatMap { Double($0) }
    }

    func bool(_ key: String) -> Bool {
        int(key) != 0
    }

    func optionalBool(_ key: String) -> Bool? {
        self[key].map { Int($0) ?? 0 != 0 }
    }

    func date(_ key: String) -> Date {
        Date(timeIntervalSince1970: double(key))
    }

    func optionalDate(_ key: String) -> Date? {
        optionalDouble(key).map { Date(timeIntervalSince1970: $0) }
    }
}
