import BackedCore
import Foundation

let usage = """
    usage:
      backed-cli volumes                                   list mounted volumes and their roles
      backed-cli role <volume-path> working|backup|card|ignored|auto
      backed-cli status [--card <path>]... [--drive <path>]...
                         verdict for each card; defaults: detected cards vs. drives marked working/backup
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

    default:
        print(usage)
    }
} catch {
    fail("\(error)")
}
