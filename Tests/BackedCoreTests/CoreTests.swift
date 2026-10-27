@testable import BackedCore
import Foundation
import Testing

/// A throwaway folder tree; files get random content unless given bytes.
final class TempTree {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("backed-test-\(UUID().uuidString)")

    init() { try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ rel: String, _ data: Data = Data((0..<1024).map { _ in UInt8.random(in: 0...255) })) -> Data {
        let url = root.appendingPathComponent(rel)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: url)
        return data
    }

    var dest: Destination { Destination(id: "dir:\(root.path)", name: "T7 Shield", root: root) }
}

func memoryStore() throws -> Store { try Store(path: ":memory:") }

@Suite struct HashTests {
    @Test func emptyInputMatchesReferenceVector() {
        #expect(XXH3Hasher().digest() == "99aa06d3014798d86001c324468d497f")
    }

    @Test func chunkedFileHashEqualsOneShot() throws {
        let t = TempTree()
        let data = t.write("big.bin", Data((0..<(hashChunkSize + 12345)).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        let h = XXH3Hasher()
        data.withUnsafeBytes { h.update($0) }
        let path = t.root.appendingPathComponent("big.bin").path
        #expect(try hashFile(atPath: path, uncached: false) == h.digest())
        #expect(try hashFile(atPath: path, uncached: true) == h.digest())
    }
}

@Suite struct ScannerTests {
    @Test func classifiesAndSkipsJunk() {
        let t = TempTree()
        t.write("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        t.write("PRIVATE/M4ROOT/CLIP/C0001M01.XML")
        t.write("PRIVATE/M4ROOT/SUB/C0001S03.MP4")
        t.write("PRIVATE/M4ROOT/MEDIAPRO.XML")
        t.write("DCIM/100MSDCF/DSC00001.ARW")
        t.write("DCIM/100MSDCF/._DSC00001.ARW")
        t.write(".Spotlight-V100/Store-V2/x")
        t.write(".DS_Store")

        let kinds = Dictionary(uniqueKeysWithValues: CardScanner.scan(t.root).map { ($0.path, $0.kind) })
        #expect(kinds == [
            "PRIVATE/M4ROOT/CLIP/C0001.MP4": .video,
            "PRIVATE/M4ROOT/CLIP/C0001M01.XML": .sidecar,
            "PRIVATE/M4ROOT/SUB/C0001S03.MP4": .proxy,
            "PRIVATE/M4ROOT/MEDIAPRO.XML": .other,
            "DCIM/100MSDCF/DSC00001.ARW": .photo,
        ])
        #expect(CardScanner.looksLikeCard(t.root))
        #expect(!CardScanner.looksLikeCard(TempTree().root))
    }
}

@Suite struct MatcherTests {
    @Test func sameNameDifferentContentIsMissing_renamedCopyIsBacked() throws {
        let card = TempTree(), drive = TempTree(), store = try memoryStore()
        let a = card.write("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        card.write("PRIVATE/M4ROOT/CLIP/C0002.MP4")
        drive.write("Anything/renamed by hand.mp4", a)  // same content, other name: counts
        drive.write("2026/C0002.MP4")  // same name and size, other camera: doesn't count

        let files = CardScanner.scan(card.root)
        let checks = try Matcher(store: store).check(cardRoot: card.root, files: files, drives: [drive.dest])
        #expect(checks[0].missing.map(\.path) == ["PRIVATE/M4ROOT/CLIP/C0002.MP4"])
        #expect(Verdict.from(total: 2, checks: checks) == .partiallyBacked(missing: 1, total: 2, drive: "T7 Shield"))
    }

    @Test func allCopiedIsGreen() throws {
        let card = TempTree(), drive = TempTree(), store = try memoryStore()
        for i in 1...3 { drive.write("Footage/FX3/C000\(i).MP4", card.write("CLIP/C000\(i).MP4")) }
        let checks = try Matcher(store: store).check(cardRoot: card.root, files: CardScanner.scan(card.root), drives: [drive.dest])
        let v = Verdict.from(total: 3, checks: checks)
        #expect(v == .backed(total: 3, drives: ["T7 Shield"]))
        #expect(v.orb == .green)
    }

    @Test func memoryIsNeverGreen() throws {
        let card = TempTree(), drive = TempTree(), store = try memoryStore()
        drive.write("x.MP4", card.write("CLIP/C0001.MP4"))
        let files = CardScanner.scan(card.root)
        _ = try Matcher(store: store).check(cardRoot: card.root, files: files, drives: [drive.dest])

        var away = drive.dest
        away.root = nil
        let checks = try Matcher(store: store).check(cardRoot: card.root, files: files, drives: [away])
        let v = Verdict.from(total: 1, checks: checks)
        guard case .fromMemory(0, "T7 Shield", .some) = v else { Issue.record("got \(v)"); return }
        #expect(v.orb == .grey)
        #expect(v.lines.last == "Plug it in to confirm before formatting.")
    }

    @Test func changedDestinationFileIsRehashed() throws {
        let card = TempTree(), drive = TempTree(), store = try memoryStore()
        drive.write("C0001.MP4", card.write("CLIP/C0001.MP4"))
        let files = CardScanner.scan(card.root)
        let matcher = Matcher(store: store)
        #expect(try matcher.check(cardRoot: card.root, files: files, drives: [drive.dest])[0].missing.isEmpty)

        drive.write("C0001.MP4")  // same size, new content
        let url = drive.root.appendingPathComponent("C0001.MP4")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        #expect(try matcher.check(cardRoot: card.root, files: files, drives: [drive.dest])[0].missing.count == 1)
    }

    @Test func partialFilesOnDestinationDoNotCount() throws {
        let card = TempTree(), drive = TempTree(), store = try memoryStore()
        drive.write("C0001.MP4" + partialSuffix, card.write("CLIP/C0001.MP4"))
        let checks = try Matcher(store: store).check(cardRoot: card.root, files: CardScanner.scan(card.root), drives: [drive.dest])
        #expect(checks[0].missing.count == 1)
    }

    @Test func noDrivesIsAProblem() {
        #expect(Verdict.from(total: 5, checks: []).orb == .red)
    }
}

@Suite struct VerdictCopyTests {
    @Test func copyMatchesSpec() {
        #expect(Verdict.notBacked(missing: 148, total: 148, drive: "T7 Shield").lines
            == ["148 of 148 files aren't on T7 Shield yet. Don't format."])
        #expect(Verdict.partiallyBacked(missing: 1, total: 148, drive: "T7 Shield").lines
            == ["1 of 148 files isn't on T7 Shield yet. Don't format."])
        #expect(Verdict.backed(total: 148, drives: ["T7 Shield"]).lines
            == ["148 / 148 files copied. Each one read back and checked."])
        let sat = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 24, hour: 12).date!
        #expect(Verdict.fromMemory(missing: 12, drive: "T7 Shield", asOf: sat).lines
            == ["12 files to copy", "From memory — T7 Shield as of Sat 24 Oct.", "Plug it in to confirm before formatting."])
        #expect(Verdict.reading(n: 28, total: 148).lines == ["Reading 28 of 148 files on the card…"])
    }
}
