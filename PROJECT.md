# Project State

## Last Verified

2026-10-27, after the rename to CopyCopied. `swift test` passed (28 tests). `swift build` and `scripts/build-app.sh` are clean. The renamed app launched and showed its "cc." status item. Phase 3 acceptance last passed before the rename (the code changes since are names, strings and the card-destination guard). Git is on `main`, remote https://github.com/bythebug/copycopied (private).

## Project Goal

**CopyCopied** is a native macOS menu bar utility for videographers and photographers. When a camera card is inserted, it fingerprints every file by content (xxh3-128) and answers "Is this card actually backed?" against the working and backup drives. It copies only the missing files, into the folder structure the user already uses, verifies every copy with an uncached read-back, and then shows green. Full spec: `backed-build-prompt.md`.

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
- ~~Q1~~ Answered 2026-10-27: **no read-only remount.** Cards stay writable so users can delete from Finder. Recorded as PLAN.md D7.
- **Q2** Re-hash matched destination files before showing green, or trust the stat-keyed cache?
- **Q3** Developer ID team for signing and notarization.
- ~~Q4~~ Answered: private GitHub repo `bythebug/copycopied`, remote `origin`. The user asked for it to be created and pushed.

## Current Status

- Phase 0 (plan): COMPLETE (user review pending)
- Phase 1 (core engine + `copycopied-cli status`): COMPLETE
- Phase 2 (copy/verify + `copycopied-cli copy`): COMPLETE, with the gaps listed under Known Issues
- Phase 3 (menu bar app): COMPLETE (see the gaps under Known Issues)
- Phases 4–8: NOT STARTED

## Completed

- **Phase 0:** `docs/PLAN.md`, covering architecture, decisions D1–D12, risks, disagreements with the spec, and questions.
- **Phase 1:** CopyCopiedCore scanning, hashing, SQLite index, matching and verdicts. Plus `copycopied-cli volumes|role|status` and `scripts/make-fake-card.sh`.
  - Verified with fake Canon card + APFS "T7 Shield": "148 of 148 files aren't on T7 Shield yet. Don't format." After 19 files were copied by hand: "129 of 148…". After all were copied by hand into another folder structure: green. With the drive detached: grey "From memory — T7 Shield as of Tue 27 Oct."
- **Phase 2:** `Copier` (partial file → F_FULLFSYNC → uncached verify → re-read → re-copy once → `RENAME_EXCL` placement with `(2)` numbering, stale-partial sweep, preflight for free space and FAT32's 4 GiB limit, sleep assertion), `CopyLog` (JSON lines), `Indexer.record`, `copycopied-cli copy`.
  - Verified with fake images: copied 148 files to an exFAT drive (no fsync fallback was needed). Card B with reused names got `(2)` names. A copy too big for the drive was refused before anything was written. A drive force-detached mid-copy gave a plain-language error, and the next run cleaned up the partial and finished green. Copying into a new folder on a drive that already held the files copied nothing.
- **Phase 3:** `Sources/CopyCopiedApp`, built into `build/CopyCopied.app` by `scripts/build-app.sh` (ad-hoc signed; `DEVELOPER_ID` env for hardened runtime).
  - Status item "cc." with a worst-verdict dot (none when no card is in).
  - Popover that opens by itself when a card mounts, with a fallback anchor when the icon is hidden behind the notch or a crowded menu bar.
  - Per-card rows: orb placeholder, verdict lines, `Choose folder…` copy, "Plug in X to copy", `Show in Finder`.
  - "Also plugged in" list with a role menu (Working drive / Backup / Not used / Treat as a card). "Not a card" in the card row's context menu.
  - Open backed window with the launch-at-login toggle (`SMAppService`) and a logs link. Notification when a copy ends while the popover is closed.
  - Every mount or unmount re-checks all cards, so plugging in a drive updates the verdict.
  - `Engine` actor owns the Store and serialises all disk work. `AppModel` is `@MainActor @Observable`. `COPYCOPIED_DB` env var overrides the database.
  - Shared CLI/app steps moved into `CopyCopiedCore/Offload.swift`.
  - Verified: inserting fake Card C opened the popover by itself → "Reading 28 of 80 files on the card…" (grey) → "50 of 80 files aren't on T7 Shield yet. Don't format." (red dot). Card A showed "129 of 148…", which exposed the walker bug below.
- **Bug fixed in Phase 3 (safety-relevant):** `walkFiles` called `skipDescendants()` on junk *files* (`.DS_Store`, `._*`), which skipped the whole enclosing folder. On a card this could have dropped clips from the scan and produced a false green. Fixed, with regression test `junkFilesDoNotHideTheirFolder` (it failed before the fix).
- **Guard: CopyCopied never writes to a card (2026-10-27, user request).** Choosing a folder on a card (app `Choose folder…`, CLI `copy --to`, CLI `status --drive`) is refused before matching, because before this a card compared with itself showed a **false green**. The copier also refuses card destinations via `readOnlyRoots`. Tests: `neverWritesIntoACard`, `cardFolderIsRefusedBeforeMatching`; also checked on a fake card image.
- Docs: `docs/SAFETY.md`, `README.md`.

## In Progress

Nothing.

## Next Task

**Phase 4: shoots and folders.**
- `Planner` with the template tokens `{year} {client} {date:fmt} {shoot} {camera} {kind}` and the D6 layout (`Footage/{camera}`, `Photo/{camera}` only if there are stills, `Audio` only if there's audio, `Project`).
- Template inference by scanning an existing root.
- Shoot persistence: new `shoot` and `camera` tables in Store.
- Logical shoot day with a 05:00 cutoff, plus clock checks.
- Camera identity: needs metadata. Start with a generic AVFoundation/ImageIO metadata provider and a mockable protocol so tests run without real clips. Brand profiles stay in Phase 6.
- Body labels (`FX3`, `FX3 B`), and asking the user when there's no serial.
- The New shoot sheet with a live tree preview; `Add to "<shoot>"` as the primary action.
- Per-shoot log location.

Acceptance: the three-card integration test (A → new shoot → green; B second body → `FX3 B`; C after midnight → same shoot) passes, and the tree preview matches what's created on disk.


## Remaining Work

### Required
- Phase 3 follow-ups: per-drive copy queues instead of one global actor; caching card hashes across re-checks.
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
- `CopyCopiedCore` (no UI imports):
  - `Hash.swift`: `XXH3Hasher` and `hashFile(uncached:)` (8 MB chunks, `F_NOCACHE`, checks for cancellation), plus `CoreError`.
  - `FileWalk.swift`: `walkFiles` (skips junk and `.copycopied-partial` files) and `statFile` (size, mtime, inode).
  - `CardScanner.swift`: card heuristics, classification by kind, sidecar ↔ clip by stem prefix.
  - `Store.swift`: system SQLite3 wrapper with tables `volume(id, name, role, last_indexed)` and `indexed_file(volume_id, path, size, mtime, inode, hash, hash_verified_at)`.
  - `Indexer.swift`: `Destination` (volume UUID or `dir:<path>`), incremental index, lazy hashing of same-size candidates, `record`.
  - `Matcher.swift`: `Matcher.check` → `[DriveCheck]` → `Verdict.from` (red/grey/green, spec copy text).
  - `Volume.swift`: snapshot of mounted volumes (FileManager), `isCard`, `containing`, `destination(for:)`.
  - `Copier.swift`: `Copier`, `CopyRequest/Outcome/Event/Error`, `CopyLog`.
  - `Offload.swift`: shared app/CLI steps (`drives`, `destination(containing:)`, `newLog`, `copyMissing`, `explain`).
- `CopyCopiedApp` (AppKit + SwiftUI): `main.swift` (AppDelegate: status item, popover, fallback anchor, mount notifications, main window), `AppModel.swift` (cards, others, check/copy tasks, progress throttle, notifications), `Engine.swift` (actor over Store), `Views.swift` (Orb, CardRow, PopoverView, MainView).
- `copycopied-cli`: hand-rolled argument parsing; database at `~/Library/Application Support/CopyCopied/copycopied.sqlite` (`--db` overrides).

Data flow: scan card → index connected drives (re-stat) → hash only same-size candidates (uncached) → hash card files as needed → per-drive missing list → verdict. Copy: missing list → requests → copier → `Indexer.record` → re-check → verdict.

## Important Decisions

- **Renamed to CopyCopied** (2026-10-27, user). "backed." is another company's product name. The rename covers code modules, CLI, app bundle, bundle ID, data folder, partial-file suffix, menu glyph ("cc."), docs and the GitHub repo (`bythebug/copycopied`, private). Done; build and tests pass under the new names.

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
- Test: `swift test` (28 tests)
- App: `scripts/build-app.sh` → `build/CopyCopied.app`; run with `COPYCOPIED_DB=<path> build/CopyCopied.app/Contents/MacOS/backed` to use a test database
- CLI: `.build/debug/copycopied-cli volumes | role <path> working|backup|card|ignored|auto | status [--card P] [--drive P] | copy --to <folder> [--card P] [--keep-structure]` plus `--db <path>`
- Fake media: `scripts/make-fake-card.sh sony|canon|gopro|drive "<Name>" [clips] [kb]` (creates and mounts the image in `fake-cards/`); detach with `hdiutil detach "/Volumes/<Name>"`
- Lint/format: none configured. Deploy/sign: not built yet.

## Verification

- 2026-10-27 `swift test`: 23/23 passed. Covers the xxh3 reference vector, chunked vs one-shot hashing, scanning and classification, matching (same name with different content, renamed copies), memory never green, rehash on change, partials ignored, spec copy text, copy and date preservation, clashes, case-insensitive clashes, identical files at the target name, bit flip, re-copy, cancel, stale partials, swept partials, source changed, preflight, log, copy → green.
- 2026-10-27 Phase 3: launched the built app, attached fake card images. The popover auto-opened with reading progress, then the red verdict. The status item showed the dot (checked via Accessibility title "b. ●" and screenshots). Popover auto-open was seen both with the icon visible and with it hidden; the `hidesOnDeactivate` fix for the hidden case was rebuilt but only re-verified with the icon visible.
- 2026-10-27 manual runs on fake images: the Phase 1 acceptance (red → hand-copied → green → unplugged → grey from memory) and the Phase 2 scenarios listed under Completed.

## Known Issues

- Phase 3 UI paths not exercised by clicking: `Choose folder…` → copy → green (the shared `Offload.copyMissing` is unit-tested and its preflight was seen refusing on a full fake drive), role menus, launch-at-login toggle, notifications (they may need a properly signed app). None verified in the UI.
- The orb is a breathing gradient placeholder. The particle orb is Phase 8. In one screenshot taken mid-resize the orb looked vertically offset; it was correct once settled.
- Re-checks re-hash the card's same-size candidates every time; no card hash cache yet.

- macOS writes `.fseventsd` to writable card mounts, and an AppleDouble `._DCIM` was also found on the fake card (possibly from the test script). Not caused by CopyCopied By decision D7 cards stay writable, so this is accepted; CopyCopied ignores those files.
- It hasn't been measured whether the `F_NOCACHE` read-back actually reaches the device (TODO(verify) in `Copier.writePartial`).
- `RENAME_EXCL` support on exFAT/FAT is unknown. The fallback is check-then-rename, which is only safe with one copier per drive. The CLI doesn't enforce that; the Phase 3 per-drive queue must.
- Volumes without a UUID get the id `noid:<name>:<capacity>` (TODO(verify) for FAT cards).
- The "Mac sleeps mid-copy" and "card pulled mid-copy" scenarios haven't been tested on hardware. They share the drive-pull code path, which was tested.
- Card metadata (capture date, camera, serial) isn't read yet (Phases 4 and 6).
- The CLI copies into a flat folder or keeps the card structure. The D6 template layout (`Footage/{camera}`) comes with the Planner in Phase 4.
- Matching loads every index row for a drive into memory each check. Fine for about 50k files; not yet measured at scale.

## Blockers

None. Q2 (re-hash before green) and Q3 (signing team) are still open; Q3 blocks notarization in Phase 8.

## Files and Components

- `backed-build-prompt.md`: authoritative spec.
- `CLAUDE.md`: permanent project rules. `PROJECT.md`: this file.
- `docs/PLAN.md`: architecture, decisions, risks, questions. `docs/SAFETY.md`: each rule's enforcement and tests.
- `Sources/CopyCopiedCore/*`: engine (complete for Phases 1–2). `Sources/copycopied-cli/main.swift`: CLI.
- `Sources/CXXHash/`: vendored xxhash. `Tests/CopyCopiedCoreTests/`: `CoreTests.swift`, `CopierTests.swift`.
- `scripts/make-fake-card.sh`: fake cards and drives. `fake-cards/`: git-ignored images and test database.

## Session Progress

- 2026-10-27, session 3: decided cards stay writable (no read-only remount); added the never-write-to-card guard (fixed a false green when a card was chosen as its own destination); renamed the product to CopyCopied; added the app icon (`scripts/make-icon.swift` → `assets/`), wired into `build-app.sh`; renamed the GitHub repo.
- 2026-10-27, session 2: created and pushed the private GitHub repo; built Phase 3, the menu bar app.
  - Found and fixed: the walker bug that skipped folders containing junk files (safety-relevant); the popover not opening when the icon is hidden by the notch or a menu bar manager; the fallback anchor panel hiding when the app is inactive.
- 2026-10-27, session 1: initialized project memory; wrote PLAN.md; on "build", ran `git init`, vendored xxhash v0.8.3, and built and committed Phases 1 and 2.
  - Bugs found and fixed while doing it: the verify hook ran per read instead of per write; the containing-volume lookup failed for folders that didn't exist yet (this caused duplicate copies); partials were left behind after a drive pull; the disconnect message was raw.

## Handoff Notes

1. **Building:** CopyCopied, a macOS menu bar app that proves camera cards are backed up, using content hashing and verified copies. Spec: `backed-build-prompt.md`.
2. **Where we are:** Phases 0–3 are done, committed and pushed (`origin` = github.com/bythebug/copycopied, private). The CLI and menu bar app work against fake disk images.
3. **Most recent:** the Phase 3 menu bar app and the walker false-green bug fix.
4. **Remaining:** Phases 4–8, and answers to Q2–Q3.
5. **Next:** Phase 4, shoots and folders (see Next Task).
6. **Be careful:**
   - Safety rules beat features.
   - Never let a disconnected drive produce green.
   - Keep `Copier.place` non-overwriting.
   - Queue copies per destination drive (the partial sweep assumes it).
   - Mark camera facts `TODO(verify)`.
   - Don't add dependencies (GRDB, xcodegen, ArgumentParser) without asking.
   - Test shell loops that wait on files must have timeouts. Two hung in session 1; use a Python driver instead.
   - Detach fake images when done.
