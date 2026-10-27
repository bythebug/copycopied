import Foundation
import IOKit.pwr_mgt

public struct CopyRequest: Sendable {
    public var source: URL
    public var destination: URL  // wanted final path; may end up numbered if it clashes
    public var expectedHash: String?  // from an earlier, independent read of the source, if any

    public init(source: URL, destination: URL, expectedHash: String? = nil) {
        self.source = source
        self.destination = destination
        self.expectedHash = expectedHash
    }
}

public struct CopyOutcome: Sendable, Equatable {
    public var source: URL
    public var finalURL: URL
    public var hash: String
    public var renamed: Bool  // landed under a non-clashing name (safety rule 4)
    public var alreadyThere: Bool  // identical file already at the wanted path; nothing written
}

public enum CopyEvent: Sendable, Equatable {
    case copying(n: Int, total: Int, file: String)
    case verifying(n: Int, total: Int, file: String)
}

public enum CopyError: Error, CustomStringConvertible, Equatable {
    case notEnoughSpace(needed: Int64, free: Int64)
    case tooLargeForFAT32(String)
    case verifyFailed(String)
    case sourceChanged(String)
    case destinationIsCard(String)

    public var description: String {
        let gb = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        switch self {
        case let .notEnoughSpace(needed, free): return "Not enough space: needs \(gb(needed)), only \(gb(free)) free. Nothing was copied."
        case let .tooLargeForFAT32(f): return "\(f) is 4 GB or larger and the drive is FAT32, which can't hold it. Use an exFAT or APFS drive."
        case let .verifyFailed(f): return "\(f) didn't match the card after copying twice. It wasn't saved. Check the drive and try again."
        case let .destinationIsCard(card): return "That folder is on \(card), a memory card. CopyCopied never writes to cards. Choose a folder on a drive."
        case let .sourceChanged(f): return "\(f) read differently from the card than it did a moment ago. Check the card reader and try again."
        }
    }
}

/// Copy → F_FULLFSYNC → uncached read-back → atomic, non-overwriting rename (safety rules 2, 4, 6).
public final class Copier {
    /// Test hook: runs on each written partial after it's synced, before it's verified (byte-flip test, spec §11).
    public var beforeVerify: (URL) -> Void = { _ in }
    /// Card roots. Nothing is ever written, renamed or deleted under these (safety rule 1).
    public var readOnlyRoots: [URL] = []
    let log: CopyLog?

    public init(log: CopyLog? = nil) { self.log = log }

    public static let fat32Limit: Int64 = 4 << 30

    /// Why a batch can't start, or nil. Pure, so it's testable without real drives.
    public static func preflight(sizes: [Int64], free: Int64, fsType: String) -> CopyError? {
        if fsType == "msdos", sizes.contains(where: { $0 >= fat32Limit }) { return .tooLargeForFAT32("A file") }
        let needed = sizes.reduce(0, +)
        return needed > free ? .notEnoughSpace(needed: needed, free: free) : nil
    }

    /// Free bytes and filesystem type ("apfs", "exfat", "msdos", …) for the volume holding `url` (or its nearest existing parent).
    public static func space(at url: URL) -> (free: Int64, fsType: String)? {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.path != "/" { u = u.deletingLastPathComponent() }
        var s = statfs()
        guard statfs(u.path, &s) == 0 else { return nil }
        let type = withUnsafeBytes(of: s.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return (Int64(s.f_bavail) * Int64(s.f_bsize), type)
    }

    /// Copies in order and stops at the first failure; already-finished files stay (they're verified).
    /// Assumes every destination is on one volume.
    public func copy(_ requests: [CopyRequest], progress: (CopyEvent) -> Void = { _ in }) throws -> [CopyOutcome] {
        guard let first = requests.first else { return [] }
        // Checked before anything touches the disk, including the partial sweep below.
        let real = { (u: URL) in u.standardizedFileURL.resolvingSymlinksInPath().path }
        for r in requests {
            let dst = real(r.destination)
            if let card = readOnlyRoots.first(where: { dst == real($0) || dst.hasPrefix(real($0) + "/") }) {
                throw CopyError.destinationIsCard(card.lastPathComponent)
            }
        }
        let sizes = requests.map { statFile(atPath: $0.source.path)?.size ?? 0 }
        if let space = Self.space(at: first.destination),
           let e = Self.preflight(sizes: sizes, free: space.free, fsType: space.fsType) {
            if case .tooLargeForFAT32 = e, let big = requests.indices.first(where: { sizes[$0] >= Self.fat32Limit }) {
                throw CopyError.tooLargeForFAT32(requests[big].source.lastPathComponent)
            }
            throw e
        }

        // Keep the Mac awake while copying (PLAN.md D11). Lid-close sleep still happens; resume covers it.
        var assertion = IOPMAssertionID(0)
        IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "CopyCopied is copying a card" as CFString, &assertion)
        defer { IOPMAssertionRelease(assertion) }

        // Partials left by an interrupted run (drive pulled, crash) are ours to delete.
        // ponytail: assumes one copy at a time per destination drive; the app's per-drive queue guarantees it.
        for dir in Set(requests.map { $0.destination.deletingLastPathComponent() }) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(partialSuffix) {
                unlink(dir.appendingPathComponent(name).path)
                log?.write("removed-partial", ["path": dir.appendingPathComponent(name).path])
            }
        }

        var out: [CopyOutcome] = []
        for (i, r) in requests.enumerated() {
            try Task.checkCancellation()
            let name = r.source.lastPathComponent
            progress(.copying(n: i + 1, total: requests.count, file: name))
            do {
                out.append(try copyOne(r) { progress(.verifying(n: i + 1, total: requests.count, file: name)) })
            } catch {
                log?.write("failed", ["source": r.source.path, "error": "\(error)"])
                throw error
            }
        }
        return out
    }

    func copyOne(_ r: CopyRequest, verifying: () -> Void) throws -> CopyOutcome {
        let fm = FileManager.default
        let dir = r.destination.deletingLastPathComponent()
        var missingDirs: [URL] = []
        var d = dir
        while !fm.fileExists(atPath: d.path) { missingDirs.insert(d, at: 0); d = d.deletingLastPathComponent() }
        for d in missingDirs {
            try fm.createDirectory(at: d, withIntermediateDirectories: false)
            log?.write("folder", ["path": d.path])
        }

        let partial = dir.appendingPathComponent(r.destination.lastPathComponent + partialSuffix)
        defer { unlink(partial.path) }  // never leave a partial behind, whatever happens

        let name = r.source.lastPathComponent
        var hash = try writePartial(from: r.source, to: partial)
        if let e = r.expectedHash, e != hash { throw CopyError.sourceChanged(name) }

        verifying()
        // PLAN.md D12: re-read once; if still wrong, re-copy once.
        var ok = try verify(partial, hash)
        if !ok {
            log?.write("recopy", ["source": r.source.path])
            hash = try writePartial(from: r.source, to: partial)
            if let e = r.expectedHash, e != hash { throw CopyError.sourceChanged(name) }
            ok = try verify(partial, hash)
        }
        guard ok else { throw CopyError.verifyFailed(name) }

        if let attrs = try? fm.attributesOfItem(atPath: r.source.path) {
            try? fm.setAttributes([.modificationDate: attrs[.modificationDate], .creationDate: attrs[.creationDate]]
                .compactMapValues { $0 }, ofItemAtPath: partial.path)
        }

        let placed = try place(partial, at: r.destination, hash: hash)
        log?.write(placed.alreadyThere ? "already-there" : "copied", [
            "source": r.source.path, "destination": placed.url.path, "xxh3_128": hash,
            "size": String(statFile(atPath: placed.url.path)?.size ?? -1),
        ])
        return CopyOutcome(source: r.source, finalURL: placed.url, hash: hash,
                           renamed: placed.url != r.destination && !placed.alreadyThere, alreadyThere: placed.alreadyThere)
    }

    private func verify(_ partial: URL, _ hash: String) throws -> Bool {
        beforeVerify(partial)
        for _ in 0..<2 {
            if try hashFile(atPath: partial.path, uncached: true) == hash { return true }
        }
        return false
    }

    /// Streams source → partial, hashing as it goes, then F_FULLFSYNC. Returns the source hash.
    private func writePartial(from src: URL, to partial: URL) throws -> String {
        unlink(partial.path)  // a stale partial from an interrupted run is ours to remove
        let input = open(src.path, O_RDONLY | O_NOFOLLOW)
        guard input >= 0 else { throw CoreError.io(op: "open", path: src.path, errno: errno) }
        defer { close(input) }
        let output = open(partial.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o644))
        guard output >= 0 else { throw CoreError.io(op: "create", path: partial.path, errno: errno) }
        defer { close(output) }
        // Keep written pages out of the cache so the read-back has to come from the disk.
        // TODO(verify): measure on real exFAT/APFS drives that F_NOCACHE read-back hits the device.
        _ = fcntl(output, F_NOCACHE, 1)

        let hasher = XXH3Hasher()
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: hashChunkSize, alignment: 16384)
        defer { buf.deallocate() }
        while true {
            try Task.checkCancellation()
            let n = read(input, buf.baseAddress, hashChunkSize)
            if n < 0 {
                if errno == EINTR { continue }
                throw CoreError.io(op: "read", path: src.path, errno: errno)
            }
            if n == 0 { break }
            hasher.update(UnsafeRawBufferPointer(rebasing: buf[0..<n]))
            var off = 0
            while off < n {
                let w = write(output, buf.baseAddress! + off, n - off)
                if w < 0 {
                    if errno == EINTR { continue }
                    throw CoreError.io(op: "write", path: partial.path, errno: errno)
                }
                off += w
            }
        }
        if fcntl(output, F_FULLFSYNC) != 0 {
            // TODO(verify): which destination filesystems refuse F_FULLFSYNC (exFAT?).
            log?.write("fsync-fallback", ["path": partial.path, "errno": String(errno)])
            guard fsync(output) == 0 else { throw CoreError.io(op: "fsync", path: partial.path, errno: errno) }
        }
        return hasher.digest()
    }

    /// Renames the verified partial into place without ever replacing an existing file.
    /// A clash with different content gets "C0001 (2).MP4"; identical content already there is left alone.
    private func place(_ partial: URL, at wanted: URL, hash: String) throws -> (url: URL, alreadyThere: Bool) {
        var candidate = wanted
        var n = 1
        while true {
            var rc = renamex_np(partial.path, candidate.path, UInt32(RENAME_EXCL))
            var clash = rc != 0 && errno == EEXIST
            if rc != 0, errno == ENOTSUP || errno == EINVAL {
                // ponytail: check-then-rename on filesystems without RENAME_EXCL; only racy if something else writes the same name.
                clash = access(candidate.path, F_OK) == 0
                rc = clash ? -1 : rename(partial.path, candidate.path)
            }
            if rc == 0 { return (candidate, false) }
            guard clash else { throw CoreError.io(op: "rename", path: candidate.path, errno: errno) }
            if (try? hashFile(atPath: candidate.path, uncached: true)) == hash { return (candidate, true) }
            n += 1
            candidate = Self.numbered(wanted, n)
        }
    }

    /// "C0001.MP4", 2 → "C0001 (2).MP4"
    public static func numbered(_ url: URL, _ n: Int) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(stem) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
    }
}

/// Append-only JSON-lines log of every folder created and file copied (safety rule 7).
/// Fields chosen so an MHL export can be generated from it later.
public final class CopyLog {
    public let url: URL
    private let handle: FileHandle

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
    }

    deinit { try? handle.close() }

    public func write(_ event: String, _ fields: [String: String]) {
        var entry = fields
        entry["event"] = event
        entry["time"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        handle.write(data + Data("\n".utf8))
    }
}
