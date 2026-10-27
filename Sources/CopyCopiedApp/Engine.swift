import CopyCopiedCore
import Foundation

/// Owns the database and does all disk work off the main thread. One call at a time, which also means
/// one copy at a time per drive (the copier's partial sweep relies on it).
/// ponytail: one actor serialises every card; split into per-drive queues when parallel offloads matter.
actor Engine {
    private let store: Store

    /// `COPYCOPIED_DB` points the app at another database (used for fake-card testing).
    init() throws { store = try Store(path: ProcessInfo.processInfo.environment["COPYCOPIED_DB"] ?? Store.defaultURL().path) }

    func roles() throws -> [String: VolumeRole] {
        Dictionary(try store.volumes().compactMap { r in r.role.map { (r.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    func setRole(_ role: VolumeRole?, id: String, name: String) throws {
        try store.setRole(role, id: id, name: name)
    }

    struct Check: Sendable {
        var files: [CardFile]
        var total: Int
        var checks: [DriveCheck]
        var verdict: Verdict
    }

    func check(cardRoot: URL, progress: @Sendable (Int, Int) -> Void) throws -> Check {
        let files = CardScanner.scan(cardRoot)
        let total = files.filter(\.kind.isRelevant).count
        progress(0, total)
        let drives = try Offload.drives(store: store, mounted: Volumes.mounted())
        let checks = try Matcher(store: store).check(cardRoot: cardRoot, files: files, drives: drives, progress: progress)
        return Check(files: files, total: total, checks: checks, verdict: Verdict.from(total: total, checks: checks))
    }

    /// Copies what's missing into `folder`. If its drive has no role yet it becomes a working drive,
    /// since that's where the user just chose to keep this card.
    func copy(cardRoot: URL, to folder: URL, progress: @Sendable (CopyEvent) -> Void) throws -> URL {
        do { try Offload.refuseCardFolder(folder, cardRoot: cardRoot, store: store) } catch {
            throw CopyFailure(message: "\(error)")
        }
        let dest = Offload.destination(containing: folder)
        let files = CardScanner.scan(cardRoot)
        let missing = try Matcher(store: store).check(cardRoot: cardRoot, files: files, drives: [dest])[0].missing
        defer {
            // After the card check above, so a card can never become a working drive.
            if (try? store.volume(id: dest.id)?.role) ?? nil == nil {
                try? store.setRole(.workingDrive, id: dest.id, name: dest.name)
            }
        }
        guard !missing.isEmpty else { return folder }
        let log = try Offload.newLog(cardName: cardRoot.lastPathComponent)
        do {
            _ = try Offload.copyMissing(cardRoot: cardRoot, missing: missing, to: folder, dest: dest, store: store,
                                        log: log, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CopyFailure(message: Offload.explain(error, cardRoot: cardRoot, driveName: dest.name))
        }
        return folder
    }

    struct CopyFailure: Error { var message: String }
}
