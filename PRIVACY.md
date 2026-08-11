# Privacy Policy

Last updated: 11 August 2026

## The app collects and transmits nothing

KelvinXDR does not collect, store or transmit any personal data. It makes no network
requests of its own. Everything it does — reading and writing the gamma transfer table,
talking to monitors over DDC/CI, watching for media keys — happens locally on your Mac,
between the app and your hardware.

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
