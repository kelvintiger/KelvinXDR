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

Keep the feature out of the menu bar and use both visible Experimental labeling in Settings
and a default-off write gate.

- Remove the Space Layout Protection item and submenu from the menu bar entirely.
- Rename the Settings section to `Space Layout Protection — Experimental` and add a concise
  warning that Space writes are unverified and may leave partially changed window state.
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

## Settings-only user experience

Settings is the only user-facing surface for Space Layout Protection. The menu bar contains no
Space Layout Protection item, status, or action.

The existing Space Layouts profile section becomes `Space Layout Protection — Experimental`.
It contains, in order:

1. A concise warning about the failed Sequoia verification and possible partial changes.
2. `Enable Experimental Space Writes`, off by default.
3. `Automatically Restore Layouts`, separately opt-in and disabled while writes are off.
4. Existing topology/profile selection and non-Space-writing Save/profile-management controls.
5. `Restore Now`, disabled while writes are off or runtime capabilities are unavailable.
6. `Convert Fullscreen Apps to Dedicated Desktops…`, disabled while writes are off or runtime
   capabilities are unavailable.

Settings receives manager-owned state and mutations through closures, following the existing
profile architecture. UI controls never modify Space preferences or perform writes directly.

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
- Run `git diff --check` and focused searches confirming the menu item is absent and the
  Settings Experimental labels and manager gates are present.
- Do not repeat live Space writes, fullscreen conversion, or dock/undock validation as part of
  this release-label change.

## Release and source control

Commit the implementation separately from this design record. Push only
`codex/mission-control-normal-spaces` to `origin`; do not merge, force-push, or modify the clean
main checkout or frozen Claude worktree.
