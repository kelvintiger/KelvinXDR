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

Sliders and toggles live in the menu bar. Shortcut recording, typed percentages, the EDR
trigger corner and the excluded-app list live in the settings window (Cmd+, from the menu).
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
backlight, `OSDUIHelper` for the optional system bezel). Apple can change these at any
time.

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
- **[BetterDisplay](https://github.com/waydabber/BetterDisplay)**: no code borrowed, but
  its polish set the bar this app's HUD and menu aim for.

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
