import BackedCore
import Foundation

let usage = """
    usage:
      backed-cli volumes                                   list mounted volumes and their roles
      backed-cli role <volume-path> working|backup|card|ignored|auto
      backed-cli status [--card <path>]... [--drive <path>]...
                         verdict for each card; defaults: detected cards vs. drives marked working/backup
      backed-cli copy --to <folder> [--card <path>] [--keep-structure]
                         copy what's missing from the card (by content) into <folder>, verify each file;
                         files go flat into <folder> unless --keep-structure keeps the card's folders
    options: --db <path>  use another database (default ~/Library/Application Support/backed/backed.sqlite)
    """

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())

/// Removes every `--name value` pair from args and returns the values.
@MainActor func take(_ name: String) -> [String] {
    var out: [String] = []
    while let i = args.firstIndex(of: name) {
        guard i + 1 < args.count else { fail("\(name) needs a value") }
        out.append(args[i + 1])
        args.removeSubrange(i...i + 1)
    }
    return out
}

func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

let roleNames: [String: VolumeRole?] = [
    "working": .workingDrive, "backup": .backupDrive, "card": .card, "ignored": .ignored, "auto": nil,
]

do {
    let dbPath = try take("--db").last ?? Store.defaultURL().path
    let store = try Store(path: dbPath)
    let known = Dictionary(try store.volumes().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let mounted = Volumes.mounted()

    switch args.first {
    case "volumes":
        for v in mounted {
            let role = known[v.id]?.role?.rawValue ?? (v.isCard(role: nil) ? "card (auto)" : "not used")
            print("\(v.name)\t\(role)\t\(v.url.path)\t\(v.id)")
        }
        for r in known.values where r.role != nil && !mounted.contains(where: { $0.id == r.id }) {
            print("\(r.name)\t\(r.role!.rawValue)\tnot connected\t\(r.id)")
        }

    case "role":
        guard args.count == 3, let role = roleNames[args[2]] else { fail(usage) }
        let d = Volumes.destination(for: url(args[1]))
        guard FileManager.default.fileExists(atPath: d.root!.path) else { fail("No such path: \(args[1])") }
        try store.setRole(role, id: d.id, name: d.name)
        print("\(d.name): \(args[2])")

    case "status":
        let cards: [(name: String, root: URL)] = {
            let explicit = take("--card")
            if !explicit.isEmpty { return explicit.map { (url($0).lastPathComponent, url($0)) } }
            return mounted.filter { $0.isCard(role: known[$0.id]?.role) }.map { ($0.name, $0.url) }
        }()
        let drives: [Destination] = {
            let explicit = take("--drive")
            if !explicit.isEmpty { return explicit.map { Volumes.destination(for: url($0)) } }
            return known.values.filter { $0.role == .workingDrive || $0.role == .backupDrive }
                .sorted { $0.name < $1.name }
                .map { r in Destination(id: r.id, name: r.name, root: mounted.first { $0.id == r.id }?.url) }
        }()
        if cards.isEmpty { print("No card connected.") }

        let matcher = Matcher(store: store)
        for card in cards {
            let files = CardScanner.scan(card.root)
            let total = files.filter(\.kind.isRelevant).count
            let tty = isatty(STDERR_FILENO) == 1
            let checks = try matcher.check(cardRoot: card.root, files: files, drives: drives) { n, total in
                if tty { FileHandle.standardError.write(Data("\r\(Verdict.reading(n: n, total: total).lines[0])".utf8)) }
            }
            if tty { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
            let verdict = Verdict.from(total: total, checks: checks)
            print("\(card.name) [\(verdict.orb.rawValue)]")
            for line in verdict.lines { print("  \(line)") }
            for c in checks where checks.count > 1 {
                print("  · \(c.drive.name): \(c.connected ? "" : "(not connected) ")\(c.missing.count) missing")
            }
        }

    case "copy":
        guard let toArg = take("--to").last else { fail(usage) }
        let to = url(toArg).standardizedFileURL.resolvingSymlinksInPath()
        let keepStructure = args.contains("--keep-structure")
        let explicit = take("--card")
        let cardRoots = explicit.isEmpty ? mounted.filter { $0.isCard(role: known[$0.id]?.role) }.map(\.url) : explicit.map(url)
        guard cardRoots.count == 1, let cardRoot = cardRoots.first else {
            fail(cardRoots.isEmpty ? "No card connected." : "Several cards connected; pick one with --card <path>.")
        }
        // Match against the whole drive holding <folder>, so files already anywhere on it aren't copied again.
        let dest = Volumes.containing(to)?.destination ?? Volumes.destination(for: to)
        let matcher = Matcher(store: store)
        let files = CardScanner.scan(cardRoot)
        let total = files.filter(\.kind.isRelevant).count
        let missing = try matcher.check(cardRoot: cardRoot, files: files, drives: [dest])[0].missing

        if !missing.isEmpty {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let log = try CopyLog(url: Store.defaultURL().deletingLastPathComponent()
                .appendingPathComponent("logs/\(stamp) \(cardRoot.lastPathComponent).jsonl"))
            let requests = missing.map {
                CopyRequest(source: cardRoot.appendingPathComponent($0.path),
                            destination: to.appendingPathComponent(keepStructure ? $0.path : ($0.path as NSString).lastPathComponent))
            }
            let tty = isatty(STDERR_FILENO) == 1
            let outcomes: [CopyOutcome]
            do {
                outcomes = try Copier(log: log).copy(requests) { e in
                    guard tty else { return }
                    let v: Verdict = switch e {
                    case let .copying(n, t, _): .copying(n: n, total: t)
                    case let .verifying(n, t, _): .verifying(n: n, total: t)
                    }
                    FileHandle.standardError.write(Data("\r\(v.lines[0])\u{1B}[K".utf8))
                }
                if tty { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
            } catch {
                if isatty(STDERR_FILENO) == 1 { FileHandle.standardError.write(Data("\n".utf8)) }
                // I/O or device errors mid-copy almost always mean the card or drive was pulled.
                var reason = "\(error)"
                if case let BackedError.io(_, path, err) = error, [EIO, ENXIO, ENODEV, ENOENT].contains(err) {
                    let who = path.hasPrefix(cardRoot.path) ? cardRoot.lastPathComponent : dest.name
                    reason = "Lost contact with \(who) while copying (was it unplugged?). Plug it back in and copy again; only what's still missing will be copied."
                }
                print("\(cardRoot.lastPathComponent) [red]\n  \(reason)\n  Log: \(log.url.path)")
                exit(1)
            }
            let indexer = Indexer(store: store)
            for o in outcomes {
                let rel = String(o.finalURL.path.dropFirst(dest.root!.path.count + 1))
                try indexer.record(dest, path: rel, hash: o.hash)
                if o.renamed { print("  \(o.source.lastPathComponent) → \(o.finalURL.lastPathComponent) (a different file already had that name)") }
            }
            print("  Log: \(log.url.path)")
        }
        let verdict = Verdict.from(total: total, checks: try matcher.check(cardRoot: cardRoot, files: files, drives: [dest]))
        print("\(cardRoot.lastPathComponent) [\(verdict.orb.rawValue)]")
        for line in verdict.lines { print("  \(line)") }

    default:
        print(usage)
    }
} catch {
    fail("\(error)")
}
