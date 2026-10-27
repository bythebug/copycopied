import Foundation

public struct DriveCheck: Sendable, Equatable {
    public var drive: Destination
    public var missing: [CardFile]  // relevant card files with no same-size+same-hash file on the drive
    public var asOf: Date?  // last index time; matters when the drive isn't connected
    public var connected: Bool { drive.root != nil }
}

public enum Verdict: Sendable, Equatable {
    case reading(n: Int, total: Int)
    case notBacked(missing: Int, total: Int, drive: String)
    case partiallyBacked(missing: Int, total: Int, drive: String)
    case fromMemory(missing: Int, drive: String, asOf: Date?)
    case copying(n: Int, total: Int)
    case verifying(n: Int, total: Int)
    case backed(total: Int, drives: [String])
    case problem(String)

    public enum Orb: String, Sendable { case red, grey, green }

    public var orb: Orb {
        switch self {
        case .notBacked, .partiallyBacked, .problem: .red
        case .reading, .fromMemory, .copying, .verifying: .grey
        case .backed: .green
        }
    }

    /// Green requires every required drive connected with nothing missing. Memory alone is never green (safety rule 3).
    public static func from(total: Int, checks: [DriveCheck]) -> Verdict {
        guard !checks.isEmpty else { return .problem("No working drive chosen yet.") }
        if let worst = checks.filter(\.connected).max(by: { $0.missing.count < $1.missing.count }), !worst.missing.isEmpty {
            let m = worst.missing.count
            return m == total ? .notBacked(missing: m, total: total, drive: worst.drive.name)
                : .partiallyBacked(missing: m, total: total, drive: worst.drive.name)
        }
        if let away = checks.first(where: { !$0.connected }) {
            return .fromMemory(missing: away.missing.count, drive: away.drive.name, asOf: away.asOf)
        }
        return .backed(total: total, drives: checks.map(\.drive.name))
    }

    public var lines: [String] {
        switch self {
        case let .reading(n, total):
            return ["Reading \(n) of \(total) files on the card…"]
        case let .notBacked(m, total, drive), let .partiallyBacked(m, total, drive):
            return ["\(m) of \(total) \(m == 1 && total == 1 ? "file" : "files") \(m == 1 ? "isn't" : "aren't") on \(drive) yet. Don't format."]
        case let .fromMemory(m, drive, asOf):
            let when = asOf.map { " as of " + Self.dayFormat.string(from: $0) } ?? ""
            return [m == 0 ? "Nothing to copy" : "\(m) \(m == 1 ? "file" : "files") to copy",
                    "From memory — \(drive)\(when).",
                    "Plug it in to confirm before formatting."]
        case let .copying(n, total):
            return ["Copying \(n) of \(total)…"]
        case let .verifying(n, total):
            return ["Checking \(n) of \(total)…"]
        case let .backed(total, _):
            return ["\(total) / \(total) files copied. Each one read back and checked."]
        case let .problem(reason):
            return [reason]
        }
    }

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE d MMM"
        return f
    }()
}

/// "Is it backed?": content matching by size, then xxh3, never by name (safety rule 5).
public struct Matcher {
    public let store: Store

    public init(store: Store) { self.store = store }

    /// Connected drives are re-indexed (re-stat'd) first so cached hashes are only trusted when the stat key still holds.
    /// `progress(n, total)` reports card files examined.
    public func check(cardRoot: URL, files: [CardFile], drives: [Destination],
                      progress: (Int, Int) -> Void = { _, _ in }) throws -> [DriveCheck] {
        let relevant = files.filter(\.kind.isRelevant)
        let sizes = Set(relevant.map(\.size))
        let indexer = Indexer(store: store)
        for d in drives where d.root != nil {
            try indexer.index(d)
            try indexer.hashCandidates(d, sizes: sizes)
        }
        // size → hashes present on each drive (unhashed rows on a disconnected drive can't vouch for anything)
        let byDrive = try drives.map { d in
            Dictionary(grouping: try store.indexedFiles(volumeID: d.id).filter { sizes.contains($0.stat.size) },
                       by: \.stat.size).mapValues { Set($0.compactMap(\.hash)) }
        }

        var cardHashes: [String: String] = [:]
        var missing = Array(repeating: [CardFile](), count: drives.count)
        for (n, f) in relevant.enumerated() {
            progress(n + 1, relevant.count)
            for i in drives.indices {
                guard let hashes = byDrive[i][f.size], !hashes.isEmpty else { missing[i].append(f); continue }
                let h = try cardHashes[f.path] ?? hashFile(atPath: cardRoot.appendingPathComponent(f.path).path, uncached: false)
                cardHashes[f.path] = h
                if !hashes.contains(h) { missing[i].append(f) }
            }
        }
        return try drives.indices.map {
            DriveCheck(drive: drives[$0], missing: missing[$0], asOf: try store.volume(id: drives[$0].id)?.lastIndexed)
        }
    }
}
