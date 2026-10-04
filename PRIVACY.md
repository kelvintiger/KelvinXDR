# Privacy Policy

Last updated: 4 October 2026

## The app collects and transmits nothing

KelvinXDR does not collect or transmit any personal data, and what it stores stays on your
Mac. It makes no network requests of its own. Everything it does — reading and writing the
gamma transfer table, talking to monitors over DDC/CI, watching for media keys — happens
locally on your Mac, between the app and your hardware.

There is no account, no sign-in, no server behind this app. Nothing to leak, because
nothing is sent anywhere.

## Your preferences stay on your Mac

Settings (slider positions, shortcuts, the trigger corner, the excluded-app list) are
stored in the standard macOS user defaults database, under the `com.kelvin.KelvinXDR`
domain in your own home directory:

```
~/Library/Preferences/com.kelvin.KelvinXDR.plist
```

They are readable and writable by you, they are not synced anywhere by the app, and they
are removed when you delete that file. The app never uploads them.

## Saved Space layouts stay on your Mac too

Space Layout Protection is experimental and does nothing unless you use it. When you do, it
keeps its layout profiles as JSON files in a second place:

```
~/Library/Application Support/KelvinXDR/SpaceLayouts/
```

A profile describes the windows that were on each desktop when it was saved: the owning
app's name and bundle identifier, the window's title, the document the app reports for it
(usually the path or URL of the open file) where there is one, the window's position and
size, and the process and window numbers macOS had assigned at the time. It also holds the
name and identifier of each display, and the file is named after the display identifiers.
Window titles and document paths can say a lot about what you were working on, so treat
these files accordingly.

Nothing is written there on the app's own initiative. A file is created or changed only when
you save a named layout in Settings, when you confirm **Convert Fullscreen Apps to Dedicated
Desktops** (which records the arrangement it ends with), or when you select, rename or
delete a layout you already saved. Restoring a layout, automatic restoration included, only
reads them.

Like the preferences, these files are never uploaded or synced by the app. To delete them,
remove the folder:

```bash
rm -rf ~/Library/Application\ Support/KelvinXDR
```

## No analytics, no telemetry

There is no analytics SDK, no crash reporter, no usage tracking, no update pinger and no
unique identifier of any kind in the app. Not anonymised, not aggregated, not
"only-if-you-opt-in" — none at all. Crashes are visible to you in Console.app and nowhere
else, unless you choose to report one yourself.

The source is public, so this is checkable rather than something you have to take on
trust.

## The project website uses cookieless analytics

The project website at <https://kelvinct.com/KelvinXDR/> — as distinct from the app — uses
**Cloudflare Web Analytics**, which is cookieless. It sets no cookies, uses no client-side
state, does not fingerprint visitors and does not track anyone across sites or over time.
It reports aggregate page views and referrers only.

This applies to the website only. Installing or running KelvinXDR involves no website and
no analytics.

## GitHub

Downloading the source, filing an issue or opening a pull request happens on GitHub and is
covered by [GitHub's privacy statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement),
not by this one. Anything you post to the repository is public.

## Contact

Questions about this policy: **KelvinXDR@kelvinct.com**, or open an issue at
<https://github.com/kelvintiger/KelvinXDR/issues>.
