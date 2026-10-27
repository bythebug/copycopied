@testable import BackedCore
import Foundation
import Testing

private func contents(_ dir: URL) -> [String] {
    ((try? FileManager.default.subpathsOfDirectory(atPath: dir.path)) ?? []).sorted()
}

private func flipFirstByte(_ url: URL) {
    let h = try! FileHandle(forUpdating: url)
    let b = try! h.read(upToCount: 1)!
    try! h.seek(toOffset: 0)
    h.write(Data([b[0] ^ 0xFF]))
    try! h.close()
}

@Suite struct CopierTests {
    @Test func copiesVerifiesAndKeepsDates() throws {
        let card = TempTree(), drive = TempTree()
        let data = card.write("CLIP/C0001.MP4")
        let src = card.root.appendingPathComponent("CLIP/C0001.MP4")
        let old = Date(timeIntervalSince1970: 1_761_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: src.path)

        let dst = drive.root.appendingPathComponent("Footage/FX3/C0001.MP4")
        let out = try Copier().copy([CopyRequest(source: src, destination: dst)])
        #expect(out[0].finalURL == dst && !out[0].renamed)
        #expect(try Data(contentsOf: dst) == data)
        #expect(out[0].hash == (try hashFile(atPath: src.path, uncached: false)))
        #expect((try FileManager.default.attributesOfItem(atPath: dst.path)[.modificationDate] as! Date) == old)
        #expect(contents(drive.root) == ["Footage", "Footage/FX3", "Footage/FX3/C0001.MP4"])
    }

    @Test func neverOverwritesAClash() throws {
        let card = TempTree(), drive = TempTree()
        let ours = card.write("C0001.MP4")
        let theirs = drive.write("C0001.MP4")  // reformatted card reused the name
        let out = try Copier().copy([CopyRequest(source: card.root.appendingPathComponent("C0001.MP4"),
                                                 destination: drive.root.appendingPathComponent("C0001.MP4"))])
        #expect(out[0].renamed && out[0].finalURL.lastPathComponent == "C0001 (2).MP4")
        #expect(try Data(contentsOf: drive.root.appendingPathComponent("C0001.MP4")) == theirs)
        #expect(try Data(contentsOf: out[0].finalURL) == ours)
    }

    @Test func caseInsensitiveClashIsNumbered() throws {
        let card = TempTree(), drive = TempTree()
        drive.write("C0001.mp4")
        // Only meaningful on a case-insensitive destination (the default for APFS on macOS).
        guard FileManager.default.fileExists(atPath: drive.root.appendingPathComponent("C0001.MP4").path) else { return }
        card.write("C0001.MP4")
        let out = try Copier().copy([CopyRequest(source: card.root.appendingPathComponent("C0001.MP4"),
                                                 destination: drive.root.appendingPathComponent("C0001.MP4"))])
        #expect(out[0].finalURL.lastPathComponent == "C0001 (2).MP4")
    }

    @Test func identicalFileAtNameIsNotDuplicated() throws {
        let card = TempTree(), drive = TempTree()
        drive.write("C0001.MP4", card.write("C0001.MP4"))
        let out = try Copier().copy([CopyRequest(source: card.root.appendingPathComponent("C0001.MP4"),
                                                 destination: drive.root.appendingPathComponent("C0001.MP4"))])
        #expect(out[0].alreadyThere && !out[0].renamed)
        #expect(contents(drive.root) == ["C0001.MP4"])
    }

    @Test func bitFlipIsCaughtAndNamed() throws {
        let card = TempTree(), drive = TempTree()
        card.write("C0001.MP4")
        let copier = Copier()
        copier.beforeVerify = flipFirstByte
        #expect(throws: CopyError.verifyFailed("C0001.MP4")) {
            try copier.copy([CopyRequest(source: card.root.appendingPathComponent("C0001.MP4"),
                                         destination: drive.root.appendingPathComponent("C0001.MP4"))])
        }
        #expect(contents(drive.root).isEmpty)  // no file under the real name, no partial
    }

    @Test func oneBadWriteIsRecopied() throws {
        let card = TempTree(), drive = TempTree()
        let data = card.write("C0001.MP4")
        let copier = Copier()
        var writes = 0  // corrupt only the first write; the re-copy is clean
        copier.beforeVerify = { writes += 1; if writes == 1 { flipFirstByte($0) } }
        let out = try copier.copy([CopyRequest(source: card.root.appendingPathComponent("C0001.MP4"),
                                               destination: drive.root.appendingPathComponent("C0001.MP4"))])
        #expect(try Data(contentsOf: out[0].finalURL) == data)
    }

    @Test func cancelMidCopyLeavesNoPartial() async throws {
        let card = TempTree(), drive = TempTree()
        card.write("A.MP4")
        card.write("B.MP4")
        let src = card.root, dst = drive.root
        let task = Task {
            let copier = Copier()
            var seen = 0
            copier.beforeVerify = { _ in seen += 1; if seen == 2 { withUnsafeCurrentTask { $0?.cancel() } } }
            return try copier.copy(["A.MP4", "B.MP4"].map {
                CopyRequest(source: src.appendingPathComponent($0), destination: dst.appendingPathComponent($0))
            })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(contents(drive.root) == ["A.MP4"])  // A finished and verified; B left nothing behind
    }

    @Test func stalePartialFromCrashIsReplaced() throws {
        let card = TempTree(), drive = TempTree()
        let data = card.write("C0001.MP4")
        drive.write("C0001.MP4" + partialSuffix, Data("half".utf8))
        _ = try Copier().copy([CopyRequest(source: card.root.appendingPathComponent("C0001.MP4"),
                                           destination: drive.root.appendingPathComponent("C0001.MP4"))])
        #expect(contents(drive.root) == ["C0001.MP4"])
        #expect(try Data(contentsOf: drive.root.appendingPathComponent("C0001.MP4")) == data)
    }

    @Test func leftoverPartialsInTargetFolderAreSwept() throws {
        let card = TempTree(), drive = TempTree()
        card.write("A.MP4")
        drive.write("B.MP4" + partialSuffix, Data("half".utf8))  // from an earlier, interrupted batch
        _ = try Copier().copy([CopyRequest(source: card.root.appendingPathComponent("A.MP4"),
                                           destination: drive.root.appendingPathComponent("A.MP4"))])
        #expect(contents(drive.root) == ["A.MP4"])
    }

    @Test func sourceThatReadsDifferentlyFails() throws {
        let card = TempTree(), drive = TempTree()
        card.write("C0001.MP4")
        #expect(throws: CopyError.sourceChanged("C0001.MP4")) {
            try Copier().copy([CopyRequest(source: card.root.appendingPathComponent("C0001.MP4"),
                                           destination: drive.root.appendingPathComponent("C0001.MP4"),
                                           expectedHash: "not-the-hash")])
        }
        #expect(contents(drive.root).isEmpty)
    }

    @Test func preflightStopsBeforeStarting() {
        #expect(Copier.preflight(sizes: [10, 20], free: 25, fsType: "apfs") == .notEnoughSpace(needed: 30, free: 25))
        #expect(Copier.preflight(sizes: [10, 20], free: 30, fsType: "apfs") == nil)
        #expect(Copier.preflight(sizes: [Copier.fat32Limit], free: .max, fsType: "msdos") == .tooLargeForFAT32("A file"))
        #expect(Copier.preflight(sizes: [Copier.fat32Limit], free: .max, fsType: "exfat") == nil)
    }

    @Test func logRecordsFoldersAndCopies() throws {
        let card = TempTree(), drive = TempTree(), logs = TempTree()
        card.write("C0001.MP4")
        let log = try CopyLog(url: logs.root.appendingPathComponent("shoot.jsonl"))
        _ = try Copier(log: log).copy([CopyRequest(source: card.root.appendingPathComponent("C0001.MP4"),
                                                   destination: drive.root.appendingPathComponent("Footage/C0001.MP4"))])
        let events = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: String]
        }
        #expect(events.map { $0["event"] } == ["folder", "copied"])
        #expect(events[1]["xxh3_128"]?.count == 32)
    }

    @Test func copiedThenMatchedIsGreen() throws {
        let card = TempTree(), drive = TempTree(), store = try memoryStore()
        for i in 1...3 { card.write("CLIP/C000\(i).MP4") }
        let files = CardScanner.scan(card.root)
        let matcher = Matcher(store: store)
        let missing = try matcher.check(cardRoot: card.root, files: files, drives: [drive.dest])[0].missing
        let out = try Copier().copy(missing.map {
            CopyRequest(source: card.root.appendingPathComponent($0.path),
                        destination: drive.root.appendingPathComponent("Footage/" + ($0.path as NSString).lastPathComponent))
        })
        for o in out { try Indexer(store: store).record(drive.dest, path: "Footage/" + o.finalURL.lastPathComponent, hash: o.hash) }
        let v = Verdict.from(total: 3, checks: try matcher.check(cardRoot: card.root, files: files, drives: [drive.dest]))
        #expect(v == .backed(total: 3, drives: ["T7 Shield"]))
    }
}

@Suite struct OffloadTests {
    @Test func copyMissingRecordsIndexSoRecheckIsGreen() throws {
        let card = TempTree(), drive = TempTree(), store = try memoryStore()
        for i in 1...3 { card.write("DCIM/100CANON/MVI_000\(i).MP4") }
        let files = CardScanner.scan(card.root)
        let matcher = Matcher(store: store)
        let dest = drive.dest
        let missing = try matcher.check(cardRoot: card.root, files: files, drives: [dest])[0].missing
        let out = try Offload.copyMissing(cardRoot: card.root, missing: missing, to: drive.root.appendingPathComponent("2026/Shoot"),
                                          dest: dest, store: store, log: nil)
        #expect(out.count == 3)
        // Recorded with their hashes, so the re-check needn't read them again.
        #expect(try store.indexedFiles(volumeID: dest.id).allSatisfy { $0.hash != nil && $0.path.hasPrefix("2026/Shoot/") })
        #expect(Verdict.from(total: 3, checks: try matcher.check(cardRoot: card.root, files: files, drives: [dest])).orb == .green)
    }

    @Test func pulledDriveIsExplainedPlainly() {
        let card = URL(fileURLWithPath: "/Volumes/Card A")
        let e = BackedError.io(op: "write", path: "/Volumes/T7 Shield/x.MP4.backed-partial", errno: EIO)
        #expect(Offload.explain(e, cardRoot: card, driveName: "T7 Shield").hasPrefix("Lost contact with T7 Shield"))
        let c = BackedError.io(op: "read", path: "/Volumes/Card A/DCIM/x.MP4", errno: ENXIO)
        #expect(Offload.explain(c, cardRoot: card, driveName: "T7 Shield").hasPrefix("Lost contact with Card A"))
    }
}
