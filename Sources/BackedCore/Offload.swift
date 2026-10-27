import Foundation

/// The steps shared by the app and the CLI: which drives count, copy what's missing, explain failures.
public enum Offload {
    /// Working and backup drives from the store. Connected ones get a root; the rest are memory only.
    public static func drives(store: Store, mounted: [MountedVolume]) throws -> [Destination] {
        try store.volumes().filter { $0.role == .workingDrive || $0.role == .backupDrive }.map { r in
            let root: URL? = if r.id.hasPrefix("dir:") {
                FileManager.default.fileExists(atPath: String(r.id.dropFirst(4))) ? URL(fileURLWithPath: String(r.id.dropFirst(4))) : nil
            } else {
                mounted.first { $0.id == r.id }?.url
            }
            return Destination(id: r.id, name: r.name, root: root)
        }
    }

    /// The whole drive holding `folder`, so files already anywhere on it aren't copied again; a plain folder off the boot disk.
    public static func destination(containing folder: URL) -> Destination {
        Volumes.containing(folder)?.destination ?? Volumes.destination(for: folder)
    }

    /// Throws when `folder` is on the card being offloaded or any other mounted card. Call before matching:
    /// a card compared against itself looks fully backed (false green), and nothing may be written there (rule 1).
    public static func refuseCardFolder(_ folder: URL, cardRoot: URL, store: Store) throws {
        let roles = Dictionary(try store.volumes().compactMap { r in r.role.map { (r.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let real = { (u: URL) in u.standardizedFileURL.resolvingSymlinksInPath().path }
        let f = real(folder)
        let cards = [cardRoot] + Volumes.mounted().filter { $0.isCard(role: roles[$0.id]) }.map(\.url)
        if let card = cards.first(where: { f == real($0) || f.hasPrefix(real($0) + "/") }) {
            throw CopyError.destinationIsCard(card.lastPathComponent)
        }
    }

    public static func newLog(cardName: String) throws -> CopyLog {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return try CopyLog(url: Store.defaultURL().deletingLastPathComponent()
            .appendingPathComponent("logs/\(stamp) \(cardName).jsonl"))
    }

    /// Copies `missing` card files into `folder` (flat, or keeping the card's folders), verified,
    /// and records each in the drive's index so the re-check needn't read them again.
    public static func copyMissing(cardRoot: URL, missing: [CardFile], to folder: URL, dest: Destination,
                                   keepStructure: Bool = false, store: Store, log: CopyLog?,
                                   progress: (CopyEvent) -> Void = { _ in }) throws -> [CopyOutcome] {
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath()
        let requests = missing.map {
            CopyRequest(source: cardRoot.appendingPathComponent($0.path),
                        destination: folder.appendingPathComponent(keepStructure ? $0.path : ($0.path as NSString).lastPathComponent))
        }
        let copier = Copier(log: log)
        let roles = Dictionary(try store.volumes().compactMap { r in r.role.map { (r.id, $0) } }, uniquingKeysWith: { a, _ in a })
        copier.readOnlyRoots = [cardRoot] + Volumes.mounted().filter { $0.isCard(role: roles[$0.id]) }.map(\.url)
        let outcomes = try copier.copy(requests, progress: progress)
        let indexer = Indexer(store: store)
        let root = dest.root!.standardizedFileURL.resolvingSymlinksInPath().path
        for o in outcomes {
            try indexer.record(dest, path: String(o.finalURL.path.dropFirst(root.count + 1)), hash: o.hash)
        }
        return outcomes
    }

    /// Plain-language reason for a failed copy. I/O or device errors mid-copy almost always mean something was unplugged.
    public static func explain(_ error: Error, cardRoot: URL, driveName: String) -> String {
        if case let BackedError.io(_, path, err) = error, [EIO, ENXIO, ENODEV, ENOENT].contains(err) {
            let who = path.hasPrefix(cardRoot.path) ? cardRoot.lastPathComponent : driveName
            return "Lost contact with \(who) while copying (was it unplugged?). Plug it back in and copy again; only what's still missing will be copied."
        }
        return "\(error)"
    }
}
