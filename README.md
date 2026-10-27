# backed.

Tells you, with certainty, whether every file on a camera card is safely copied to your drives. It copies only what's missing and verifies every copy. Spec: `backed-build-prompt.md`. Plan: `docs/PLAN.md`. Safety: `docs/SAFETY.md`.

Status: core engine and copy/verify (Phases 1–2) work through `backed-cli`. The menu bar app comes next.

## Run locally with fake cards

```sh
swift test                                              # core tests, no hardware
swift build
scripts/make-fake-card.sh canon "Card A" 148            # exFAT image that looks like a card, mounted
scripts/make-fake-card.sh drive "T7 Shield"             # empty APFS "drive"

B=.build/debug/backed-cli
$B volumes                                              # what's plugged in, and roles
$B role "/Volumes/T7 Shield" working
$B status                                               # Card A [red] 148 of 148 files aren't on T7 Shield yet…
$B copy --to "/Volumes/T7 Shield/2026/Test shoot"       # copies missing files, verifies each one
$B status                                               # Card A [green]
hdiutil detach "/Volumes/T7 Shield"; $B status          # grey: From memory — never green
```

Add `--db fake-cards/test.sqlite` to keep test runs out of your real database. Images live in `fake-cards/` (git-ignored). Eject them with `hdiutil detach "/Volumes/<name>"`.
