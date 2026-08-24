# Third-party notices

KelvinXDR is GPLv3 (see `LICENSE.md`). This file records work by others that Space Layout
Protection is derived from.

## SpaceKit — MIT

<https://github.com/cehbz/spacekit>

SpaceKit is the reference implementation for every undocumented macOS behaviour Space Layout
Protection depends on. No SpaceKit source is compiled into KelvinXDR — it is Go, KelvinXDR is
Swift — but the following were translated closely enough that its licence travels with them:

- The shape of `SLSCopyManagedDisplaySpaces`' reply: per-display `Display Identifier`,
  `Current Space`, and `Spaces[]` carrying `ManagedSpaceID` / `id64` / `uuid` / `type`, with
  type 0 meaning a desktop and type 4 a fullscreen or tiled Space
  (`internal/skylight/skylight.go` -> `KelvinXDR/SkyLightSpaces.swift`).
- Invoking `SLSBridgedMoveWindowsToManagedSpaceOperation` through its own
  `performWithWMBridgeDelegate` selector, after confirming the class responds to it, rather
  than yabai's approach of parsing the SkyLight Mach-O for a non-exported function
  (`internal/skylight/move.m` -> `SkyLightSpaces.submitMove(_:toNormalSpace:)`).
- Creating a desktop by driving Mission Control's accessibility tree — Dock -> `mc` ->
  `mc.display` rows -> the `mc.spaces.add` button, re-walked between presses because the tree
  reflows (`internal/skylight/spacecreate.m` -> `MissionControlDesktopCreator.create(_:)`).
- Reading window titles through `kAXTitle` with `_AXUIElementGetWindow`, so that titles are
  available without the Screen Recording permission `kCGWindowName` requires
  (`internal/skylight/ax.m` -> `WindowAccessibility.windows()`).
- Toggling `AXFullScreen` for an explicitly selected window
  (`skylight.SetFullscreen` -> `WindowAccessibility.exitFullscreen(pid:windowID:)`). KelvinXDR
  only turns it off during confirmed conversion and never re-enters fullscreen.
- Matching windows within an app rather than across apps (`internal/layout/layout.go` ->
  `KelvinXDR/SpacePlanner.swift`). SpaceKit's UUID-first Space resolution was studied but is
  intentionally not retained: KelvinXDR uses logical type-0 position first to restore the
  visible Mission Control row.

Its research notes (`macos-spaces-research.md`) are also the source for the version history of
the write-side APIs and for the fact that the bridged move is user-Space to user-Space only.

Not taken from SpaceKit: physical-topology identity, the normal-window schema and history,
logical-slot-first restoration, conservative matching and ambiguity refusal, display-relative
geometry, conversion eligibility and ordering, bounded verification, session circuit breaking,
or automatic-restore cancellation. KelvinXDR does not reproduce native fullscreen order.

```
MIT License

Copyright (c) 2026 Charles Haynes

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## restore-spaces — GPLv3

<https://github.com/tplobo/restore-spaces>

Studied for behavioural ideas only — per-monitor saved environments, resolving Spaces whose IDs
have changed, and title-similarity window matching. No code was taken, and none of its
Hammerspoon architecture was carried over; its move mechanism (`hs.spaces.moveWindowToSpace`)
has been non-functional since macOS 15. Listed here because it was read.

## CGSInternal

<https://github.com/NUIKit/CGSInternal>

The mask value `0x7` passed to `SLSCopySpacesForWindows` (current | other | user-created) comes
from its `CGSSpace.h`. A single constant, reproduced as a comment at the call site.
