import Foundation

/// A place copies can live: a mounted volume (id = volume UUID) or, for tests/CLI, any folder (id = "dir:<path>").
public struct Destination: Sendable, Hashable {
    public var id: String
    public var name: String
    public var root: URL?  // nil = not connected; only the stored index ("memory") is available

    public init(id: String, name: String, root: URL?) {
        self.id = id
        self.name = name
        self.root = root
    }
}

/// Keeps a destination's `indexed_file` rows in step with the disk. Rows survive disconnects (the drive's memory).
public struct Indexer {
    public let store: Store

    public init(store: Store) { self.store = store }

    /// Incremental walk: rows whose (size, mtime, inode) changed lose their hash; vanished files are removed.
    public func index(_ dest: Destination) throws {
        guard let root = dest.root else { return }
        try store.touchVolume(id: dest.id, name: dest.name)
        let existing = Dictionary(try store.indexedFiles(volumeID: dest.id).map { ($0.path, $0.stat) },
                                  uniquingKeysWith: { a, _ in a })
        let onDisk = walkFiles(root)
        try store.transaction {
            for f in onDisk where existing[f.path] != f.stat {
                try store.query("""
                    INSERT INTO indexed_file(volume_id, path, size, mtime, inode, hash, hash_verified_at)
                    VALUES(?, ?, ?, ?, ?, NULL, NULL)
                    ON CONFLICT(volume_id, path) DO UPDATE SET size = excluded.size, mtime = excluded.mtime,
                      inode = excluded.inode, hash = NULL, hash_verified_at = NULL
                    """, [.text(dest.id), .text(f.path), .int(f.stat.size), .real(f.stat.mtime),
                          .int(Int64(bitPattern: f.stat.inode))])
            }
            let seen = Set(onDisk.map(\.path))
            for path in existing.keys where !seen.contains(path) {
                try store.query("DELETE FROM indexed_file WHERE volume_id = ? AND path = ?", [.text(dest.id), .text(path)])
            }
            try store.query("UPDATE volume SET last_indexed = ? WHERE id = ?",
                            [.real(Date().timeIntervalSince1970), .text(dest.id)])
        }
    }

    /// Records a file backed. just wrote and verified uncached, so it needs no re-hash.
    public func record(_ dest: Destination, path: String, hash: String) throws {
        guard let root = dest.root, let st = statFile(atPath: root.appendingPathComponent(path).path) else { return }
        try store.touchVolume(id: dest.id, name: dest.name)
        try store.query("""
            INSERT OR REPLACE INTO indexed_file(volume_id, path, size, mtime, inode, hash, hash_verified_at)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            """, [.text(dest.id), .text(path), .int(st.size), .real(st.mtime), .int(Int64(bitPattern: st.inode)),
                  .text(hash), .real(Date().timeIntervalSince1970)])
    }

    /// Hashes (uncached) every unhashed row whose size is in `sizes`. Only size collisions are worth reading.
    public func hashCandidates(_ dest: Destination, sizes: Set<Int64>) throws {
        guard let root = dest.root else { return }
        for f in try store.indexedFiles(volumeID: dest.id) where f.hash == nil && sizes.contains(f.stat.size) {
            let path = root.appendingPathComponent(f.path).path
            let hash = try hashFile(atPath: path, uncached: true)
            // If the file changed while we read it, leave it unhashed; the next index pass picks it up.
            guard statFile(atPath: path) == f.stat else { continue }
            try store.query("UPDATE indexed_file SET hash = ?, hash_verified_at = ? WHERE volume_id = ? AND path = ?",
                            [.text(hash), .real(Date().timeIntervalSince1970), .text(dest.id), .text(f.path)])
        }
    }
}
