# KelvinXDR

macOS menu bar app (LSUIElement). Two jobs: an XDR gamma boost on the built-in panel, and
DDC/native brightness-contrast-volume control for every other display. Derived from
BrightXDR but rewritten; history starts at `bc9ff05`.

`~/Projects/KelvinXDR` → `github.com/kelvintiger/KelvinXDR` is the only repo. When you need
to know what actually shipped, read the pushed tree (`gh api`) rather than reconstructing it
from local artifacts — it is the ground truth and it is one call away.

## Prior session context

The design of the 1×1 EDR trigger, the gamma-boost ceiling, the DDC work, the media-key
event tap, and the app icon were all worked out in one long session whose transcript is at:

```
~/.claude/projects/-Users-kelvin-Projects-BrightXDR--claude-worktrees-brightxdr-hdr-flicker-2e0553/57635e74-dd45-450f-b6ce-6b594c984ec8.jsonl
```

(The path is named for a directory that no longer exists — transcripts live under
`~/.claude`, not in the project folder, so it survived the cleanup.)

It is ~11MB of JSONL, one JSON object per line. Walk it with `python3 -c` over
`json.loads(line)` rather than grepping raw — long regexes over the whole file will hang.
Tool calls are `type: "tool_use"` objects with an `input` field; images (screenshots, icon
previews) are base64 under `type: "image"` → `source.data`, though they are re-encoded and
lossy, so prefer the real file over anything recovered from here.

Transcripts are pruned after 30 days by default (`cleanupPeriodDays` is unset). If any of
this matters past that, copy the file somewhere permanent.

## Working in parallel

Agents work in git worktrees under `.claude/worktrees/` or `.codex/worktrees/`, one branch each,
so several can edit at once without fighting over one index. Check where you are with
`git worktree list`; you are
in a worktree when `git rev-parse --git-dir` and `--git-common-dir` disagree.

**Edit only inside your own worktree.** The main checkout at `~/Projects/KelvinXDR` belongs to
whoever is using it and may hold uncommitted work — a previous session left debug
instrumentation sitting there for days. If something outside your worktree needs to change,
say so and let the human decide.

**Hardware access is exclusive: one agent at a time.** This is the rule that actually bites,
and it is specific to this project. Everything worth verifying runs through global singleton
state:

- the gamma transfer table (system-wide, one per display)
- the I2C bus to each monitor
- `/Applications/KelvinXDR.app` and the running process
- the `com.kelvin.KelvinXDR` defaults domain
- the built-in panel's backlight

Two agents probing simultaneously read each other's writes, and the findings that come out are
artefacts of the collision rather than bugs. Anything that builds, installs, launches, reads
gamma, or touches DDC has to be serialised. Editing code and running `./build.sh test` are
safe in parallel — the test binary touches no hardware at all, which is most of why it exists.

If concurrent hardware work ever becomes genuinely necessary, add a lockfile. Do not try to be
careful about it by hand.

**CI cannot enforce any of this.** A worktree leaves no trace in a commit — the remote sees
branches and nothing else — so a GitHub Action has nothing to inspect. A local `pre-commit`
hook could check the `--git-dir` / `--git-common-dir` difference above, but hooks live in
`.git/hooks`, which is not tracked, and would need `core.hooksPath` pointed at a committed
directory to travel with the repo. None of that reaches the hardware rule, which is a runtime
concern no commit-time check can see. This section is the enforcement mechanism.

## Build / install

```bash
./build.sh          # -> build/KelvinXDR.app
./build.sh run      # build, then relaunch
```

Install to `/Applications` — that is where the Accessibility grant is anchored:

```bash
killall KelvinXDR; rm -rf /Applications/KelvinXDR.app
cp -R build/KelvinXDR.app /Applications/ && open /Applications/KelvinXDR.app
```

`build.sh` signs with the stable self-signed `KelvinXDR Signing` identity when it exists.
An ad-hoc signature is pinned to the exact binary hash, so every rebuild silently revokes
Accessibility and the media keys stop working. If the build prints `signed ad-hoc`, fix the
identity before debugging anything key-related.

`build.sh` also regenerates `Contents/Resources/KelvinXDR.icns` from `KelvinXDR/AppIcon.png`
on every build. The icon in a built bundle is only ever as good as that PNG in the tree you
built from.

## Verifying — headless, no need to ask the user to look

A menu bar app is awkward to inspect from a shell. These all work without a human:

- **Is the media-key event tap live?** `defaults read com.kelvin.KelvinXDR MediaKeysActive`
  — the app writes it at launch and when trust polling succeeds. `1` = `CGEventTap` created.
- **Is HDR engaged and is the boost applied?** Compile a few lines of Swift that read
  `NSScreen.maximumExtendedDynamicRangeColorComponentValue` and
  `CGGetDisplayTransferByTable` for the built-in display. Headroom > 1 proves the 1×1 EDR
  trigger worked; the gamma table's white point equals the boost factor (1.59 = ceiling).
  This is the real proof the feature works — screenshots cannot show it.
- **Which icon actually shipped?** `iconutil -c iconset` against the *installed* bundle's
  `.icns`. Never infer it from the source PNG.
- **What can Space Layout Protection see?**
  `/Applications/KelvinXDR.app/Contents/MacOS/KelvinXDR --spaces-dump` prints the topology
  fingerprint, the private-API capability flags, every display's ordered desktops and every
  AX-readable window's desktop, as JSON. Read-only, never prompts, and exits immediately — so
  it works from a plain shell, unlike anything that has to press a button in Mission Control.
  Operation summaries are mirrored to `SpacesLastResult` in defaults.
- `screencapture` from a Bash tool returns a black frame (no Screen Recording grant), so it
  cannot verify the menu bar or the OSD. Don't waste a call on it.

## Gotchas

- `killall` sends SIGTERM, which kills a Cocoa app before `applicationWillTerminate` runs.
  The SIGTERM/SIGINT handlers in `AppDelegate` restore the gamma tables. Never `kill -9` —
  that leaves the display scaled until logout.
- `didChangeScreenParameters` fires for brightness and colour-profile changes, not just
  hotplug. Invalidating the gamma baseline on every one of them makes the screen visibly
  drop out of XDR and pop back; compare the display set first.
- The gamma boost only has headroom to move into once the display is in EDR mode, which
  lags the trigger window appearing by up to ~100ms.
- Spaces bit twice. Ordering a floating window front *from hidden* while a fullscreen Space
  is active can get it adopted by that Space (it then shows only there); re-asserting
  `collectionBehavior` at that hidden-to-visible edge is the fix, and `OSD.show` does it.
  Re-asserting while the window is already *visible* causes the opposite bug — ejection to
  the desktop Spaces mid-key-repeat — so never re-assert on every show. The HUD's
  `.stationary` is a recorded user choice (visible during Mission Control); `.transient`
  hides it there like the system bezel. The EDR trigger must never become `.transient`:
  hidden during Mission Control means the EDR request lapses while the gamma table is
  still scaled.
- **CoreGraphics reports zero active displays in clamshell; SkyLight does not.** Measured
  here: with the lid shut and no external monitor, `CGGetActiveDisplayList` returns 0 while
  `SLSCopyManagedDisplaySpaces` still lists the display and all its desktops. So a topology
  fingerprint built from CoreGraphics reads `none` on every lid close, and the reading after
  it — the same displays coming back — would look like a hotplug. `TopologyGate` refuses the
  empty topology for exactly this reason; do not "fix" that guard away.
- A Mac on battery with the lid shut is slow enough that `swiftc` can exceed a two-minute
  timeout and `--spaces-dump` can return nothing at all. That is the machine napping, not a
  hang in this code — open the lid and re-run before debugging it.
- SkyLight's `Display Identifier` is **not** `CGDisplayCreateUUIDFromDisplayID`. It is a
  display UUID only while *Displays have separate Spaces* is on; with that off there is one
  shared set of desktops and the identifier is the literal string `Main`. Treat it as an
  opaque key that is only ever compared against another SkyLight reading — the topology
  fingerprint comes from CoreGraphics separately, which is why it keeps working either way.
- Space `type` 0 is a desktop; 4 is fullscreen or tiled. Filter to 0 before counting. A tiled
  Space is present on this Mac right now and counting it would make the display look like it
  already had the desktop a restore was about to build. Type-4 Spaces are also not valid
  targets for the bridged move.
- Within the ordered type-0 list, saved logical position is authoritative. `uuid` is a
  diagnostic hint only: if UUID-bearing normal Spaces survive but reorder, following UUID
  preserves the visible scramble instead of repairing it. Extras remain; never delete Spaces.
- `SLSCopySpacesForWindows` takes a window *list* and returns the union of their Spaces, not a
  per-window mapping. Ask for one window at a time or the answer is meaningless.
- The transferred prototype recorded `SLSBridgedMoveWindowsToManagedSpaceOperation` working
  on Sequoia 15.7.9 (24G830), SIP enabled, on 2026-08-20: a disposable window moved away and
  back, confirmed each way with `SLSCopySpacesForWindows`. Revalidate the corrected adapter on
  this machine before making the final support claim. SpaceKit externally validates Tahoe
  26.4+, but this project has no Tahoe hardware. Never say "verified on Tahoe." The obsolete
  `SLSSpaceSetCompatID` + `SLSSetWindowListWorkspace` path is dead on Sequoia and must not
  return.
- The bridged move needs no Objective-C file. `@objc private protocol` declaring
  `initWithWindows:spaceID:` plus `unsafeBitCast(cls, to: Proto.Type.self)` reaches it from
  Swift, so `build.sh` stays a single `swiftc` call with no `.o` to link. Independently confirm
  the class, `initWithWindows:spaceID:`, and `performWithWMBridgeDelegate` before the cast.
  Submission is still not success: poll one-window membership and accept only a verified move.
- `build.sh test` compiles `SpaceSnapshot.swift` and `SpacePlanner.swift` only.
  `SkyLightSpaces.swift` is deliberately outside the test binary: it is all private API, and a
  mock of SkyLight would only test the mock. Keep new Space logic on the pure side of that
  line if you want it covered.
- Runtime responsibilities stay split: `SkyLightSpaces` owns only symbols/inventory/membership/
  accepted moves; `MissionControlDesktopCreator` owns Dock AX identifiers `mc`, `mc.display`,
  and `mc.spaces.add` and re-reads after every press; `WindowAccessibility` owns
  `_AXUIElementGetWindow`, identity, `AXFullScreen` exit, and `AXPosition`/`AXSize`. The manager
  owns serialization, retries, verification, cancellation, profiles, and summaries.
- **`build.sh`'s icon loop clobbers `$1`.** `set -- $spec` inside the `for spec in ...` loop
  replaces the positional parameters, so every `"${1:-}"` read after it returns `1024`, the
  last icon size. `./build.sh run` had therefore stopped relaunching the app entirely, and
  silently. `CMD="${1:-}"` is captured at the top now; use `$CMD`, never `$1`, below that loop.
- **Install by staging and swapping, never `rm -rf` then `cp`.** The documented sequence
  deletes `/Applications/KelvinXDR.app` and then copies. A copy that fails part-way — a full
  disk did it here — leaves the machine with no app at all, and the one just deleted was the
  working one. `./build.sh install` copies to `/Applications/.KelvinXDR.staging.app` first and
  `mv`s it into place, which is atomic and cannot strand you.
- **Window titles:** `kCGWindowName` needs Screen Recording, while `kAXTitle` and `AXDocument`
  use Accessibility through `_AXUIElementGetWindow`. KelvinXDR never requests Screen Recording;
  if it is already granted, the CG title is an optional quality improvement. A shell probe may
  have a permission the app lacks, so verify real matching evidence from the app's own dump or
  snapshot. Ambiguous same-app windows are skipped.
- **Fullscreen Spaces are `type` 4 and name their occupant.** `TileLayoutManager.TileSpaces` is
  present even for an ordinary, untiled fullscreen app: one entry, with `TileWindowID` (a real
  CGWindowID) and `appName`. `tiles.count > 1` is Split View — record it, never rebuild it.
- **Never restore native fullscreen order.** Leaving fullscreen destroys its type-4 Space and
  re-entering creates another one, perturbing the Mission Control row. The only supported use
  of `AXFullScreen` is the explicit, confirmed conversion action, and it only turns fullscreen
  off. Every required normal desktop is created and verified before that first write. Split
  View/tiled layouts are detected for skip reasons and never reconstructed.
- SkyLight's `Display Identifier` and `CGDisplayCreateUUIDFromDisplayID` return the *same*
  string on this Mac (separate Spaces on), which is what lets a saved display be mapped back to
  a `CGDisplayBounds` for the AX move. Do not assume identity in policy or persistence; store
  the measured mapping. In shared literal-`Main` mode, per-display restoration is unavailable.
- Automatic restoration is separate from manual save/restore/conversion and defaults off. A
  topology notification only re-arms debounce; re-sample physical displays after it fires.
  Disabling the toggle invalidates the token and cancels the pending work immediately. Never
  auto-learn a post-hotplug arrangement in this proof of concept.
- A window can survive its Space being torn down (undock, fullscreen app closing) as a
  zombie: ordered in, alpha animating, drawn nowhere. No in-process check detects this —
  `isVisible` is our own bookkeeping, and `isOnActiveSpace` answers yes for any
  canJoinAllSpaces window (a heal gated on it shipped and failed in the field). The only
  honest detector is the window server's `kCGWindowIsOnscreen` for the window number, and
  the only reliable cure is rebuilding the window. `OSD.scheduleVerify` does both.
