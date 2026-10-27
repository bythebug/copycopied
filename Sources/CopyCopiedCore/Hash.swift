import CXXHash
import Foundation

public enum CoreError: Error, CustomStringConvertible, Equatable {
    case io(op: String, path: String, errno: Int32)
    case db(String)

    public var description: String {
        switch self {
        case let .io(op, path, err): "\(op) failed for \(path): \(String(cString: strerror(err)))"
        case let .db(msg): "Database error: \(msg)"
        }
    }
}

/// Streaming xxh3-128 (see PLAN.md D2). Digest is 32 lowercase hex chars.
public final class XXH3Hasher {
    private let state = XXH3_createState()!

    public init() { XXH3_128bits_reset(state) }
    deinit { XXH3_freeState(state) }

    public func update(_ bytes: UnsafeRawBufferPointer) {
        XXH3_128bits_update(state, bytes.baseAddress, bytes.count)
    }

    public func digest() -> String {
        let h = XXH3_128bits_digest(state)
        return String(format: "%016llx%016llx", h.high64, h.low64)
    }
}

public let hashChunkSize = 8 << 20

/// Hashes a file read-only. `uncached` sets F_NOCACHE so the bytes come from the disk, not the page cache.
public func hashFile(atPath path: String, uncached: Bool) throws -> String {
    let fd = open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw CoreError.io(op: "open", path: path, errno: errno) }
    defer { close(fd) }
    if uncached { _ = fcntl(fd, F_NOCACHE, 1) }

    let hasher = XXH3Hasher()
    let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: hashChunkSize, alignment: 16384)
    defer { buf.deallocate() }
    while true {
        if Task.isCancelled { throw CancellationError() }
        let n = read(fd, buf.baseAddress, hashChunkSize)
        if n < 0 {
            if errno == EINTR { continue }
            throw CoreError.io(op: "read", path: path, errno: errno)
        }
        if n == 0 { break }
        hasher.update(UnsafeRawBufferPointer(rebasing: buf[0..<n]))
    }
    return hasher.digest()
}
