# Project State

## Last Verified

2026-10-27 — initial project initialization. Directory contained only `backed-build-prompt.md`.

## Project Goal

**backed.** — a native macOS menu bar utility for videographers/photographers. When a camera card is inserted it fingerprints every file by content (xxh3), answers "Is this card actually backed?" against working/backup drives, copies only missing files into a shoot folder structure the user already uses, verifies every copy with an uncached read-back, then shows green. Full spec: `backed-build-prompt.md`.

## Requirements

### Confirmed

All from `backed-build-prompt.md`:
- Safety rules §2 (read-only cards, verified-green only, memory never proof, never overwrite, content matching, atomic copies, per-shoot log).
- Verdict model §5 (`reading`, `notBacked`, `partiallyBacked`, `fromMemory`, `copying`, `verifying`, `backed`, `problem`) driving orb colour and copy.
- UI §6: status item with worst-verdict dot, auto-opening popover, New shoot sheet with live folder tree preview, main window (Shoots/Drives/Cameras/Settings), particle orb with Reduce Motion fallback.
- Features §7: card detection/scan, content matching, logical shoot day (cutoff 05:00), multi-card shoots, second-body labelling (`FX3 B`), clock checks, folder template + inference, copy/verify with collisions/resume, from-memory verdict, multiple working drives, Downloads → Assets sorting (opt-in, click required).
- Brands §9: Sony, Canon, Nikon, Panasonic, Fuji, Blackmagic, DJI, GoPro, iPhone + generic fallback; `docs/cameras.md` marking verified vs assumed.
- Testing §11 and phases §12 (0–8) with acceptance checks; commit per phase.
- Deliverables §14: project with `BackedCore`, app target, CLI target; `docs/PLAN.md`, `docs/cameras.md`, `docs/SAFETY.md`; fake-card + sign/notarize scripts; README.
- Phase 0 must stop and wait for user answers before Phase 1.

### Assumptions

- Tech stack in spec §3 (Swift 6, SwiftUI/AppKit, DiskArbitration, vendored xxhash, GRDB, FSEvents, not sandboxed, SMAppService) is the baseline unless PLAN.md argues otherwise.
- Minimum macOS 14 per spec; machine runs macOS 27.2, so newer-API trade-offs are a PLAN.md question.

### Open Questions

- Project is not a git repository; spec requires per-phase commits. Should `git init` be run (and is there a remote)?
- SwiftPM-only vs xcodegen (not installed) vs checked-in Xcode project — to be decided in PLAN.md.
- xxh3-64 vs xxh3-128 — to be justified in PLAN.md.
- Default copy layout (camera folder vs per-card roll folder preserving card structure) for NLE relinking — spec asks for a recommendation in PLAN.md.
- iPhone support scope — spec asks what is realistic.
- Signing identity / Apple Developer team for notarization — UNKNOWN.

## Current Status

NOT STARTED — Phase 0 (plan) has not begun. No code, no `docs/`.

## Completed

- Project memory files created: `CLAUDE.md`, `PROJECT.md` (2026-10-27).

## In Progress

Nothing.

## Next Task

**Phase 0:** read `backed-build-prompt.md` in full and write `docs/PLAN.md` containing: architecture (BackedCore / app / CLI split, actors, data flow), module list, decisions requested by the spec (build system, xxh3 width, min macOS, default copy layout, sandboxing trade-off, iPhone realism, Spotlight/Finder metadata blocking on cards), risks and disagreements with the spec, and the open questions above. Then stop and wait for the user's answers. Ask about `git init` before the first phase commit.

## Remaining Work

### Required
- Phase 0: `docs/PLAN.md`, user sign-off.
- Phase 1: core engine + `backed-cli status`.
- Phase 2: copy/verify + `backed-cli copy --to`.
- Phase 3: menu bar app.
- Phase 4: shoots, folders, template inference, multi-card/body/midnight/clock logic.
- Phase 5: multiple drives, backups, from-memory verdict.
- Phase 6: camera profiles + `docs/cameras.md`.
- Phase 8 (required parts): accessibility, signing/notarization script, onboarding; `docs/SAFETY.md`, README, fake-card script.

### Desirable
- Phase 7: Downloads sorting.
- Phase 8: Metal/Canvas orb polish, performance pass, MB/s reporting.

### Optional
- Out of scope for v1 (§13): cloud, team sync, transcoding, proxies, MHL export (design log to allow it later), Windows, landing page.

## Architecture

None exists yet. Proposed (spec §3, not yet adopted): `BackedCore` pure-Swift package (scanner, indexer actor, matcher, verdict engine, planner, copier actor, GRDB store, camera profiles) + thin SwiftUI/AppKit menu bar app + `backed-cli`.

## Important Decisions

None made yet beyond the spec. Record PLAN.md decisions here once the user approves them.

## Dependencies

None yet. Proposed by spec: GRDB (SQLite), vendored `xxhash.h` (C target).

## Commands

None verified yet. Toolchain present: `swift` 6.4, `xcodebuild` (Xcode 27.1), `hdiutil`, `git`. `xcodegen` missing.

## Verification

- 2026-10-27: `command -v` / `swift --version` / `xcodebuild -version` — Swift 6.4, Xcode 27.1, macOS 27.2 confirmed; xcodegen absent; directory is not a git repo.

## Known Issues

None.

## Blockers

None. (Phase 1 is gated on user answers to PLAN.md, by design.)

## Files and Components

- `backed-build-prompt.md` — authoritative product/engineering spec.
- `CLAUDE.md` — permanent project rules (safety, workflow, architecture constraints).
- `PROJECT.md` — this file; changing state.

## Session Progress

- 2026-10-27: Initialized project memory from the spec. No code written. Next: Phase 0 PLAN.md.

## Handoff Notes

1. **Building:** backed., a macOS menu bar app that proves camera cards are backed up via content hashing and verified copies. Spec in `backed-build-prompt.md`.
2. **Where we are:** nothing implemented; only spec + memory files exist; not a git repo.
3. **Most recent:** project initialization.
4. **Remaining:** all phases 0–8.
5. **Next:** write `docs/PLAN.md` (Phase 0) and stop for user review.
6. **Be careful:** the safety rules in spec §2 override every feature; don't skip the Phase 0 stop; don't invent camera metadata facts (use `TODO(verify)`); don't install xcodegen/GRDB or other deps without approval; commit per phase only after git is set up with the user's consent.
