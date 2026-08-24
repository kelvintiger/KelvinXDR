# Experimental Space Writes Release Gate

## Context

Space Layout Protection is a beta proof of concept. Its hardware-free logic passes, but an
accepted cross-managed-display move did not verify on the local macOS Sequoia 15.7.9 machine.
The same bridged operation has encouraging external evidence on macOS Tahoe 26.4+, while this
KelvinXDR implementation has not been validated on Tahoe or macOS 27.

A Git commit message is not visible to people using the app. Shipping this branch therefore
requires a user-visible warning and an enforcement boundary that keeps all experimental Space
writes off until someone deliberately opts in.

## Selected approach

Use both visible Experimental labeling and a default-off write gate.

- Rename the menu and submenu to `Space Layout Protection (Experimental)`.
- Add `Enable Experimental Space Writes` as a separate, unchecked preference.
- Keep read-only inventory, capability reporting, `--spaces-dump`, and normal-layout Save
  available without the write gate.
- Require the gate for manual Restore, automatic restoration, missing-desktop creation through
  restore/conversion, and fullscreen-to-normal conversion.
- Keep `Automatically Restore Layouts` separately opt-in and disabled unless experimental
  writes are enabled.
- Turning experimental writes off also turns automatic restoration off, cancels pending
  topology work, and prevents an in-progress restore or conversion from starting another write.
- Existing retry bounds, membership verification, geometry verification, and the session
  circuit breaker remain in force after opt-in.

## Manager enforcement

The manager owns a new persisted Boolean preference, defaulting to false. Enforcement occurs
inside the manager rather than only through disabled menu items, so Settings actions and future
callers cannot bypass it.

Restore and conversion entry points check the gate before starting. Long-running operations
re-check it immediately before write loops and between windows. Automatic restoration reports
enabled only when both its existing preference and the experimental write gate are enabled.
Disabling the gate clears the automatic preference and invalidates pending debounce work.

Save remains available because it only inventories windows and writes KelvinXDR profile files;
it does not move windows, create desktops, or change fullscreen state.

## User experience

The submenu title continuously identifies the feature as Experimental. The write toggle appears
before automatic restoration. When the gate is off, Restore, automatic restoration, and Convert
are disabled; Save remains available when its read capabilities exist.

Documentation states that:

- the write path is experimental and must be explicitly enabled;
- the Sequoia cross-display validation failed to verify;
- Tahoe 26.4+ has external supporting evidence but no local KelvinXDR validation;
- macOS 27 is untested;
- failed operations may leave extra normal desktops or partially changed normal-window state.

## Verification

- Add hardware-free tests for default-off semantics, automatic-restore coupling, and write
  eligibility when the experimental gate is disabled.
- Run `STRICT=1 ./build.sh test` with task-specific module caches if needed.
- Run a strict full app build without installing or launching.
- Run `git diff --check` and focused searches confirming the Experimental labels and manager
  gates are present.
- Do not repeat live Space writes, fullscreen conversion, or dock/undock validation as part of
  this release-label change.

## Release and source control

Commit the implementation separately from this design record. Push only
`codex/mission-control-normal-spaces` to `origin`; do not merge, force-push, or modify the clean
main checkout or frozen Claude worktree.
