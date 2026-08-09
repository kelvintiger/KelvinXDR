//
//  Tests/main.swift
//  KelvinXDR
//
//  The pure logic, checked without hardware. Everything interesting in this app needs an XDR
//  panel, an I2C bus or an Accessibility grant, none of which exist on a CI runner — so this
//  covers only what is genuinely a function of its inputs. That is still the code that has
//  churned most and where the real bugs have been: a rounding rule that skipped a detent
//  going down, and a name comparison that could never match.
//
//  No framework, no fixtures. `./build.sh test`, or `swiftc Tests/main.swift <sources>`.
//

import Foundation

var failures = 0
var checks = 0

func expect(_ ok: Bool, _ description: String) {
    checks += 1
    if !ok { failures += 1 }
    print("  \(ok ? "pass" : "FAIL")  \(description)")
}

func section(_ title: String) { print("\n\(title)") }

// MARK: - Detent

func pct(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }

func step(_ from: Float, _ up: Bool, ceiling: Float = 1.59, fine: Bool = false,
          expected: Float, _ why: String) {
    let got = Detent.next(from: from, up: up, ceiling: ceiling, fine: fine)
    expect(abs(got - expected) < 0.002,
           "\(pct(from)) \(up ? "up" : "down")\(fine ? " ⌥⇧" : "") -> \(pct(got)) "
           + "(expected \(pct(expected))) — \(why)")
}

section("Detent — Apple's 1/16 below 100%")
step(0.0000, true,  expected: 0.0625, "notch 0 to 1")
step(0.0625, true,  expected: 0.1250, "notch 1 to 2")
step(0.5000, true,  expected: 0.5625, "notch 8 to 9")
step(0.9375, true,  expected: 1.0000, "notch 15 lands exactly on 100%")
step(1.0000, false, expected: 0.9375, "back down off 100%")
step(0.0625, false, expected: 0.0000, "down to the floor")
step(0.0000, false, expected: 0.0000, "already at the floor")

section("Detent — geometric above 100%, x1.1725 per notch")
step(1.0000, true,  expected: 1.1725, "first XDR notch")
step(1.1725, true,  expected: 1.3748, "second XDR notch")
step(1.3748, true,  expected: 1.5900, "third clamps to the 159% ceiling")
step(1.5900, true,  expected: 1.5900, "at the ceiling, stays")
step(1.5900, false, expected: 1.3748, "down off the ceiling")
step(1.1725, false, expected: 1.0000, "returns to exactly 100%")

section("Detent — Option+Shift quarter notches")
step(0.0000, true,  fine: true, expected: 0.015625, "1/64, matching macOS")
step(0.5000, true,  fine: true, expected: 0.515625, "1/64 mid-scale")
step(1.0000, false, fine: true, expected: 0.984375, "fine step below 100%")
step(1.0000, true,  fine: true, expected: 1.0407,   "fine step into XDR")
step(1.5900, false, fine: true, expected: 1.5490,   "fine step down off the ceiling")

section("Detent — external displays cap at 100%")
step(0.9375, true, ceiling: 1.0, expected: 1.0, "reaches maximum")
step(1.0000, true, ceiling: 1.0, expected: 1.0, "clamped — no XDR on externals")

section("Detent — off-grid positions snap, symmetrically")
// 37% sits between notch 5 (31.25%) and notch 6 (37.5%), so those are its neighbours.
// Regression: rounding to nearest went to the *nearer* grid point first and then stepped,
// which moved up one rung but skipped one going back down.
step(0.37, true,  expected: 0.375,  "up to the next grid point above")
step(0.37, false, expected: 0.3125, "down to the next grid point below, not past it")

section("Detent — a press always moves")
// Regression: 1.55/0.05 is 30.99999 in Float; a bare floor() returned the input unchanged.
for start in stride(from: Float(0), through: Float(1.55), by: 0.05) {
    let up = Detent.next(from: start, up: true, ceiling: 1.59, fine: false)
    expect(up > start, "\(pct(start)) up moves somewhere (-> \(pct(up)))")
}

section("Detent — up then down returns to the start")
for start in [Float(0.0), 0.0625, 0.5, 0.9375, 1.0, 1.1725, 1.3748] {
    let there = Detent.next(from: start, up: true, ceiling: 1.59, fine: false)
    let back = Detent.next(from: there, up: false, ceiling: 1.59, fine: false)
    expect(abs(back - start) < 0.002, "\(pct(start)) -> \(pct(there)) -> \(pct(back))")
}

// MARK: - AudioOutput

func matches(_ display: String, _ output: String?, _ expected: Bool, _ why: String) {
    let got = AudioOutput.matches(displayName: display, output: output)
    expect(got == expected,
           "\"\(display)\" vs \(output.map { "\"\($0)\"" } ?? "nil") -> \(got) — \(why)")
}

section("AudioOutput — does this display own the audio?")
// NSScreen appends " (1)"/" (2)" to identical displays; CoreAudio reports the plain model
// name, so comparing them raw could never match.
matches("LG Ultra HD (1)", "LG Ultra HD", true, "NSScreen suffix stripped")
matches("LG Ultra HD (2)", "LG Ultra HD", true, "the second identical panel")
matches("LG Ultra HD", "LG Ultra HD", true, "no suffix to strip")
matches("LG Ultra HD (10)", "LG Ultra HD", true, "multi-digit suffix")
matches("Studio (Display) (1)", "Studio (Display)", true, "parens in the real name survive")
matches("LG Ultra HD (1)", "MacBook Pro Speakers", false, "audio is on the Mac — pass through")
matches("Built-in Retina Display", "MacBook Pro Speakers", false, "panel name is not the speaker name")
matches("LG Ultra HD (1)", nil, false, "no output device readable")
matches("LG Ultra HD", "LG", false, "must not match on prefix alone")

// MARK: -

print("\n\(checks - failures)/\(checks) passed")
if failures > 0 { print("\(failures) FAILED") }
exit(failures == 0 ? 0 : 1)
