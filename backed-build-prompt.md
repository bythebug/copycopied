# Build prompt: **backed.** (card offload for Mac)

> Paste everything below into Claude Code at the root of an empty repo, or save it as `CLAUDE.md` / `SPEC.md` and tell Claude Code: *"Read SPEC.md and start with Phase 0."*

---

## 0. Your role and how to work

You are a senior macOS engineer. You'll build **backed.**, a native menu bar utility for Mac that tells videographers and photographers, with certainty, whether every file on a memory card is already safely copied to their drives. It copies only what's missing and verifies every copy.

How I want you to work:

1. **Plan before you code.** Read this whole spec first. Then write `docs/PLAN.md`: your architecture, module list, the open questions you have, and anything in this spec you think is wrong or risky. Stop and wait for my answers before Phase 1.
2. **Build in the phases in section 12.** Finish each phase's acceptance checks before you start the next one. Commit at the end of every phase with a clear message.
3. **Don't invent camera facts.** Section 9 lists brands. When you don't know exactly how a brand lays out its card or where it stores the serial number, say so. Then build a fallback and leave a `// TODO(verify)` marker with what needs checking. Don't guess silently.
4. **Data safety beats features.** Section 2 lists the safety rules. If any feature conflicts with them, the rule wins. Flag the conflict to me.
5. **Write tests as you go.** The core logic (matching, grouping, dates, folder planning, copy and verify) must be testable without real hardware.

---

## 1. Product in one paragraph

A shooter plugs in a card. backed. opens by itself from the menu bar and reads the card. It fingerprints every file by its **content** (xxh3 hash), not by its name. It then answers one question: **"Is this card actually backed?"** If files are missing from the working drive, it says how many and warns *"Don't format."* The user picks a client and names the shoot. backed. builds the folder structure the way they already file, using the date and camera read from the card. It copies only the missing files, reads every copy back to check it, and then turns **green**. It handles several cards per day, second camera bodies, footage shot past midnight, several working and backup drives, wrong camera clocks, and the working drive being somewhere else. It also catches downloaded music, VO and LUTs and files them into the shoot's Assets folder.

Tagline: *"Is it backed?"* Visual language: dark UI, a particle orb whose colour is the state (**red** = not backed, **grey/white** = reading or unknown, **green** = backed).

---

## 2. Safety rules (never break these)

1. **Cards are read-only.** Never write, rename, delete, touch timestamps, create `.DS_Store`/`._` files or Spotlight indexes, or format. Open all card files read-only. If you can, block Spotlight and Finder metadata writes on card volumes (document how you did this). backed. never offers to format a card.
2. **Green means verified.** A card shows green only when *every* relevant file on it has a byte-identical copy on the required destinations. "Byte-identical" means the destination was **read back from disk** (not from the page cache) and its xxh3 hash matched the source hash.
3. **Memory is never proof.** If a destination drive isn't connected, backed. can say what it *remembers* ("From memory — T7 Shield as of Sat 24 Oct"). It must never show green from memory alone, and it must tell the user to plug the drive in to confirm before formatting.
4. **Never overwrite.** If a destination path already exists with different content, keep both. Write the new file under a non-clashing name (see 7.6). Never replace an existing file.
5. **Matching is by content, never by name.** Two `C0001.MP4` files from different cameras or cards are different files unless their size and hash match.
6. **Copies are atomic.** Write to a temporary `.backed-partial` file, `F_FULLFSYNC` it, verify it, then rename it into place. If a copy is interrupted, never leave a half file under the real name.
7. **No surprises.** Every folder created and every file copied goes into a per-shoot log the user can open.

---

## 3. Tech stack (suggested; challenge it in PLAN.md if you disagree)

- **Swift 6, SwiftUI, AppKit**, macOS 14+ (tell me if a later minimum gets us important APIs).
- **Menu bar:** `NSStatusItem` + `NSPopover` or a borderless `NSPanel`. Don't use `MenuBarExtra`, because the popover must open **programmatically** when a card mounts.
- **Mount detection:** DiskArbitration (`DARegisterDiskAppearedCallback`, `DARegisterDiskDisappearedCallback`, description keys for removable/ejectable, `DeviceProtocol`, volume UUID, volume name). Use `NSWorkspace.didMountNotification` as a fallback.
- **Hashing:** xxh3-64 (or xxh3-128; justify your pick). Vendor the official `xxhash.h` C library through a SwiftPM C target. Hash while reading, in large chunks (e.g. 8–16 MB), to keep throughput high.
- **Uncached read-back:** open the destination with `fcntl(F_NOCACHE)` (or an equivalent) so the verify pass reads the physical disk.
- **Metadata:** AVFoundation (QuickTime/MP4 metadata), ImageIO (EXIF: `Model`, `BodySerialNumber`, `DateTimeOriginal`, `OffsetTimeOriginal`), plus per-brand sidecar parsers (e.g. Sony XML).
- **Persistence:** SQLite through **GRDB** in `~/Library/Application Support/backed/`.
- **File watching:** FSEvents for destination drives and `~/Downloads`.
- **Distribution:** Developer ID, hardened runtime, notarized, **not sandboxed** for v1 (explain the trade-off). Launch at login via `SMAppService`. Ask for the permissions you need (removable volumes, Downloads) with clear explanations.
- **Architecture:** a pure-Swift core package (`BackedCore`) with no UI dependency, containing all logic. The app target is a thin UI on top. Use Swift Concurrency (actors for the indexer and copier), and support cancellation everywhere.

---

## 4. Core concepts and data model

Define these types (adjust names if you like, but keep the concepts):

- **Volume:** a mounted disk. Fields: `volumeUUID`, `name` (e.g. "T7 Shield", "Card A"), `role` (`card | workingDrive | backupDrive | ignored`), `isConnected`, `lastSeen`, `capacity`, `free`.
- **CardFile:** a media or sidecar file on a card. Fields: relative path, size, mtime, hash (once computed), `captureDate` (from metadata), `cameraID`, `kind` (`video | photo | audio | sidecar | proxy | other`).
- **Camera:** `make`, `model`, `serial` (may be partial or missing), `userLabel` (e.g. "FX3", "FX3 B").
- **Client:** a top-level client folder found on a working drive (e.g. "Harbour Coffee Co.").
- **Shoot:** `client`, `name` ("Brand film"), `shootDate` (the logical day), the working drive and folder path, attached cameras → folder labels, cards ingested, `status`.
- **IndexedFile:** a file on a destination drive. Fields: `volumeUUID`, path, size, mtime, inode, hash, `hashVerifiedAt`. This is the drive's **memory**, kept when the drive is unplugged.
- **CopyJob / CopyItem:** source → destination, bytes, state (`queued | copying | verifying | done | failed(reason)`), source hash, destination hash.
- **CardSession:** one insertion of a card. Holds the scan result and the current verdict.

**Fast path for matching:** compare by size first. Only hash candidates whose sizes collide. Cache destination hashes keyed by `(volumeUUID, path, size, mtime, inode)`. Re-hash only when those change.

---

## 5. States and verdicts

Each connected card has exactly one verdict. The orb colour and the copy follow from it.

| Verdict | Orb | Example copy |
|---|---|---|
| `reading(n, total)` | grey/white, animated | "Reading 28 of 148 files on the card…" |
| `notBacked(missing, total, drive)` | red | "148 of 148 files aren't on T7 Shield yet. Don't format." |
| `partiallyBacked(missing, total, drive)` | red | "12 of 148 files aren't on T7 Shield yet. Don't format." |
| `fromMemory(missing, drive, asOf)` | grey | "12 files to copy / From memory — T7 Shield as of Sat 24 Oct. / Plug it in to confirm before formatting." |
| `copying(n, total)` | grey→green fill | "Copying 41 of 148…" |
| `verifying(n, total)` | grey→green | "Checking 41 of 148…" |
| `backed(total, drives)` | green | "148 / 148 files copied. Each one read back and checked." |
| `problem(reason)` | red | Plain-language error + what to do |

If backups are configured as **required**, `backed` needs every required drive to pass. Show each drive's status separately.

---

## 6. UI spec (match the marketing slides)

General: dark, compact, native-feeling. SF Pro; tight, heavy display type only in onboarding and empty states. Accent blue for primary actions, red for danger, green for safe. Use the copy exactly as written here unless you suggest better copy in PLAN.md.

### 6.1 Menu bar item
- A small "b." glyph with a coloured dot. The dot shows the **worst** verdict across connected cards (red > grey > green). There's no dot when no card is connected.

### 6.2 Popover (opens by itself when a card mounts)
Layout from top to bottom:
- **Card row:** the orb (state-coloured, ~48pt), card icon + volume name ("Card A"), and the verdict line(s) from section 5.
- **Actions,** which depend on context:
  - Not backed, no shoot matches → `Choose folder…` (secondary), `New shoot…` (primary, blue).
  - Not backed, a matching shoot exists (same day, same client drive) → `Add to "22.10.26 Brand film"` (primary), plus `New shoot…`.
  - Drive missing → "Plug in T7 Shield to copy." + `New shoot…`.
  - Backed → no primary action. Optional `Show in Finder`.
- Divider.
- **"Also plugged in":** each connected non-card volume with its role on the right ("Working drive", "Backup", or "Not used").
- Footer: `Open backed` (link style, blue) and `Quit`.
- If several cards are inserted, show one card row each, stacked.

### 6.3 New shoot sheet
Title "New shoot". Subtitle: "Creates the folders on {drive} › {year} › {root}" (e.g. "T7 Shield › 2026 › Client work").
- **Client:** combo box with autocomplete from existing client folders. Under it: "Adds to existing Harbour Coffee Co. folder" or "Creates a new client folder".
- **Shoot name:** text field, focused by default.
- **Date:** date stepper with the hint "· taken from the card". Pre-fill it from the card's logical shoot day (section 7.3). If a clock problem was found (section 7.4), show a warning here and make the user confirm.
- **Folders:** a live tree preview. Each node is tagged `already there` (grey) or `new` (blue), and the camera folder is labelled "148 files go here". Example:
  ```
  Harbour Coffee Co.        already there
    22.10.26 Brand film     new
      Footage               new
        FX3                 new
      Project               new
  ```
  Below it, an explanation of conditional folders, e.g. "Video only, so no Photo folder."
- **Camera on this card:** "FX3 · serial …4471 → [FX3 ▾] 148 clips". The dropdown lets the user relabel. backed. remembers the label for that serial from then on.
- `Cancel` / `Create`. Create builds the folders and starts the copy straight away.

### 6.4 Main window ("Open backed")
- **Shoots:** a list of shoots → for each: the cards ingested, the cameras, per-drive status, and the log.
- **Drives:** working drives, backup drives (as many as the user wants, all in one list), last-indexed time, re-index button.
- **Cameras:** known bodies by serial → label.
- **Settings:** folder template (7.5), root/year folders, day cutoff hour, which file kinds to copy, required vs optional backups, Downloads sorting on/off, launch at login.

### 6.5 Orb
A soft particle sphere: Metal or a SwiftUI `Canvas` shader. It breathes gently while reading, fills from grey to green during copying, and settles as a calm green when done. Keep CPU/GPU use negligible when idle, and stop animating when the popover is closed. Add a static fallback for Reduce Motion.

---

## 7. Feature specs

### 7.1 Card detection and scanning
- Treat a volume as a card when it's removable or ejectable and looks like a camera card (it has `DCIM/`, `PRIVATE/M4ROOT/`, `CLIP/`, a BRAW/DJI/GoPro layout, etc.). Add a setting to manually mark any volume as card or not card, so it works with odd readers and with disk images during testing.
- Walk the whole card. Ignore system junk (`.Spotlight-V100`, `.fseventsd`, `.Trashes`, `._*`, `.DS_Store`, `System Volume Information`).
- Classify each file: video, photo (including RAW: ARW, CR3, NEF, RW2, RAF, DNG, HEIC, JPG), audio, sidecar (XML, XMP, THM, LRV, etc.), proxy.
- Stream progress to the UI: "Reading N of M files on the card…". Large cards must stay responsive. Read metadata first and hash afterwards, and let matching start before hashing has finished.

### 7.2 "Is it backed?" matching
- For each card file that should be copied, look for any IndexedFile on the destination with the same **size and hash**. Path and name don't matter.
- Index destination drives in the background when they connect (incrementally, through FSEvents plus the cache). Keep the index when they disconnect; that's the "memory".
- Same name but different content must stay red. Example: `C0001.MP4` from A cam serial …4471 and from B cam serial …5190 are different files.
- Same content under a different name or path counts as backed. The user may already have copied files by hand.

### 7.3 Shoot day and grouping several cards
- **Logical shoot day:** capture timestamps before a cutoff hour (default 05:00, configurable) belong to the previous day. Example: Card C shot at 00:38 joins the 22.10.26 shoot.
- **Joining a shoot:** when a new card's logical day and working drive match an open shoot, offer "Add to {shoot}" as the primary action. The second card joins the same shoot.
- **Second body:** if the same model shows up with a **different serial** inside the same shoot, create a sibling camera folder with the next suffix ("FX3 B", then "FX3 C"). Remember serial → label.
- **Same body again:** clips from a known serial go into its existing camera folder (e.g. Cards A and C → `FX3`).
- If metadata gives no serial, ask the user which body the card came from. Never merge silently.

### 7.4 Camera clock checks
Before a folder gets a date, flag the card if:
- capture dates are before 2010 or in the future;
- the card's dates are spread implausibly, or differ sharply from file-system timestamps;
- the camera's dates are far from the last known shoot for that serial, when the user's intent suggests otherwise.
Show the problem plainly ("This camera's clock looks wrong: clips say 1 Jan 2000"), suggest a date (e.g. today, or the date of other cards from that day), and make the user confirm. Only the folder date changes; files are never altered.

### 7.5 Folder template ("the way you already file")
- Tokens: `{year}`, `{client}`, `{date:dd.MM.yy}` (any date format), `{shoot}`, `{camera}`, `{kind}`.
- Default:
  ```
  {drive}/{year}/Client work/{client}/{date:dd.MM.yy} {shoot}/
      Footage/{camera}/
      Photo/{camera}/      ← only if the card has stills
      Audio/               ← only if the card has audio
      Project/
      Assets/Music, Assets/VO, Assets/LUTs   ← created when first used
  ```
- **On first run, scan the chosen root** and infer the user's pattern (year folders? date format? "Footage" vs "Video"?). Offer it as the template, with a preview the user can accept or edit.
- Folders for absent kinds aren't created, and the sheet says why ("Video only, so no Photo folder.").

### 7.6 Copy and verify
- Copy only files that are missing (by content). Check free space first and stop with a clear message if it isn't enough.
- Per file: read the source in chunks and hash it while writing to `name.backed-partial` → `F_FULLFSYNC` → reopen the destination uncached and hash it → compare → atomic rename → keep the original modification and creation dates where the file system allows.
- **Name collisions** on the destination (same name, different content, e.g. the card was reformatted and C0001 used again): never overwrite. Write `C0001 (2).MP4` and record it in the log. Make this behaviour configurable, e.g. prefix with the card or roll name instead.
- Default layout: media lands in the camera folder, with sidecars kept beside their clips. Optionally keep the full original card structure under a per-card roll folder. Tell me in PLAN.md which default is better for NLE relinking (Sony XML, proxies) and why.
- Copy to the working drive first, then to each backup (or in parallel if they're on separate buses). Show per-drive progress.
- **Interruptions:** if a drive is ejected or the card pulled, stop cleanly, delete the partials, and mark the session. Re-inserting resumes with only what's still missing.
- Retry a failed verify once. If it fails again, show a hard red error naming the file.
- Done state: "148 / 148 files copied · Each one read back and checked." Send a macOS notification if the popover is closed.

### 7.7 Drive not connected ("Drive at home?")
- If the card's shoot or default working drive isn't connected, compare against the drive's stored index and show the `fromMemory` verdict: "12 files to copy / From memory — T7 Shield as of Sat 24 Oct. / Plug it in to confirm before formatting." along with "Plug in T7 Shield to copy."
- When the drive is plugged in, re-check automatically and update.

### 7.8 Multiple working drives
- Each shoot belongs to one working drive. A card that matches an existing shoot is routed to the drive that shoot is on. For new shoots, the user chooses (default: last used, or the drive with the most free space; say which in the UI).

### 7.9 Downloads → shoot Assets ("That track belongs with the shoot")
- Watch `~/Downloads` (opt-in). When an audio file (`wav, mp3, aiff, m4a, flac`) or LUT (`cube, 3dl`) finishes downloading (ignore `.crdownload`, `.download`, `.part`), drop a small orb next to the menu bar icon labelled "click to sort".
- Clicking it moves the file into the **active shoot's** `Assets/Music`, `Assets/VO` or `Assets/LUTs`. The active shoot is the one most recently ingested or opened; offer a quick picker to choose another. Guess VO vs music from the filename/duration, but let the user correct it.
- The orb fades after a while if ignored. Never move anything without that click.

---

## 8. Indexing performance

- Index destinations in the background at low QoS. Pause indexing while a copy runs on the same drive.
- Hash only when needed: files whose size matches a card file get priority, and the rest fill in lazily.
- Target: a 128 GB card on a fast reader plus SSD copies at close to hardware speed (verify adds one read pass). Report MB/s in the main window.
- Index cost on a drive with 50k files should be minutes the first time and seconds after that.

---

## 9. Camera support

Required brands: **Sony, Canon, Nikon, Lumix (Panasonic), Fuji, Blackmagic, DJI, GoPro, iPhone** (imported files, or iPhone cards via an adapter, if applicable; tell me what's realistic).

Build a `CameraProfile` protocol:
```swift
protocol CameraProfile {
  func matches(volume: CardVolume) -> Bool
  func enumerateMedia(in: CardVolume) -> [CardFile]           // incl. sidecar grouping
  func camera(for file: CardFile) async -> Camera?             // make/model/serial
  func captureDate(for file: CardFile) async -> Date?
}
```
- For each brand, document in `docs/cameras.md` where model, serial and capture time live (EXIF, MP4/QuickTime atoms, XML sidecars, maker notes, BRAW SDK, GPMF, etc.), **marking what you've verified and what you're assuming**.
- A generic fallback profile (EXIF, AVFoundation, file dates) must make any unknown card usable.
- Sidecars and proxies travel with their parent clip and count towards "backed".

---

## 10. Edge cases you must handle and test

- Two cameras, same filenames, same day → separate files, both copied, neither marked backed by the other.
- A card reformatted mid-shoot reuses `C0001` → collision handled, nothing overwritten.
- Clips across midnight → one shoot day.
- Same model, two bodies → `FX3` and `FX3 B`.
- No serial in metadata → ask the user.
- Camera clock reset to 2000 → flagged before folders are named.
- Card pulled mid-copy, drive pulled mid-copy, Mac sleeps mid-copy → no partial files left, clean resume.
- Destination is full → stop before starting.
- Destination is exFAT/FAT32 (4 GB file limit on FAT32; 2-second timestamp precision) → handle or warn.
- Case-insensitive destination clash (`C0001.mp4` vs `C0001.MP4`).
- Files already copied by hand into a different structure → recognised as backed.
- Bit flip simulated on the destination → verify catches it, red, file named.
- Very large cards (1 TB+, 10k+ files) → UI stays responsive.
- Several cards inserted at once → independent sessions, sensible queuing per destination drive.

---

## 11. Testing

- `BackedCore` unit tests for: matching, day logic, body labelling, clock checks, template planning, collision naming, and the copy/verify state machine (with an injectable file-system layer).
- **Fake cards:** a script `scripts/make-fake-card.sh` that uses `hdiutil create -fs ExFAT` to build disk images that look like Sony, Canon and GoPro cards, with generated media files carrying realistic metadata where possible (or a mocked metadata provider). The "treat as card" debug setting lets these act as cards.
- **Corruption test:** a hook that flips a byte in a destination file between write and verify; it must fail.
- Integration test: insert fake Card A → new shoot → copy → green; insert Card B (second body) → "FX3 B"; insert Card C (after midnight) → same shoot.

---

## 12. Build phases and acceptance checks

**Phase 0: Plan.** `docs/PLAN.md` with your architecture, risks and questions. Wait for me.

**Phase 1: Core engine, no UI.** Volume detection, card scan, hashing, destination index in SQLite, matching, verdicts. CLI target `backed-cli status` that prints the verdict for the connected cards.
✅ Fake card + fake drive: prints "148 of 148 files aren't on T7 Shield yet." Copy them by hand into any folder → it prints backed.

**Phase 2: Copy and verify.** Atomic copy, uncached read-back, collisions, resume, free-space checks, logs. `backed-cli copy --to <path>`.
✅ All the copy edge cases in section 10 pass, including the byte-flip test.

**Phase 3: Menu bar app.** Status item, auto-opening popover, verdict rows, "Also plugged in", Open/Quit, notifications, launch at login.
✅ Inserting a fake card opens the popover by itself, which shows reading progress, then red.

**Phase 4: Shoots and folders.** Template inference from the existing root, New shoot sheet with live tree preview, client autocomplete, camera labelling, joining shoots across several cards, second body, midnight cutoff, clock checks.
✅ The three-card integration test passes; the tree preview matches what gets created on disk.

**Phase 5: Drives.** Several working drives, backups list, required vs optional, the from-memory verdict, auto re-check on reconnect.
✅ Unplug the drive → grey "From memory…" verdict, never green. Plug it back in → green after verification.

**Phase 6: Camera profiles.** All brands in section 9 plus the fallback, with `docs/cameras.md`.

**Phase 7: Downloads sorting** with the orb UI.

**Phase 8: Polish.** The orb in Metal/Canvas, motion, dark UI that matches the slides, accessibility (VoiceOver labels for every verdict, Reduce Motion), performance pass, signing and notarization script, a first-run onboarding that picks the working drive and root folder.

---

## 13. Out of scope for v1 (mention if you think otherwise)

- Cloud backup, team sync, transcoding, proxy generation, checksum report exports such as MHL (but design the log so an MHL export is easy to add later), Windows.
- The waitlist landing page (separate project).

---

## 14. Deliverables

- Xcode project (or SwiftPM + xcodegen; justify your pick) with the `BackedCore` package, the app target and the CLI target.
- `docs/PLAN.md`, `docs/cameras.md`, `docs/SAFETY.md` (how each rule in section 2 is enforced and tested).
- Scripts: fake card generator, build/sign/notarize.
- A README for running it locally with fake cards.

Start with Phase 0.
