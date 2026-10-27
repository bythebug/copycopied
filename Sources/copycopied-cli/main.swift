import CopyCopiedCore
import Foundation

let usage = """
    usage:
      copycopied-cli volumes                                   list mounted volumes and their roles
      copycopied-cli role <volume-path> working|backup|card|ignored|auto
      copycopied-cli status [--card <path>]... [--drive <path>]...
                         verdict for each card; defaults: detected cards vs. drives marked working/backup
      copycopied-cli copy --to <folder> [--card <path>] [--keep-structure]
                         copy what's missing from the card (by content) into <folder>, verify each file;
                         files go flat into <folder> unless --keep-structure keeps the card's folders
    options: --db <path>  use another database (default ~/Library/Application Support/CopyCopied/copycopied.sqlite)
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
        let drives: [Destination] = try {
            let explicit = take("--drive")
            if !explicit.isEmpty { return explicit.map { Volumes.destination(for: url($0)) } }
            return try Offload.drives(store: store, mounted: mounted)
        }()
        if cards.isEmpty { print("No card connected.") }

        let matcher = Matcher(store: store)
        for card in cards {
            // A card is never its own (or another card's) backup; matching it would look green.
            for d in drives where d.root != nil {
                do { try Offload.refuseCardFolder(d.root!, cardRoot: card.root, store: store) } catch { fail("\(error)") }
            }
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
        do { try Offload.refuseCardFolder(to, cardRoot: cardRoot, store: store) } catch { fail("\(error)") }
        let dest = Offload.destination(containing: to)
        let matcher = Matcher(store: store)
        let files = CardScanner.scan(cardRoot)
        let total = files.filter(\.kind.isRelevant).count
        let missing = try matcher.check(cardRoot: cardRoot, files: files, drives: [dest])[0].missing

        if !missing.isEmpty {
            let log = try Offload.newLog(cardName: cardRoot.lastPathComponent)
            let tty = isatty(STDERR_FILENO) == 1
            let outcomes: [CopyOutcome]
            do {
                outcomes = try Offload.copyMissing(cardRoot: cardRoot, missing: missing, to: to, dest: dest,
                                                   keepStructure: keepStructure, store: store, log: log) { e in
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
                let reason = Offload.explain(error, cardRoot: cardRoot, driveName: dest.name)
                print("\(cardRoot.lastPathComponent) [red]\n  \(reason)\n  Log: \(log.url.path)")
                exit(1)
            }
            for o in outcomes where o.renamed {
                print("  \(o.source.lastPathComponent) → \(o.finalURL.lastPathComponent) (a different file already had that name)")
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
