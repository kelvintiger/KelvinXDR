# Security Policy

## Supported versions

There are no tagged releases. The latest commit on `main` is the only supported version —
fixes land there and you rebuild. Older commits get nothing.

| Version | Supported |
| --- | --- |
| `main` (latest commit) | ✅ |
| anything else | ❌ |

## Reporting a vulnerability

**Use [private vulnerability reporting](https://github.com/kelvintiger/KelvinXDR/security/advisories/new).**
It is enabled on this repository: the report stays private until there is a fix, and you
get credit on the advisory if you want it. That is the preferred channel.

If GitHub is not an option, email **KelvinXDR@kelvinct.com**. Please do not open a public
issue for something exploitable.

Useful in a report: what an attacker gains, the macOS and hardware you saw it on, and the
shortest reproduction you have. A patch is welcome but never expected.

## What to expect

This is one person's side project, not a product with a support rota. Best effort, no SLA:
roughly a first reply within a week, and a fix when there is a fix. If a report goes
unanswered for two weeks, assume it was missed rather than ignored — send it again, or
disclose publicly. You are not obliged to sit on a finding indefinitely because I am slow.

## Scope

The app has no server, no account and makes no network requests of its own, so the usual
web surface does not exist here. What is genuinely worth reporting:

- **Accessibility grant abuse.** The media-key event tap runs with a real permission
  attached. Anything that lets other software reach it, or that makes the tap handle
  events it should not, is in scope.
- **Privilege or code execution.** Anything that gets code running through the app, or
  reaches beyond what a user-level app should touch — including via the private APIs
  (`IOAVService*`, `DisplayServices`, `OSDUIHelper`).
- **DDC/I2C writes.** The app writes to monitor firmware. Anything that makes it send
  writes it was not asked to send, or writes that could brick a display, is in scope.
- **Preferences.** `com.kelvin.KelvinXDR` defaults are read at launch. Anything where a
  hostile value there causes worse than a bad setting is in scope.

Out of scope, already documented rather than secret:

- The app uses private, undocumented Apple APIs and can break on any macOS update. That is
  the design, stated in the [README](README.md) and [TERMS.md](TERMS.md).
- Gamma is system-wide state, so a hard kill (`kill -9`) can leave the screen scaled until
  you restore it. See [Recovery](README.md#recovery).
- Requiring an Accessibility grant for the media keys. It is optional, and everything else
  works without it.
- The build's self-signed / ad-hoc code signature. It is a build-from-source project;
  signing is covered in the README.
