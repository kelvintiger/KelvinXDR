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

Agents work in git worktrees under `.claude/worktrees/`, one branch each, so several can edit
at once without fighting over one index. Check where you are with `git worktree list`; you are
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
