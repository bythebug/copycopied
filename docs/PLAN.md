# backed. — Plan (Phase 0)

Status: written 2026-10-27. The user said "build" without reviewing it, so the **Recommended** choices below are the working defaults. Any of them can be overturned; each one notes where it would bite.

## 1. Architecture

```
┌──────────── backed (app, Phase 3+) ─────────────┐   ┌──── backed-cli ────┐
│ NSStatusItem + NSPopover, SwiftUI views, orb    │   │ status, role, copy │
│ DiskArbitration session → CardSession actors    │   └─────────┬──────────┘
└───────────────────────┬─────────────────────────┘             │
                        ▼                                       ▼
┌──────────────────────── BackedCore (no UI imports) ───────────────────────┐
│ Hashing      xxh3-128 streaming over 8 MB chunks, optional F_NOCACHE      │
│ Volumes      mounted-volume snapshot (FileManager); DA lives in the app   │
│ CardScanner  card heuristics, walk, junk filter, kind classification      │
│ Store        SQLite (system libsqlite3): volumes, indexed_file, settings…  │
│ Indexer      walk destination, upsert stat, lazy hash (size-priority)     │
│ Matcher      size → hash candidates → per-drive result → Verdict          │
│ (Phase 2) Copier   partial → F_FULLFSYNC → uncached verify → rename, log   │
│ (Phase 4) Planner  template tokens, tree preview, shoot day, body labels  │
│ (Phase 6) CameraProfile per brand + generic fallback                      │
└───────────────────────────────────────────────────────────────────────────┘
                        ▼
                CXXHash (C target: vendored official xxhash.h v0.8.3, BSD-2)
```

Data flow for "Is it backed?": scan card (stat only) → for each relevant file, look up `indexed_file` rows on each destination with the same size → none: missing. Some: hash the card file (and any unhashed candidates, uncached) → equal hash: present. Then work out the verdict per drive, then overall.

## 2. Decisions

| # | Decision | Recommended | Why / trade-off |
|---|---|---|---|
| D1 | Build system | **SwiftPM only** (core, CLI, tests, and the app as an executable target). `scripts/build-app.sh` builds the `.app` bundle (Info.plist with `LSUIElement`), then signs and notarizes it. | No new tool (xcodegen isn't installed). Plain-text and diffable, and `swift test` runs without a GUI. Cost: no asset catalogs or SwiftUI previews in Xcode. A `.metal` orb shader would need a manual `metal` compile step in the script. |
| D2 | Hash | **xxh3-128** | Same speed as xxh3-64 on arm64, and both are limited by I/O. 64 bits gives roughly 3×10⁻⁶ birthday risk across 10M files. That's small, but this is the "safe to format" decision, so I take the extra 64 bits for free. Stored as a 32-char hex string. |
| D3 | Persistence | **System SQLite3 (`import SQLite3`) with a ~100-line wrapper**, not GRDB | The spec suggested GRDB but invited challenges. About 6 tables, no ORM needed, zero dependencies (global rule: prefer platform-native). Revisit if migrations get painful. |
| D4 | Min macOS | **14** | Nothing needed from 15 or later. `SMAppService`, Canvas and `TimelineView` all exist on 14. |
| D5 | Sandbox | **Not sandboxed** (agree with the spec) | Watching every volume, DiskArbitration mount approval, FSEvents on arbitrary drives and moving files out of `~/Downloads` would each need user-picked security-scoped bookmarks. That would break "plug in and it just knows". Cost: no Mac App Store and a bigger blast radius, so the read-only and never-overwrite rules are enforced in code and tests (see SAFETY.md). |
| D6 | Default copy layout | **Flat camera folder, sidecars beside clips** (`Footage/FX3/C0001.MP4` + `C0001M01.XML`). **Card structure is kept under a roll folder** automatically for formats that depend on their folder layout. | Premiere/Resolve relink Sony XML metadata by matching basename in the same folder (assumption, TODO(verify)). Proxies are attached by filename, so they can live in `Footage/FX3/Proxy/`. AVCHD (`PRIVATE/AVCHD`), XDCAM/XF MXF `CLIP`/`CONTENTS` and P2 trees are read by NLEs as a whole structure. Flattening them breaks spanned clips (TODO(verify) per format in cameras.md). |
| D7 | Card metadata writes | **Recommend: remount card volumes read-only** through a DiskArbitration mount-approval callback (setting on by default). | `mdutil -i off` writes to the volume, so it's not allowed. A read-only mount stops Finder `.DS_Store`/`._`, Spotlight `.Spotlight-V100` and `.fseventsd` writes at the kernel. Cost: the user can't delete files from the card on the Mac while backed. runs (they shouldn't anyway). **Question Q1.** |
| D8 | iPhone | **(a)** external SSD used for iPhone ProRes recording is handled as a card by the generic profile. **(b)** "Treat folder as card" for already-imported files. **No** PTP/ImageCaptureCore in v1. | An iPhone doesn't mount as a volume, and PTP import is a separate product. |
| D9 | Which files count | Relevant = `video, photo, audio, sidecar, proxy`. `other` (camera database files such as Sony `MEDIAPRO.XML`/`STATUS.BIN`, TODO(verify)) is listed but not required for green. | Camera catalog files get rewritten by the camera and aren't media. |
| D10 | Trusting cached destination hashes | Hashes are always computed with `F_NOCACHE`. A cached hash is reused while `(volumeUUID, path, size, mtime, inode)` is unchanged **and the drive is connected now** (re-stat'd during this check). | This is the spec §4 cache. **Question Q2:** should we re-hash the matched destination files before green on cards about to be formatted? It's safer but costs one full read. |
| D11 | Sleep mid-copy | `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep)` while copying. Closing the lid still sleeps, so resume handles it. | |
| D12 | Verify retry | Re-read once (uncached). If it still differs, re-copy once. If that fails, hard red naming the file. | The spec says "retry once" without saying what to retry. |

## 3. Module list (BackedCore)

`Hash.swift`, `Volume.swift`, `CardScanner.swift`, `Store.swift`, `Indexer.swift`, `Matcher.swift` (+ `Verdict`) in Phase 1. Then `Copier.swift`/`CopyLog.swift` (2), `Planner.swift`/`ShootDay.swift`/`ClockCheck.swift`/`BodyLabels.swift` (4), and `Profiles/*.swift` (6). The indexer and copier become actors when the app starts driving them concurrently (Phase 3). Phase 1 code is synchronous and checks `Task.isCancelled` in every chunk loop.

## 4. Risks

- **exFAT/FAT behaviour**, all TODO(verify) on real media: `F_FULLFSYNC` may return `ENOTSUP` (we'll fall back to `fsync` and log it). `inode` on msdosfs/exfat may not be stable across remounts, which only costs re-hashing. mtime is accurate to 2 s on FAT32. FAT32 can't hold files over 4 GB (check before copying, and stop).
- **Volume identity:** a card reformatted in camera probably gets a new volume serial/UUID (TODO(verify)). Matching is by content, so this only affects session bookkeeping.
- **Stale cache = false green.** Mitigated by the stat key plus the connected-drive requirement (D10, Q2).
- **Metadata extraction per brand** is the least certain area. Everything goes in cameras.md as verified or assumed, and the generic fallback (EXIF/AVFoundation/file dates) always works.
- **Particle orb CPU use:** use Canvas + `TimelineView` that pauses when the popover is hidden. Metal only if Canvas costs more than ~1% CPU.

## 5. Where I disagree with or extend the spec

- GRDB → system SQLite (D3). xcodegen → SwiftPM (D1).
- "Block Spotlight/Finder writes" is best done with a read-only mount (D7), which the spec didn't mention.
- §7.6 "keep the original creation date" uses `setattrlist`/`URLResourceValues.creationDate`. exFAT keeps it; FAT32 keeps it only to 2 s precision.
- §7.4's third clock check ("far from the last known shoot … when intent suggests otherwise") is vague. I'll implement it as: the card's logical day is more than 30 days from the serial's last shoot **and** from today → warn.

## 6. Open questions

- **Q1** Remount cards read-only by default (D7)?
- **Q2** Re-hash matched destination files before green (D10)?
- **Q3** Signing: Developer ID team ID for notarization?
- **Q4** Git remote? (A local repo is initialised with one commit per phase. Nothing is pushed.)
