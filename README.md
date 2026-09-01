# KelvinXDR

> I was trying to watch Silo on my MacBook Pro and it's so damn dark I made this app.

Brightness control for macOS: XDR/HDR extra brightness on the built-in panel, plus
hardware brightness, contrast and volume for external monitors over DDC/CI.

Built for a MacBook Pro 16" (M1 Pro, Liquid Retina XDR) driving two external displays.

Website: <https://kelvinct.com/KelvinXDR/>

KelvinXDR started as an experiment on top of BrightXDR and outgrew it. It is not a fork or
an extension of any one app anymore. It is a standalone tool that borrows ideas and code
from several excellent projects: MonitorControl for external display control, BrightIntosh
and BrightXDR for the XDR boost technique, and BetterDisplay for the bar it sets on how
small and non-intrusive a display utility should feel. Full credits below.

## Get it running

No Xcode needed, only Apple's free Command Line Tools. If you have never installed those,
run this first and accept the prompt that appears (skip it if you already have them; it
just tells you they are installed):

```bash
xcode-select --install
```

Then paste this, one block, start to finish:

```bash
git clone https://github.com/kelvintiger/KelvinXDR.git
cd KelvinXDR
./build.sh
cp -R build/KelvinXDR.app /Applications/
open /Applications/KelvinXDR.app
```

A circled sun appears in the menu bar. Two optional follow-ups:

- **Media keys.** Click "Enable Media Keys" in the menu and grant Accessibility when macOS
  asks. Without the grant, the brightness and volume keys keep their stock behaviour;
  everything else still works.
- **Rebuilding from source later?** Create the signing identity described under Signing
  first. An ad-hoc build works fine, but macOS revokes the Accessibility grant every time
  the binary changes, so the media keys stop until you re-grant.

## What it does

**Extra brightness on the built-in XDR panel.** One slider, 0-159%. Below 100% it drives the
real backlight. At 100% the backlight pins at maximum and a 1x1 pixel EDR surface puts the
display into HDR mode, so the gamma transfer table can spend the headroom that opens up, to
about 1.59x above normal SDR white. Crossing 100% is what engages XDR; there is no toggle.

Using XDR brightness above 100% consumes more power, generates more heat, and may contribute
to normal backlight aging over time. macOS may automatically limit brightness if the display
gets too warm.

**External monitors over DDC/CI.** Real hardware brightness, contrast, volume and mute, the
same settings the monitor's own buttons change, not a software dim.

**Media keys follow your cursor.** Brightness and volume keys apply to whichever display the
pointer is on. Volume keys drive a monitor's speakers only when that monitor is actually the
audio output; otherwise they drive the device you can hear. Option opens the matching System
Settings pane, Shift inverts the feedback click, and Option+Shift takes quarter steps, the
same as the stock keys.

**A compact HUD, or the stock one.** Level changes show a small indicator on the display they
applied to. It hangs under the notch, the track can be dragged like the iOS volume bar, and
it never eats clicks when there is nothing to drag. Prefer the system bezel? Toggle "Use
System HUD" and the 0-159% scale maps onto extra chiclets past the usual sixteen.

**Global shortcuts.** Assignable hotkeys for brightness up and down, maximum brightness, and
putting the displays to sleep. Recorded in the settings window; no Accessibility permission
needed for these.

**Software dimming below the hardware floor.** Gamma dimming continues past a monitor's own
minimum, down to black. Displays with neither DDC nor a gamma table (AirPlay, Sidecar,
DisplayLink) fall back to a shade overlay.

**The boost follows the backlight.** Gamma above SDR white only means anything while the
panel is at full backlight, so if anything drops the backlight below maximum, the boost
stands down and returns when the backlight does. With auto-brightness on, a dimming room
lowers the backlight and takes the boost with it. Turn auto-brightness off in System
Settings to hold the boost regardless.

**Space Layout Protection (Experimental, Settings only).** Saves Mission Control layouts per
monitor setup. Every Space write is behind a separate opt-in that defaults off; Sequoia,
Tahoe, and macOS 27 write behavior is not production-validated. See below.

**Steps aside on request.** The exclusion list is empty by default: a single corner pixel
cannot cover anything, so there is nothing to step aside from. Name an app in it and the
boost releases while that app is frontmost.

## Why one pixel

The obvious implementation is a full-screen transparent layer with a multiply blend, which
is what this project originally was. It breaks on protected video.

Multiply requires the compositor to read the backdrop. Fullscreen HDR video on Apple TV+ is
decoded into protected memory and scanned out on a dedicated hardware overlay plane, which
the compositor is not permitted to read. The blend cannot be evaluated, so it degrades to
normal compositing, and a white layer at alpha 1.0 becomes an opaque white box over the
video.

A single pixel in a corner cannot cover anything, and gamma is applied at scanout after
compositing, so it brightens protected planes too. Both problems disappear by construction.

## Space Layout Protection (Experimental)

macOS can collapse or reorder Mission Control desktops when displays change. KelvinXDR's
proof of concept protects the ordered row of **normal desktops** by saving a separate profile
for each physical display topology and moving normal windows back to their saved logical
slots. A Space UUID is recorded as a diagnostic hint, but the visible logical position among
type-0 normal Spaces is authoritative.

The feature has no menu-bar item. Open Settings -> **Space Layout Protection — Experimental**.
Saving a named profile does not write Spaces and remains available when its read capabilities
exist. Restore, automatic restoration, desktop creation, and fullscreen conversion remain
disabled until **Enable Experimental Space Writes** is checked. **Automatically Restore
Layouts** is a second opt-in nested under that gate; turning either toggle off cancels pending
topology work immediately. The proof of concept never automatically learns a post-hotplug
arrangement.

Experimental failures are not guaranteed no-ops. A partially completed operation may leave
extra normal desktops, moved or resized normal windows, or an app converted out of native
fullscreen. Verification, retry bounds, and a session circuit breaker limit further writes but
cannot undo a write that already succeeded.

Restoration creates only missing normal desktops, never deletes extras, moves each confidently
matched window to its target type-0 Space, verifies membership, then restores the topology's
saved or display-relative frame. Windows saved as maximized are maximized with normal
`AXPosition` and `AXSize` against the display's visible frame—not native fullscreen.

**Named layouts**

Settings -> **Space Layout Protection — Experimental** lists what is saved, one setup at a
time. Every setup has an
**Auto-saved** history populated by explicit saves and can also hold named photographs such as
"Standard", "Docked", or "Presenting". The layout marked ● is authoritative for that exact
physical setup. All profile reads and mutations are serialized with background layout work.

**Convert native fullscreen apps**

Native fullscreen and tiled Spaces are type 4 and cannot be normal-window move targets.
KelvinXDR never attempts to restore or reproduce their order. Instead,
**Convert Fullscreen Apps to Dedicated Desktops…** is an explicit, confirmed action. It finds
only confidently identified ordinary single-window fullscreen apps, creates every required
normal desktop first, then processes them serially: leave native fullscreen, wait for the
normal AX window, move and verify it on its assigned logical desktop, maximize it with normal
geometry, and verify the frame. Conversion is visible and is never automatic.

Split View, tiled groups, ambiguous or AX-inaccessible windows, Stage Manager special cases,
panels, all-Desktops windows, and unsupported apps are skipped. If a window exits fullscreen
but a later step fails, KelvinXDR does not re-enter fullscreen; it restores a usable normal
frame when possible and reports the manual recovery required.

**What it will not do**

- It does not guess. A window it cannot confidently identify is left exactly where it is —
  ambiguous same-app windows are skipped rather than paired by frame alone.
- It never targets, reorders, recreates, or restores native type-4 fullscreen/tiled Spaces.
- It does not reconstruct Split View or tiled layouts.
- It cannot restore a profile belonging to another physical topology.
- It never deletes a desktop.
- Creating a missing desktop is done by pressing Mission Control's own add button, so
  Mission Control visibly animates in and out.
- With *Displays have separate Spaces* disabled, SkyLight reports one shared `Main` domain.
  Per-display Space restoration is disabled in that mode rather than pretending each
  physical display has its own row.
- Turn off *Automatically rearrange Spaces based on most recent use* (System Settings ->
  Desktop & Dock) or macOS will reshuffle desktops behind this feature's back.

**Requirements and permissions**

The primary development and validation system is macOS Sequoia 15.7.9 with SIP fully enabled.
The transferred prototype recorded a successful bridged normal-Space move there, verified by
moving a disposable window away and back and re-reading `SLSCopySpacesForWindows`. The
corrected implementation later submitted a cross-managed-display move, but membership did not
reach the target within its verification bound. The disposable window remained on its original
Space. KelvinXDR therefore does not claim working Space writes on Sequoia. Other Sequoia 15.7.x
releases are unverified.

Tahoe 26.4+ is an expected forward-compatibility target based on external validation of the
same bridged operation with SIP enabled. KelvinXDR has not tested Tahoe hardware, so it does
not claim "verified on Tahoe." macOS 27 is also untested. Earlier systems retain the existing macOS 13.1 build target,
but Space writes remain unavailable unless every runtime dependency is independently present.
The OS version itself never proves or disproves the operation.

The implementation resolves and reports SkyLight framework loading, connection and inventory
symbols, per-window membership, the bridged move class, `initWithWindows:spaceID:`,
`performWithWMBridgeDelegate`, `_AXUIElementGetWindow`, Accessibility, geometry, and Dock AX
identifiers independently. Every accepted real move is followed by bounded membership
verification. Repeated verification failures open a session circuit that disables further
Space writes while brightness, XDR, DDC, media keys, HUD, and read-only diagnostics remain
available.

**SIP stays fully enabled.** No scripting addition, Dock injection, yabai, or Hammerspoon
installation is used. Accessibility is required for desktop creation, conversion, reliable AX
window identification, and normal-window geometry. Screen Recording is optional at most: if
already granted it can improve CoreGraphics titles, but KelvinXDR never requests it or prompts
for it. The app remains safe without it.

The read-only diagnostic below reports the runtime contract and current inventory. It never
moves a test window automatically:

```bash
/Applications/KelvinXDR.app/Contents/MacOS/KelvinXDR --spaces-dump
```

## Building

No Xcode required; the Command Line Tools are enough.

```bash
./build.sh          # build
./build.sh run      # build and relaunch
./build.sh test     # hardware-free logic checks
```

### App icon

`build.sh` looks for `KelvinXDR/AppIcon.png` and generates the `.icns` from it, masked to
Apple's rounded-square icon grid. Replace it with any square PNG to use your own; without
one, the app falls back to the default icon.

Install with:

```bash
cp -R build/KelvinXDR.app /Applications/
```

### Signing

`build.sh` uses a self-signed identity named `KelvinXDR Signing` if one exists, and falls
back to ad-hoc. This matters: macOS binds an Accessibility grant (needed for the media-key
event tap) to the app's code signature, and an ad-hoc signature is pinned to the exact
binary hash, so every rebuild silently revokes the permission. A stable identity fixes it
permanently:

```bash
openssl req -new -x509 -days 3650 -nodes -newkey rsa:2048 \
  -keyout cs.key -out cs.crt -subj "/CN=KelvinXDR Signing" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
security import cs.key -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
security import cs.crt -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db cs.crt
```

## Settings

Everyday display sliders and toggles live in the menu bar. Shortcut recording, typed
percentages, the EDR trigger corner, the excluded-app list, and all Experimental Space Layout
Protection controls live in the settings window (Cmd+, from the menu).
The same preferences are scriptable:

```bash
defaults write com.kelvin.KelvinXDR ExcludedBundleIDs -array com.apple.TV
defaults write com.kelvin.KelvinXDR TriggerCorner -string bottomRight   # default is topRight
```

## Recovery

Gamma is system-wide state. If the app is killed in a way that skips its handlers and the
screen is left scaled, this restores it; the signal handler hands every display back to
ColorSync:

```bash
killall KelvinXDR
```

## Requirements

Apple Silicon Mac with an XDR display for the brightness boost. DDC control works with any
external monitor that implements it, though docks, HDMI extenders and matrix switchers
often drop the I2C channel, in which case the gamma fallback takes over.

The boost applies to the **built-in** panel only. On a Mac with no built-in display, the
slider is a plain 0-100% control even if an attached external is XDR-capable: the 1x1 EDR
trigger and the gamma path are both written against the internal panel. External displays
still get full DDC brightness, contrast and volume.

Uses private, undocumented APIs (`IOAVService*` for I2C, `DisplayServices` for the native
backlight, `OSDUIHelper` for the optional system bezel, `SkyLight` for Space Layout
Protection). Apple can change these at any time; each one is resolved at runtime, so a
symbol that disappears switches off the feature that needed it rather than the app.

## Credits

KelvinXDR began on top of [BrightXDR](https://github.com/starkdmi/BrightXDR) by Dmitry
Starkov (GPL-3.0) and keeps the GPL-3.0 license from that lineage. Little of the original
remains in the current app, but the license and the debt both stand.

- **[BrightXDR](https://github.com/starkdmi/BrightXDR)** (GPL-3.0): the original EDR
  overlay experiment this project grew out of.
- **[BrightIntosh](https://github.com/niklasr22/BrightIntosh)** (GPL-3.0): the pairing of
  a tiny EDR trigger window with gamma-table brightness, and the reference gamma constants
  for Apple XDR panels.
- **[MonitorControl](https://github.com/MonitorControl/MonitorControl)** (MIT): the Apple
  Silicon DDC/CI implementation in `DDC.swift` is ported from their `Arm64DDC.swift`,
  including the IORegistry traversal and the I2C retry timings. MIT license text below.
- **[SpaceKit](https://github.com/cehbz/spacekit)** (MIT): the narrow adapters in
  `SkyLightSpaces.swift`, `MissionControlDesktopCreator.swift`, and
  `WindowAccessibility.swift` follow theirs — the `SLSCopyManagedDisplaySpaces` dictionary
  shape, invoking `SLSBridgedMoveWindowsToManagedSpaceOperation` through
  `performWithWMBridgeDelegate` instead of parsing the SkyLight Mach-O, and driving Mission
  Control's accessibility tree to add a desktop with SIP enabled. Their
  `macos-spaces-research.md` is the best written record of which of these calls survives
  which macOS release. MIT license text below.
- **[BetterDisplay](https://github.com/waydabber/BetterDisplay)**: no code borrowed, but
  its polish set the bar this app's HUD and menu aim for.

### SpaceKit (MIT)

```
MIT License

Copyright (c) 2026 Charles Haynes

Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

### MonitorControl (MIT)

```
Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

## License

GPL-3.0. See [LICENSE.md](LICENSE.md). The GPL is the licence; [TERMS.md](TERMS.md) only
summarises it and warns about the private-API and gamma caveats, and adds no conditions.

[PRIVACY.md](PRIVACY.md): the app collects nothing and talks to no server.

If you want a maintained app instead of a personal one, use
[BrightIntosh](https://github.com/niklasr22/BrightIntosh) for XDR brightness or
[MonitorControl](https://github.com/MonitorControl/MonitorControl) for display control.
Both are excellent, and this project borrows from both.
