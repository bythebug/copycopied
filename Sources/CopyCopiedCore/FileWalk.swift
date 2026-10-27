import Foundation

public struct FileStat: Sendable, Equatable {
    public var size: Int64
    public var mtime: Double
    public var inode: UInt64
}

/// lstat without following links; nil unless it's a regular file.
public func statFile(atPath path: String) -> FileStat? {
    var st = stat()
    guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
    let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    return FileStat(size: Int64(st.st_size), mtime: mtime, inode: UInt64(st.st_ino))
}

let junkNames: Set<String> = [
    ".Spotlight-V100", ".fseventsd", ".Trashes", ".DS_Store", "System Volume Information",
    ".TemporaryItems", ".DocumentRevisions-V100",
]

public let partialSuffix = ".copycopied-partial"

func isJunk(_ name: String) -> Bool {
    junkNames.contains(name) || name.hasPrefix("._") || name.hasSuffix(partialSuffix)
}

/// Every regular file under `root` (relative path + stat), skipping system junk. Read-only.
public func walkFiles(_ root: URL) -> [(path: String, stat: FileStat)] {
    guard let e = FileManager.default.enumerator(atPath: root.path) else { return [] }
    var out: [(String, FileStat)] = []
    while let rel = e.nextObject() as? String {
        if isJunk((rel as NSString).lastPathComponent) {
            // Only for junk folders: on a file, skipDescendants() skips the enclosing folder and drops real files.
            if e.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { e.skipDescendants() }
            continue
        }
        if let st = statFile(atPath: root.appendingPathComponent(rel).path) { out.append((rel, st)) }
    }
    return out
}
