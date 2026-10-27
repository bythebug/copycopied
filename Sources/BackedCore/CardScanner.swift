import Foundation

public enum FileKind: String, Sendable, CaseIterable {
    case video, photo, audio, sidecar, proxy, other

    /// Kinds that must be copied for a card to be green (PLAN.md D9).
    public var isRelevant: Bool { self != .other }
}

public struct CardFile: Sendable, Equatable {
    public var path: String  // relative to the card root
    public var size: Int64
    public var mtime: Double
    public var kind: FileKind
}

public enum CardScanner {
    static let videoExt: Set<String> = ["mp4", "mov", "mxf", "mts", "m2ts", "braw", "crm", "avi", "mkv", "insv"]
    static let photoExt: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "arw", "cr2", "cr3", "nef", "nrw", "rw2", "raf", "dng", "orf", "tif", "tiff",
        "png", "srw", "pef",
    ]
    static let audioExt: Set<String> = ["wav", "mp3", "aiff", "aif", "m4a", "flac", "bwf"]
    static let sidecarExt: Set<String> = ["xml", "xmp", "thm", "lrv", "srt"]

    // TODO(verify): marker paths are from common knowledge of card layouts, not checked on real cards.
    static let cardMarkers = ["DCIM", "PRIVATE/M4ROOT", "PRIVATE/AVCHD", "CLIP", "CONTENTS", "XDROOT"]

    /// True when the folder layout looks like a camera card.
    public static func looksLikeCard(_ root: URL) -> Bool {
        let fm = FileManager.default
        if cardMarkers.contains(where: { fm.fileExists(atPath: root.appendingPathComponent($0).path) }) { return true }
        // Blackmagic cameras write .braw at or near the root. TODO(verify) exact layout per body.
        let top = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return top.contains { $0.lowercased().hasSuffix(".braw") }
    }

    /// Classifies by extension/path alone. Sidecars are refined in `scan` (they need a parent clip).
    public static func classify(_ path: String) -> FileKind {
        let ext = (path as NSString).pathExtension.lowercased()
        let upper = path.uppercased()
        // Sony proxies live in PRIVATE/M4ROOT/SUB. TODO(verify) other brands' proxy folders.
        if videoExt.contains(ext), upper.contains("/M4ROOT/SUB/") || upper.contains("/PROXY/") { return .proxy }
        if videoExt.contains(ext) { return .video }
        if photoExt.contains(ext) { return .photo }
        if audioExt.contains(ext) { return .audio }
        if sidecarExt.contains(ext) { return .sidecar }
        return .other
    }

    /// Walks the whole card read-only and classifies every file.
    /// A sidecar only counts as one when a media file in the same folder has a stem that prefixes it
    /// (C0001.MP4 ↔ C0001M01.XML, GX010001.MP4 ↔ GX010001.THM); otherwise it's a camera catalog file → `.other`.
    public static func scan(_ root: URL) -> [CardFile] {
        var files = walkFiles(root).map {
            CardFile(path: $0.path, size: $0.stat.size, mtime: $0.stat.mtime, kind: classify($0.path))
        }
        var mediaStems: [String: [String]] = [:]  // dir → stems
        for f in files where [.video, .photo, .audio, .proxy].contains(f.kind) {
            mediaStems[dir(f.path), default: []].append(stem(f.path))
        }
        for i in files.indices where files[i].kind == .sidecar {
            let s = stem(files[i].path)
            if !(mediaStems[dir(files[i].path)] ?? []).contains(where: { s.hasPrefix($0) }) { files[i].kind = .other }
        }
        return files
    }

    static func dir(_ p: String) -> String { (p as NSString).deletingLastPathComponent }
    static func stem(_ p: String) -> String { ((p as NSString).lastPathComponent as NSString).deletingPathExtension.uppercased() }
}
