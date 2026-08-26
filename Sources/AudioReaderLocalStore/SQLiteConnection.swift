import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteConnection: @unchecked Sendable {
    private var db: OpaquePointer?
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

    func exec(_ sql: String) throws {
        guard db != nil else { throw LocalMigrationError.sqlite("closed") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if let errorMessage {
            let text = String(cString: errorMessage)
            sqlite3_free(errorMessage)
            if status != SQLITE_OK {
                throw LocalMigrationError.sqlite("\(sql): \(text)")
            }
        } else if status != SQLITE_OK {
            throw LocalMigrationError.sqlite("\(sql): \(errmsg())")
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw LocalMigrationError.sqlite("prepare \(sql): \(errmsg())")
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
                throw LocalMigrationError.sqlite("query \(sql): \(errmsg())")
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
            throw LocalMigrationError.sqlite("run \(sql): \(errmsg())")
        }
    }

    func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
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

    private func errmsg() -> String {
        db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
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
            throw LocalMigrationError.sqlite("utf8 encode")
        }
        return text
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from text: String) throws -> Value {
        try decoder.decode(type, from: Data(text.utf8))
    }

    static func decodeFile<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try decoder.decode(type, from: data)
    }
}

extension Dictionary where Key == String, Value == String {
    func string(_ key: String) -> String? { self[key] }

    func required(_ key: String) throws -> String {
        guard let value = self[key] else {
            throw LocalMigrationError.sqlite("missing column \(key)")
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
