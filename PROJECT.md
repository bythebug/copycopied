# Project State

## Last Verified

2026-10-27, end of the Phase 2 session. `swift test` passed (23 tests). `swift build` is clean. The fake-image acceptance runs below passed. Git is on `main` with commits for Phases 0, 1 and 2.

## Project Goal

**backed.** is a native macOS menu bar utility for videographers and photographers. When a camera card is inserted, it fingerprints every file by content (xxh3-128) and answers "Is this card actually backed?" against the working and backup drives. It copies only the missing files, into the folder structure the user already uses, verifies every copy with an uncached read-back, and then shows green. Full spec: `backed-build-prompt.md`.

## Requirements

### Confirmed

All from `backed-build-prompt.md`:
- Safety rules §2 (see `docs/SAFETY.md` for how each is enforced).
- Verdict model §5, UI §6, features §7, brands §9, edge cases §10, testing §11, phases §12 (0–8) with a commit per phase, deliverables §14.
- On 2026-10-27 the user said "build" without reviewing PLAN.md. The recommended defaults in `docs/PLAN.md` §2 (D1–D12) are therefore the working decisions, but not explicitly approved.

### Assumptions

- PLAN.md D1–D12 stand until the user overrides them (notably D1 SwiftPM-only, D3 system SQLite instead of GRDB, D6 flat camera-folder layout).
- Camera card layouts in `CardScanner.cardMarkers` / `make-fake-card.sh` come from common knowledge and are not verified (`TODO(verify)` markers).

### Open Questions

From PLAN.md §6. All are still unanswered:
- **Q1** Remount cards read-only via DiskArbitration by default? (Recommended: yes. macOS was seen writing `.fseventsd` to the writable fake card.)
- **Q2** Re-hash matched destination files before showing green, or trust the stat-keyed cache?
- **Q3** Developer ID team for signing and notarization.
- **Q4** Git remote (none set up; nothing pushed).

## Current Status

- Phase 0 (plan): COMPLETE (user review pending)
- Phase 1 (core engine + `backed-cli status`): COMPLETE
- Phase 2 (copy/verify + `backed-cli copy`): COMPLETE, with the gaps listed under Known Issues
- Phases 3–8: NOT STARTED

## Completed

- **Phase 0:** `docs/PLAN.md`, covering architecture, decisions D1–D12, risks, disagreements with the spec, and questions.
- **Phase 1:** BackedCore scanning, hashing, SQLite index, matching and verdicts. Plus `backed-cli volumes|role|status` and `scripts/make-fake-card.sh`.
  - Verified with fake Canon card + APFS "T7 Shield": "148 of 148 files aren't on T7 Shield yet. Don't format." After 19 files were copied by hand: "129 of 148…". After all were copied by hand into another folder structure: green. With the drive detached: grey "From memory — T7 Shield as of Tue 27 Oct."
- **Phase 2:** `Copier` (partial file → F_FULLFSYNC → uncached verify → re-read → re-copy once → `RENAME_EXCL` placement with `(2)` numbering, stale-partial sweep, preflight for free space and FAT32's 4 GiB limit, sleep assertion), `CopyLog` (JSON lines), `Indexer.record`, `backed-cli copy`.
  - Verified with fake images: copied 148 files to an exFAT drive (no fsync fallback was needed). Card B with reused names got `(2)` names. A copy too big for the drive was refused before anything was written. A drive force-detached mid-copy gave a plain-language error, and the next run cleaned up the partial and finished green. Copying into a new folder on a drive that already held the files copied nothing.
- Docs: `docs/SAFETY.md`, `README.md`.

## In Progress

Nothing.

## Next Task

**Phase 3: menu bar app.** Add an executable target `backed` (SwiftPM, PLAN D1) plus `scripts/build-app.sh` to assemble a `.app` (Info.plist with `LSUIElement`). It needs:
- an `NSStatusItem` "b." with a worst-verdict dot;
- an `NSPopover` that opens programmatically when a card appears (DiskArbitration `DARegisterDiskAppearedCallback`/`Disappeared` on a dispatch queue, with `NSWorkspace.didMountNotification` as fallback);
- one verdict row per card (reading progress, then red/grey/green), the "Also plugged in" list, Open/Quit, a notification when done, and `SMAppService` launch at login.

Turn the indexer and copier into actors with cancellation, and add a per-destination copy queue (SAFETY.md depends on one copy at a time per drive). Acceptance: mounting a fake card image opens the popover, which shows reading progress and then red. Ask the user about Q1 before implementing the read-only remount.

## Remaining Work

### Required
- Phase 3: menu bar app (above).
- Phase 4: Planner (template tokens, inferring the template from an existing root), shoot day with a 05:00 cutoff, joining cards to shoots, `FX3 B` body labels, asking when there's no serial, clock checks, New shoot sheet, per-shoot log location, configurable collision naming (card/roll prefix).
- Phase 5: several working drives, backups list, required vs optional drives, auto re-check on reconnect, per-drive copy progress.
- Phase 6: `CameraProfile` per brand plus generic fallback, `docs/cameras.md`, metadata (AVFoundation/ImageIO/Sony XML).
- Phase 8 (required parts): VoiceOver labels, Reduce Motion, sign/notarize script, onboarding.

### Desirable
- Phase 7: Downloads → Assets sorting.
- Phase 8: Canvas/Metal orb, performance pass on 1 TB / 10k-file cards, MB/s reporting.

### Optional
- Out of scope for v1 (§13). The log format already keeps what an MHL export needs (path, size, xxh3_128, time).

## Architecture

SwiftPM package (`Package.swift`, macOS 14, tools 6.0):
- `CXXHash`: official xxHash v0.8.3 header, vendored unmodified (BSD-2), compiled once by `xxhash.c`.
- `BackedCore` (no UI imports):
  - `Hash.swift`: `XXH3Hasher` and `hashFile(uncached:)` (8 MB chunks, `F_NOCACHE`, checks for cancellation), plus `BackedError`.
  - `FileWalk.swift`: `walkFiles` (skips junk and `.backed-partial` files) and `statFile` (size, mtime, inode).
  - `CardScanner.swift`: card heuristics, classification by kind, sidecar ↔ clip by stem prefix.
  - `Store.swift`: system SQLite3 wrapper with tables `volume(id, name, role, last_indexed)` and `indexed_file(volume_id, path, size, mtime, inode, hash, hash_verified_at)`.
  - `Indexer.swift`: `Destination` (volume UUID or `dir:<path>`), incremental index, lazy hashing of same-size candidates, `record`.
  - `Matcher.swift`: `Matcher.check` → `[DriveCheck]` → `Verdict.from` (red/grey/green, spec copy text).
  - `Volume.swift`: snapshot of mounted volumes (FileManager), `isCard`, `containing`, `destination(for:)`.
  - `Copier.swift`: `Copier`, `CopyRequest/Outcome/Event/Error`, `CopyLog`.
- `backed-cli`: hand-rolled argument parsing; database at `~/Library/Application Support/backed/backed.sqlite` (`--db` overrides).

Data flow: scan card → index connected drives (re-stat) → hash only same-size candidates (uncached) → hash card files as needed → per-drive missing list → verdict. Copy: missing list → requests → copier → `Indexer.record` → re-check → verdict.

## Important Decisions

See `docs/PLAN.md` §2 for the full list with reasons. The ones that affect code now:
- D1 SwiftPM only (no xcodegen or .xcodeproj). Active.
- D2 xxh3-128, stored as 32-hex. Active.
- D3 system SQLite3 instead of GRDB. Active; deviates from the spec.
- D9 the `other` kind (e.g. Sony `MEDIAPRO.XML`) isn't required for green. Active.
- D10 cached destination hashes are trusted while the stat key is unchanged and the drive is connected. Active; Q2 is open.
- D12 verify retry: re-read once, then re-copy once. Active.
- The test hook `Copier.beforeVerify` runs once per written partial, between sync and verify.

## Dependencies

No external packages. `CXXHash` is vendored. System frameworks used: Foundation, SQLite3, IOKit.pwr_mgt. Tests use Swift Testing (part of the toolchain).

## Commands

All verified 2026-10-27:
- Build: `swift build`
- Test: `swift test` (23 tests)
- CLI: `.build/debug/backed-cli volumes | role <path> working|backup|card|ignored|auto | status [--card P] [--drive P] | copy --to <folder> [--card P] [--keep-structure]` plus `--db <path>`
- Fake media: `scripts/make-fake-card.sh sony|canon|gopro|drive "<Name>" [clips] [kb]` (creates and mounts the image in `fake-cards/`); detach with `hdiutil detach "/Volumes/<Name>"`
- Lint/format: none configured. Deploy/sign: not built yet.

## Verification

- 2026-10-27 `swift test`: 23/23 passed. Covers the xxh3 reference vector, chunked vs one-shot hashing, scanning and classification, matching (same name with different content, renamed copies), memory never green, rehash on change, partials ignored, spec copy text, copy and date preservation, clashes, case-insensitive clashes, identical files at the target name, bit flip, re-copy, cancel, stale partials, swept partials, source changed, preflight, log, copy → green.
- 2026-10-27 manual runs on fake images: the Phase 1 acceptance (red → hand-copied → green → unplugged → grey from memory) and the Phase 2 scenarios listed under Completed.

## Known Issues

- macOS writes `.fseventsd` to writable card mounts, and an AppleDouble `._DCIM` was also found on the fake card (possibly from the test script). Not caused by backed., but it breaks the spirit of rule 1 until the D7 read-only remount is built (Q1).
- It hasn't been measured whether the `F_NOCACHE` read-back actually reaches the device (TODO(verify) in `Copier.writePartial`).
- `RENAME_EXCL` support on exFAT/FAT is unknown. The fallback is check-then-rename, which is only safe with one copier per drive. The CLI doesn't enforce that; the Phase 3 per-drive queue must.
- Volumes without a UUID get the id `noid:<name>:<capacity>` (TODO(verify) for FAT cards).
- The "Mac sleeps mid-copy" and "card pulled mid-copy" scenarios haven't been tested on hardware. They share the drive-pull code path, which was tested.
- Card metadata (capture date, camera, serial) isn't read yet (Phases 4 and 6).
- The CLI copies into a flat folder or keeps the card structure. The D6 template layout (`Footage/{camera}`) comes with the Planner in Phase 4.
- Matching loads every index row for a drive into memory each check. Fine for about 50k files; not yet measured at scale.

## Blockers

None. Q1–Q4 need answers before the parts of Phases 3 and 8 they affect.

## Files and Components

- `backed-build-prompt.md`: authoritative spec.
- `CLAUDE.md`: permanent project rules. `PROJECT.md`: this file.
- `docs/PLAN.md`: architecture, decisions, risks, questions. `docs/SAFETY.md`: each rule's enforcement and tests.
- `Sources/BackedCore/*`: engine (complete for Phases 1–2). `Sources/backed-cli/main.swift`: CLI.
- `Sources/CXXHash/`: vendored xxhash. `Tests/BackedCoreTests/`: `CoreTests.swift`, `CopierTests.swift`.
- `scripts/make-fake-card.sh`: fake cards and drives. `fake-cards/`: git-ignored images and test database.

## Session Progress

- 2026-10-27, session 1: initialized project memory; wrote PLAN.md; on "build", ran `git init`, vendored xxhash v0.8.3, and built and committed Phases 1 and 2.
  - Bugs found and fixed while doing it: the verify hook ran per read instead of per write; the containing-volume lookup failed for folders that didn't exist yet (this caused duplicate copies); partials were left behind after a drive pull; the disconnect message was raw.

## Handoff Notes

1. **Building:** backed., a macOS menu bar app that proves camera cards are backed up, using content hashing and verified copies. Spec: `backed-build-prompt.md`.
2. **Where we are:** Phases 0–2 are done and committed. The core engine and CLI work against fake disk images. There's no UI yet.
3. **Most recent:** the Phase 2 copier with atomic, verified, non-overwriting copies, plus SAFETY.md and README.
4. **Remaining:** Phases 3–8, and answers to Q1–Q4.
5. **Next:** Phase 3, the menu bar app (see Next Task).
6. **Be careful:**
   - Safety rules beat features.
   - Never let a disconnected drive produce green.
   - Keep `Copier.place` non-overwriting.
   - Queue copies per destination drive (the partial sweep assumes it).
   - Mark camera facts `TODO(verify)`.
   - Don't add dependencies (GRDB, xcodegen, ArgumentParser) without asking.
   - Test shell loops that wait on files must have timeouts. Two hung in session 1; use a Python driver instead.
   - Detach fake images when done.
