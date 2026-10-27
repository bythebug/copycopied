import Foundation
import SQLite3

public enum SQLValue: Sendable, Equatable {
    case int(Int64), real(Double), text(String), null

    var int: Int64? { if case let .int(v) = self { v } else { nil } }
    var real: Double? { if case let .real(v) = self { v } else if case let .int(v) = self { Double(v) } else { nil } }
    var text: String? { if case let .text(v) = self { v } else { nil } }
}

public enum VolumeRole: String, Sendable, CaseIterable {
    case card, workingDrive, backupDrive, ignored
}

public struct VolumeRecord: Sendable, Equatable {
    public var id: String
    public var name: String
    public var role: VolumeRole?  // nil = auto
    public var lastIndexed: Date?
}

public struct IndexedFile: Sendable, Equatable {
    public var path: String
    public var stat: FileStat
    public var hash: String?
}

/// SQLite persistence (system libsqlite3, PLAN.md D3). Not thread-safe; one Store per isolation domain.
public final class Store {
    private var db: OpaquePointer?

    public static func defaultURL() throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
            .appendingPathComponent("backed", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("backed.sqlite")
    }

    public init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw BackedError.db(String(cString: sqlite3_errmsg(db)))
        }
        try exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS volume(
              id TEXT PRIMARY KEY, name TEXT NOT NULL, role TEXT, last_indexed REAL);
            CREATE TABLE IF NOT EXISTS indexed_file(
              volume_id TEXT NOT NULL, path TEXT NOT NULL, size INTEGER NOT NULL, mtime REAL NOT NULL,
              inode INTEGER NOT NULL, hash TEXT, hash_verified_at REAL,
              PRIMARY KEY(volume_id, path));
            CREATE INDEX IF NOT EXISTS indexed_file_size ON indexed_file(volume_id, size);
            """)
    }

    deinit { sqlite3_close(db) }

    public func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    @discardableResult
    public func query(_ sql: String, _ args: [SQLValue] = []) throws -> [[SQLValue]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case let .int(v): sqlite3_bind_int64(stmt, idx, v)
            case let .real(v): sqlite3_bind_double(stmt, idx, v)
            case let .text(v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        var rows: [[SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error() }
            rows.append((0..<sqlite3_column_count(stmt)).map { c in
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: .real(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(stmt, c)))
                default: .null
                }
            })
        }
        return rows
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func error() -> BackedError { .db(String(cString: sqlite3_errmsg(db))) }

    // MARK: volumes

    /// Records that a volume was seen, keeping any role already set.
    public func touchVolume(id: String, name: String) throws {
        try query("INSERT INTO volume(id, name) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name",
                  [.text(id), .text(name)])
    }

    public func setRole(_ role: VolumeRole?, id: String, name: String) throws {
        try touchVolume(id: id, name: name)
        try query("UPDATE volume SET role = ? WHERE id = ?", [role.map { .text($0.rawValue) } ?? .null, .text(id)])
    }

    public func volumes() throws -> [VolumeRecord] {
        try query("SELECT id, name, role, last_indexed FROM volume ORDER BY name").map {
            VolumeRecord(id: $0[0].text!, name: $0[1].text!, role: $0[2].text.flatMap(VolumeRole.init),
                         lastIndexed: $0[3].real.map(Date.init(timeIntervalSince1970:)))
        }
    }

    public func volume(id: String) throws -> VolumeRecord? { try volumes().first { $0.id == id } }

    // MARK: indexed files

    public func indexedFiles(volumeID: String) throws -> [IndexedFile] {
        try query("SELECT path, size, mtime, inode, hash FROM indexed_file WHERE volume_id = ?", [.text(volumeID)]).map {
            IndexedFile(path: $0[0].text!,
                        stat: FileStat(size: $0[1].int!, mtime: $0[2].real!, inode: UInt64(bitPattern: $0[3].int!)),
                        hash: $0[4].text)
        }
    }
}
