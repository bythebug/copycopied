# CopyCopied — project instructions

Native macOS menu bar utility that verifies camera cards are backed up (content-hash matching, verified copies).
Full spec: `backed-build-prompt.md` (authoritative for requirements). Current state: `PROJECT.md`.

## Name

- The product is **CopyCopied** (renamed from "backed." on 2026-10-27, because that name belongs to someone else's product). Never use "backed" as a brand in code, UI, paths, bundle IDs or docs. The spec file keeps its original wording as the historical brief.
- Identifiers: modules `CopyCopiedCore` / `CopyCopiedApp` / `copycopied-cli`; bundle `CopyCopied.app`, executable `copycopied`, ID `com.bythebug.copycopied` (placeholder until signing, Q3); data in `~/Library/Application Support/CopyCopied/`; partial files `*.copycopied-partial`; menu bar glyph "cc.".
- Words like "backed up" / `Verdict.backed` describe a state, not the brand, and are fine.
- The icon is drawn by `scripts/make-icon.swift` → `assets/AppIcon.icns`, `assets/icon.png`, `assets/favicon.png`. Edit the script, not the PNGs.

## Workflow rules (from spec §0)

- Build in the phases of spec §12. Finish each phase's acceptance checks before starting the next. Commit at the end of every phase.
- Phase 0 = write `docs/PLAN.md` (architecture, modules, questions, risks/disagreements with the spec), then STOP and wait for the user's answers before Phase 1.
- Never invent camera facts. Unknown card layouts / serial locations get a fallback plus a `// TODO(verify): <what to check>` marker, and are recorded as assumed (not verified) in `docs/cameras.md`.
- If a feature conflicts with a safety rule, the rule wins — flag the conflict to the user.
- Write tests as you go. Core logic (matching, grouping, dates, folder planning, copy/verify) must be testable without real hardware (injectable file-system layer).

## Safety rules — never break (spec §2)

1. Cards are read-only: open read-only; never write, rename, delete, touch timestamps, create `.DS_Store`/`._*`/Spotlight indexes, or format. Never offer to format.
2. Green only when every relevant file has a byte-identical copy on all required destinations, verified by an **uncached** read-back (`F_NOCACHE`) whose xxh3 matches the source hash.
3. Memory (stored index of a disconnected drive) is never proof — never green from memory.
4. Never overwrite an existing destination file; write under a non-clashing name.
5. Match by content (size + hash), never by name.
6. Atomic copies: write `*.copycopied-partial` → `F_FULLFSYNC` → verify → rename. No half files under real names.
7. Log every folder created and file copied in a per-shoot log.

`docs/SAFETY.md` must document how each rule is enforced and tested; keep it in sync when touching copy/scan code.

## Architecture constraints

- `CopyCopiedCore`: pure Swift package, no UI imports; all logic lives here. App and CLI (`copycopied-cli`) are thin layers on top.
- Swift 6 strict concurrency; actors for indexer and copier; support cancellation everywhere.
- Menu bar via `NSStatusItem` + `NSPopover`/`NSPanel` — not `MenuBarExtra` (popover must open programmatically on card mount).
- Hashing: vendored official `xxhash.h` via a SwiftPM C target (no Swift hashing package).
- Persistence: system SQLite3 (no GRDB, PLAN.md D3) in `~/Library/Application Support/CopyCopied/`.
- Not sandboxed for v1; Developer ID + hardened runtime + notarization.
- Stack choices above are the spec's suggestions; deviations must be argued in `docs/PLAN.md` and approved by the user before adopting.

## Toolchain (verified 2026-10-27)

- Swift 6.4, Xcode 27.1, macOS 27.2 (Apple Silicon). `hdiutil` available for fake cards.
- Build system is SwiftPM only (PLAN.md D1); the app bundle comes from `scripts/build-app.sh`. `xcodegen` is not installed; don't add it without asking.

## Testing

- Fake cards via `scripts/make-fake-card.sh` (`hdiutil create -fs ExFAT`), used with the "treat as card" debug setting.
- Required: byte-flip corruption test must fail verify; edge cases in spec §10 must have tests.
