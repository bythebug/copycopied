# backed. — project instructions

Native macOS menu bar utility that verifies camera cards are backed up (content-hash matching, verified copies).
Full spec: `backed-build-prompt.md` (authoritative for requirements). Current state: `PROJECT.md`.

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
6. Atomic copies: write `*.backed-partial` → `F_FULLFSYNC` → verify → rename. No half files under real names.
7. Log every folder created and file copied in a per-shoot log.

`docs/SAFETY.md` must document how each rule is enforced and tested; keep it in sync when touching copy/scan code.

## Architecture constraints

- `BackedCore`: pure Swift package, no UI imports; all logic lives here. App and CLI (`backed-cli`) are thin layers on top.
- Swift 6 strict concurrency; actors for indexer and copier; support cancellation everywhere.
- Menu bar via `NSStatusItem` + `NSPopover`/`NSPanel` — not `MenuBarExtra` (popover must open programmatically on card mount).
- Hashing: vendored official `xxhash.h` via a SwiftPM C target (no Swift hashing package).
- Persistence: SQLite via GRDB in `~/Library/Application Support/backed/`.
- Not sandboxed for v1; Developer ID + hardened runtime + notarization.
- Stack choices above are the spec's suggestions; deviations must be argued in `docs/PLAN.md` and approved by the user before adopting.

## Toolchain (verified 2026-10-27)

- Swift 6.4, Xcode 27.1, macOS 27.2 (Apple Silicon). `hdiutil` available for fake cards.
- `xcodegen` is NOT installed — do not install it without asking; decide SwiftPM vs xcodegen vs plain Xcode project in PLAN.md.

## Testing

- Fake cards via `scripts/make-fake-card.sh` (`hdiutil create -fs ExFAT`), used with the "treat as card" debug setting.
- Required: byte-flip corruption test must fail verify; edge cases in spec §10 must have tests.
