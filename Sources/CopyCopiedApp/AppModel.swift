import AppKit
import CopyCopiedCore
import Observation
import UserNotifications

@MainActor @Observable
final class AppModel {
    struct Card: Identifiable {
        var id: String
        var name: String
        var root: URL
        var verdict: Verdict = .reading(n: 0, total: 0)
        var checks: [DriveCheck] = []
        var busy: Task<Void, Never>?
        var copying = false
        var inProgress = false  // progress updates are only accepted while true
        var lastFolder: URL?
    }

    struct OtherVolume: Identifiable {
        var id: String
        var name: String
        var role: VolumeRole?
    }

    private(set) var cards: [Card] = []
    private(set) var others: [OtherVolume] = []
    private(set) var startupError: String?

    /// Called when a card is newly inserted (the app opens the popover) and whenever any verdict changes.
    var onCardInserted: () -> Void = {}
    var onChange: () -> Void = {}
    var isPopoverShown: () -> Bool = { false }

    private let engine: Engine?

    init() {
        do { engine = try Engine() } catch {
            engine = nil
            startupError = "Couldn't open CopyCopied's database: \(error)"
        }
    }

    /// Worst verdict across connected cards (red > grey > green); nil when no card is in.
    var worst: Verdict.Orb? {
        let orbs = cards.map(\.verdict.orb)
        return orbs.contains(.red) ? .red : orbs.contains(.grey) ? .grey : orbs.isEmpty ? nil : .green
    }

    /// Re-reads mounted volumes. New cards are checked; every other card is re-checked, since a drive
    /// coming or going can change its verdict (spec 7.7).
    func refresh() async {
        guard let engine else { return }
        let roles = (try? await engine.roles()) ?? [:]
        let mounted = Volumes.mounted()
        let cardVolumes = mounted.filter { $0.isCard(role: roles[$0.id]) }
        others = mounted.filter { v in !cardVolumes.contains { $0.id == v.id } }
            .map { OtherVolume(id: $0.id, name: $0.name, role: roles[$0.id]) }

        for gone in cards where !cardVolumes.contains(where: { $0.id == gone.id }) { gone.busy?.cancel() }
        cards.removeAll { c in !cardVolumes.contains { $0.id == c.id } }

        var inserted = false
        for v in cardVolumes {
            if !cards.contains(where: { $0.id == v.id }) {
                cards.append(Card(id: v.id, name: v.name, root: v.url))
                inserted = true
            }
            check(v.id)
        }
        onChange()
        if inserted { onCardInserted() }
    }

    func check(_ id: String) {
        guard let engine, let i = index(id), !cards[i].copying else { return }
        cards[i].busy?.cancel()
        cards[i].inProgress = true
        let root = cards[i].root
        cards[i].busy = Task {
            let throttle = Throttle()
            do {
                let result = try await engine.check(cardRoot: root) { n, total in
                    guard throttle.due(n == total) else { return }
                    Task { @MainActor in self.progress(id, .reading(n: n, total: total)) }
                }
                guard !Task.isCancelled else { return }
                set(id, result.verdict, checks: result.checks)
            } catch is CancellationError {
            } catch {
                set(id, .problem("Couldn't read the card: \(error)"))
            }
        }
    }

    func copy(_ id: String, to folder: URL) {
        guard let engine, let i = index(id) else { return }
        cards[i].busy?.cancel()
        cards[i].copying = true
        cards[i].inProgress = true
        let root = cards[i].root, name = cards[i].name
        cards[i].busy = Task {
            let throttle = Throttle()
            var outcome: String
            do {
                let folder = try await engine.copy(cardRoot: root, to: folder) { e in
                    guard throttle.due(false) else { return }
                    let v: Verdict = switch e {
                    case let .copying(n, t, _): .copying(n: n, total: t)
                    case let .verifying(n, t, _): .verifying(n: n, total: t)
                    }
                    Task { @MainActor in self.progress(id, v) }
                }
                if let i = index(id) { cards[i].lastFolder = folder }
                outcome = "done"
            } catch let e as Engine.CopyFailure {
                outcome = e.message
            } catch is CancellationError {
                return
            } catch {
                outcome = "\(error)"
            }
            guard let i = index(id) else { return }
            cards[i].copying = false
            if outcome == "done" {
                check(id)
                // Wait for the re-check so the notification states the real verdict.
                await cards.first { $0.id == id }?.busy?.value
                if let c = cards.first(where: { $0.id == id }) { notify(name, c.verdict.lines.joined(separator: " ")) }
            } else {
                set(id, .problem(outcome))
                notify(name, outcome)
            }
        }
    }

    func setRole(_ role: VolumeRole?, id: String, name: String) {
        Task {
            try? await engine?.setRole(role, id: id, name: name)
            await refresh()
        }
    }

    private func index(_ id: String) -> Int? { cards.firstIndex { $0.id == id } }

    /// Progress hops can land after the final verdict; `inProgress` drops those.
    private func progress(_ id: String, _ v: Verdict) {
        guard let i = index(id), cards[i].inProgress else { return }
        cards[i].verdict = v
        onChange()
    }

    private func set(_ id: String, _ v: Verdict, checks: [DriveCheck]? = nil) {
        guard let i = index(id) else { return }
        cards[i].inProgress = false
        cards[i].verdict = v
        if let checks { cards[i].checks = checks }
        onChange()
    }

    /// Notifies only when the popover is closed (spec 7.6).
    private func notify(_ title: String, _ body: String) {
        guard !isPopoverShown(), Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Limits progress updates to ~10 per second.
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func due(_ force: Bool) -> Bool {
        lock.withLock {
            guard force || Date().timeIntervalSince(last) > 0.1 else { return false }
            last = Date()
            return true
        }
    }
}
