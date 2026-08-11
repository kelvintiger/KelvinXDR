# Terms

Last updated: 11 August 2026

This page explains, in plain language, what you are getting. It is a summary and a set of
warnings — **not** a licence. It adds no conditions of its own.

## The GPL is the licence, and it controls

KelvinXDR is free software licensed under the **GNU General Public License, version 3**
([LICENSE.md](LICENSE.md)). Your rights to use, study, modify, run and redistribute the
software come from that licence and from nothing else on this page.

Nothing here restricts, narrows, qualifies or adds to the GPL-3.0. If anything on this
page appears to conflict with the GPL-3.0, the GPL-3.0 wins and the conflicting sentence
here is void. (GPL-3.0 §7 says as much: you may remove any further restriction imposed on
material covered by the licence.)

Portions of the DDC/CI code are ported from MonitorControl and are additionally under the
MIT licence; see the Credits section of the [README](README.md).

## No warranty

The software is provided **as is, without warranty of any kind**, express or implied,
including but not limited to the implied warranties of merchantability and fitness for a
particular purpose. The entire risk as to the quality and performance of the software is
with you. To the extent permitted by applicable law, no copyright holder or contributor is
liable for any damages arising from the use or inability to use the software.

That is not extra small print — it is sections 15 and 16 of the GPL-3.0, restated here so
it is not a surprise.

## It uses undocumented Apple APIs and can break

KelvinXDR does things macOS does not offer a public API for. It calls private,
undocumented frameworks (`IOAVService*` for I2C over the display link, `DisplayServices`
for the native backlight, `OSDUIHelper` for the optional system bezel) and it writes the
system-wide gamma transfer table.

Practical consequences, stated plainly:

- **A macOS update can break it at any time**, partly or completely, with no warning and
  no obligation on anyone to fix it. Private APIs carry no compatibility promise.
- Gamma is **system-wide state**. If the app exits without its handlers running, the
  screen can stay scaled until you restore it. The [Recovery](README.md#recovery) section
  of the README explains how; `killall KelvinXDR` is the short answer, and never `kill -9`.
- DDC/CI writes go to your monitor's own firmware. Most monitors handle this fine; some
  behave oddly, and docks, HDMI extenders and matrix switchers often drop the I2C channel
  entirely.
- Running it requires an Accessibility grant for the media-key features. That is a real
  permission; grant it only if you are comfortable doing so.

Use it if that trade sounds fine to you. It is a personal tool published in the hope it is
useful, not a supported product. If you want something maintained, the README points at
BrightIntosh and MonitorControl.

## Not affiliated with Apple

This project is an independent work. It is **not** affiliated with, authorised by,
endorsed by, sponsored by or in any way officially connected to Apple Inc. Apple, macOS,
Mac, MacBook Pro, XDR and Liquid Retina are trademarks of Apple Inc., used here only to
describe what the software works with — nominative use, no claim of ownership implied.

## Contact

**KelvinXDR@kelvinct.com**, or <https://github.com/kelvintiger/KelvinXDR/issues>.
