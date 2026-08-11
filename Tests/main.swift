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

import Carbon.HIToolbox
import Cocoa
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

// MARK: - Shortcut

// NSEvent's modifier flags and Carbon's use different bit layouts. Getting this wrong
// registers a hotkey the user can never actually type, and nothing reports an error.
section("Shortcut — NSEvent flags translate to Carbon's")
expect(Shortcut.carbonModifiers(from: []) == 0, "no modifiers -> 0")
expect(Shortcut.carbonModifiers(from: [.command]) == UInt32(cmdKey), "command")
expect(Shortcut.carbonModifiers(from: [.option]) == UInt32(optionKey), "option")
expect(Shortcut.carbonModifiers(from: [.shift]) == UInt32(shiftKey), "shift")
expect(Shortcut.carbonModifiers(from: [.control]) == UInt32(controlKey), "control")
expect(Shortcut.carbonModifiers(from: [.command, .shift])
       == UInt32(cmdKey) | UInt32(shiftKey), "command+shift combines")
expect(Shortcut.carbonModifiers(from: [.command, .option, .shift, .control])
       == UInt32(cmdKey) | UInt32(optionKey) | UInt32(shiftKey) | UInt32(controlKey),
       "all four combine")
// Flags we never bind must not leak into the mask, or registration fails silently.
expect(Shortcut.carbonModifiers(from: [.capsLock, .function]) == 0,
       "capsLock and fn are ignored")
expect(Shortcut.carbonModifiers(from: [.command, .capsLock]) == UInt32(cmdKey),
       "capsLock alongside command is dropped")

section("Shortcut — display string")
// F-keys resolve from the name table, so this needs no keyboard layout.
expect(Shortcut(keyCode: UInt32(kVK_F1), modifiers: UInt32(cmdKey)).displayString == "⌘F1",
       "command + F1")
expect(Shortcut(keyCode: UInt32(kVK_F1),
                modifiers: UInt32(cmdKey) | UInt32(optionKey)).displayString == "⌥⌘F1",
       "modifiers render in Apple's order, not the order they were set")
expect(Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey)).displayString == "⌃Space",
       "control + Space")

section("ShortcutAction — stable identity")
// The raw values are persisted, and the case order indexes Carbon hot key IDs.
expect(ShortcutAction.allCases.count == 4, "four actions")
expect(ShortcutAction.allCases.map { $0.rawValue }
       == ["brightnessUp", "brightnessDown", "maximumBrightness", "displayOff"],
       "raw values and order are unchanged (persisted keys and hot key IDs depend on both)")

// MARK: - GammaBoost

// Primarily a deadlock canary. The public entry points all take one non-recursive NSLock, and
// `invalidate` has to call the *unlocked* internal restore or it deadlocks against itself — a
// mistake that hangs rather than crashes, so it would never show up as a failing assertion.
// If this section stops printing, that is the bug.
//
// Display 0 is not a real display: CoreGraphics no-ops on it, so the state machine and the
// locking get exercised without touching a panel.
section("GammaBoost — every call order completes, none deadlock")
GammaBoost.apply(factor: 1.59, to: 0)
GammaBoost.restore(0)
GammaBoost.invalidate()
GammaBoost.apply(factor: 1.2, to: 0)
GammaBoost.restoreAll()
expect(true, "apply / restore / invalidate / restoreAll in sequence")

GammaBoost.prepareForTermination()
GammaBoost.apply(factor: 1.59, to: 0)   // must be refused, and must not trap
GammaBoost.invalidate()
expect(true, "apply after prepareForTermination is refused without trapping")

// MARK: - Settings layout

// NSTextField(labelWithString:) is single-line: its intrinsic width is the whole string, so
// one long sentence silently widened the window until the text clipped against the frame.
// Caught by eye, not by a test, which is why this exists. Pure AppKit — no hardware.
section("Settings — the window fits its content")
_ = NSApplication.shared
NSApplication.shared.setActivationPolicy(.accessory)

let settings = SettingsWindowController()
// Populate the levels grid before measuring, including a display name far longer than
// anything real — an unconstrained label there would widen the window exactly the way the
// wrapping paragraphs once did.
settings.values = {
    [.init(title: "Built-in Retina Display — Brightness", fraction: 1.0, maxFraction: 1.59) { _ in },
     .init(title: "LG Ultra HD (1) — Brightness", fraction: 0.5, maxFraction: 1) { _ in },
     .init(title: "LG Ultra HD (1) — Contrast", fraction: 0.75, maxFraction: 1) { _ in },
     .init(title: String(repeating: "Absurdly Long Display Name ", count: 6) + "— Volume",
           fraction: 0.3, maxFraction: 1) { _ in }]
}
settings.reload()
if let content = settings.window?.contentView {
    content.layoutSubtreeIfNeeded()
    settings.window?.setContentSize(content.fittingSize)
}
if let content = settings.window?.contentView {
    content.layoutSubtreeIfNeeded()
    let fitting = content.fittingSize
    let expected = SettingsWindowController.contentWidth + 40   // 20pt inset each side

    expect(abs(fitting.width - expected) < 1,
           "content is \(Int(expected))pt wide, not stretched by a long label "
           + "(got \(Int(fitting.width)))")

    var overflowing: [String] = []
    func walk(_ view: NSView) {
        for sub in view.subviews {
            let frame = view.convert(sub.frame, to: content)
            if frame.maxX > fitting.width + 0.5 || frame.minX < -0.5 {
                overflowing.append((sub as? NSTextField).map { String($0.stringValue.prefix(40)) }
                                   ?? "\(type(of: sub))")
            }
            walk(sub)
        }
    }
    walk(content)
    expect(overflowing.isEmpty,
           "nothing extends past the content bounds"
           + (overflowing.isEmpty ? "" : " — \(overflowing.joined(separator: "; "))"))

    // A clipped wrapping label is exactly one line tall; a wrapped one is taller.
    let wrapping = content.subviews.compactMap { $0 as? NSTextField }
        .filter { $0.maximumNumberOfLines == 0 }
    expect(!wrapping.isEmpty, "found the wrapping labels")
    for field in wrapping {
        let needed = field.cell?.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: field.frame.width, height: .greatestFiniteMagnitude)).height ?? 0
        expect(field.frame.height >= needed - 0.5,
               "\"\(field.stringValue.prefix(30))…\" is \(Int(field.frame.height))pt, "
               + "needs \(Int(needed))pt")
    }

    expect((settings.window?.frame.height ?? 0) >= fitting.height,
           "window is tall enough for its content, so the buttons are not cut off")

    // The popup's titles and the stored corner values are parallel lists. Reordering the
    // titles without the values would silently park the EDR trigger in the wrong corner, and
    // nothing would report an error — the pixel would just show up somewhere visible.
    func findPopup(_ view: NSView) -> NSPopUpButton? {
        if let popup = view as? NSPopUpButton { return popup }
        for sub in view.subviews { if let popup = findPopup(sub) { return popup } }
        return nil
    }
    expect(SettingsWindowController.corners.first == "topRight",
           "top right is the default, so an unset pref lands on popup index 0")
    if let popup = findPopup(content) {
        expect(popup.numberOfItems == SettingsWindowController.corners.count,
               "one title per stored value")
        for (index, value) in SettingsWindowController.corners.enumerated()
        where index < popup.numberOfItems {
            let title = popup.item(at: index)?.title ?? ""
            expect(title.lowercased().replacingOccurrences(of: " ", with: "") == value.lowercased(),
                   "popup item \(index) \"\(title)\" stores \"\(value)\"")
        }
    } else {
        expect(false, "found the trigger-corner popup")
    }
} else {
    expect(false, "settings window has a content view")
}

// MARK: - Media key modifiers

// Apple's table. A swallowed key never reaches macOS, so anything not reproduced here is lost
// — which is exactly what happened to Option, where we stepped the value instead of opening
// System Settings.
section("MediaKeys — what each modifier means")
expect(MediaKeys.adjustment(for: []) == .coarse, "no modifier -> 1/16 step")
expect(MediaKeys.adjustment(for: [.option, .shift]) == .fine, "⌥⇧ -> 1/64 quarter step")
expect(MediaKeys.adjustment(for: [.option]) == .openSettings, "⌥ alone -> System Settings")
expect(MediaKeys.adjustment(for: [.shift]) == .coarseInvertedFeedback,
       "⇧ alone -> 1/16 step, feedback sound inverted")
// Order must not matter, and the two-modifier case must not be read as either single one.
expect(MediaKeys.adjustment(for: [.shift, .option]) == .fine, "⇧⌥ is the same as ⌥⇧")
// Modifiers macOS ignores for these keys must not change the meaning.
expect(MediaKeys.adjustment(for: [.command]) == .coarse, "⌘ is not special -> plain step")
expect(MediaKeys.adjustment(for: [.control, .shift]) == .coarseInvertedFeedback,
       "⌃ alongside ⇧ still inverts the click")
expect(MediaKeys.adjustment(for: [.command, .option]) == .openSettings,
       "⌘⌥ still opens settings — ⌥ is what counts")
expect(MediaKeys.adjustment(for: [.capsLock]) == .coarse, "capsLock is not a modifier here")

// MARK: - Typed percentages

// Clamping rather than rejecting is the point: typing 500 into a control that stops at 159
// means "as high as it goes", and refusing it would only make you guess the ceiling.
section("Percent — typing a percentage")
func parses(_ text: String, max: Double, _ expected: Double?, _ why: String) {
    let got = Percent.parse(text, max: max)
    let ok: Bool
    switch (got, expected) {
    case let (value?, want?): ok = abs(value - want) < 0.0001
    case (nil, nil):          ok = true
    default:                  ok = false
    }
    expect(ok, "\"\(text)\" max \(max) -> \(got.map { "\($0)" } ?? "nil") — \(why)")
}
parses("50", max: 1, 0.5, "half")
parses("100", max: 1, 1.0, "the top of an ordinary control")
parses("0", max: 1, 0.0, "zero is a value, not an empty entry")
parses("101", max: 1, 1.0, "above the maximum clamps rather than being rejected")
parses("500", max: 1, 1.0, "far above still clamps")
parses("159", max: 1.59, 1.59, "the XDR ceiling is reachable by typing")
parses("200", max: 1.59, 1.59, "clamps to the XDR ceiling, not to 100%")
parses("120", max: 1.59, 1.20, "a value only the built-in panel can hold")
parses("", max: 1, nil, "nothing typed -> no change")
parses("abc", max: 1, nil, "no digits -> no change")
parses("7%", max: 1, 0.07, "a stray percent sign is ignored")
// Regression: digit-filtering turned "12.5" into "125" — a dim request became a 125% boost.
parses("12.5", max: 1.59, 0.125, "a decimal is a decimal, not ten times the value")
parses("50.5", max: 1, 0.505, "decimal on an ordinary control")
parses("0.5", max: 1, 0.005, "sub-1% stays sub-1%")
parses("12,5", max: 1, 0.125, "comma decimal separator accepted")
parses(".", max: 1, nil, "a lone dot is not a number")

// MARK: - DDC reply validation

// A checksum-valid reply can still be the wrong one. Result code 0x01 means "unsupported
// VCP" and arrives zero-filled — parsed blindly, that put a volume row on speakerless
// monitors and quantised brightness to a max of 1. The opcode echo catches a reply consumed
// off the bus for a different request (reads and writes run on different threads).
section("DDC — Get-VCP-Feature replies are validated, not just checksummed")
func vcpReply(result: UInt8 = 0, opcode: UInt8, maxHi: UInt8 = 0, maxLo: UInt8 = 100,
              curHi: UInt8 = 0, curLo: UInt8 = 70) -> [UInt8] {
    [0x6E, 0x88, 0x02, result, opcode, 0x00, maxHi, maxLo, curHi, curLo, 0x00]
}
expect(DDC.parseReply(vcpReply(opcode: 0x10), command: 0x10)! == (70, 100),
       "a well-formed brightness reply parses to current 70, max 100")
expect(DDC.parseReply(vcpReply(result: 1, opcode: 0x10), command: 0x10) == nil,
       "non-zero result code (unsupported VCP) is rejected")
expect(DDC.parseReply(vcpReply(opcode: 0x12), command: 0x10) == nil,
       "a contrast reply cannot satisfy a brightness request")
expect(DDC.parseReply(vcpReply(opcode: 0x62, maxLo: 0), command: 0x62) == nil,
       "max == 0 is never a usable scale")
expect(DDC.parseReply(Array(vcpReply(opcode: 0x10).prefix(10)), command: 0x10) == nil,
       "a short reply is rejected")
expect(DDC.parseReply(vcpReply(opcode: 0x10, maxHi: 1, maxLo: 0, curHi: 0, curLo: 255),
                      command: 0x10)! == (255, 256),
       "16-bit fields assemble high byte first")

// MARK: - System bezel chiclets

// The system HUD draws a fixed strip, so the unified 0...159% scale has to map onto it. Keeping
// Apple's 1/16 notch and running the strip longer means the chiclets past the 16th *are* the
// XDR range, rather than the whole thing being rescaled and 100% landing somewhere arbitrary.
section("System HUD — chiclets for the 0...159% scale")
expect(Int(Detent.notch(1.0).rounded()) == 16, "100% is Apple's 16th chiclet")
expect(Int(Detent.notch(1.59).rounded()) == 19, "159% needs 19, so the strip runs 3 past the top")
expect(Int(Detent.notch(0.5).rounded()) == 8, "50% is half the backlight strip")
expect(Detent.notch(1.2) > 16 && Detent.notch(1.2) < 19, "120% sits inside the XDR chiclets")

// MARK: - Compact HUD layout

// screencapture returns a black frame without a Screen Recording grant, so the HUD cannot be
// checked by eye from a shell. Its geometry can be, which covers the two things most likely to
// be silently wrong: where it sits, and whether it is eating clicks meant for the app beneath.
section("OSD — the compact HUD")
// A CI runner's window server may omit the on-screen key even for windows it is drawing,
// and a spurious zombie-rebuild mid-test would swap the window out from under the
// assertions below. The verify path needs a real zombie to test, which no harness can make.
OSD.verificationEnabled = false
if let screen = NSScreen.main {
    func findTrack(_ view: NSView) -> OSDTrack? {
        if let track = view as? OSDTrack { return track }
        for sub in view.subviews { if let track = findTrack(sub) { return track } }
        return nil
    }

    let hud = OSD()
    hud.show(on: screen, symbol: "sun.max.fill", value: 0.5, mark: 1.0 / 1.59,
             onScrub: { _ in })

    if let window = NSApp.windows.first(where: { $0.level == .screenSaver }),
       let content = window.contentView, let track = findTrack(content) {

        let menuBar = screen.frame.height - (screen.visibleFrame.maxY - screen.frame.minY)
        let gap = screen.frame.maxY - max(menuBar, 24) - window.frame.maxY
        expect(gap >= 0 && gap <= 8,
               "hangs just under the menu bar — \(Int(gap))pt below it, so it reads as sitting "
               + "beneath the notch")
        expect(abs(window.frame.midX - screen.frame.midX) < 1, "horizontally centred")

        // A 6pt-tall bar is not a drag target; the hit area has to be finger-sized.
        expect(track.frame.height >= 20,
               "the draggable area is \(Int(track.frame.height))pt tall, not the 6pt of the bar")
        expect(window.ignoresMouseEvents == false, "accepts the mouse while it has a scrub handler")

        if let bar = track.subviews.first, let fill = bar.subviews.first {
            expect(abs(fill.frame.width - track.frame.width * 0.5) < 1,
                   "50% fills half the track")
            hud.update(value: 0.25)
            expect(abs(fill.frame.width - track.frame.width * 0.25) < 1,
                   "dragging to 25% moves the fill without redrawing the HUD")
        } else {
            expect(false, "found the bar and its fill")
        }

        // Anything with no level to drag must go back to being click-through: the HUD sits at
        // .screenSaver level, so every event it accepts is one the app underneath never sees.
        hud.show(on: screen, symbol: "speaker.slash.fill", value: nil, mark: nil, onScrub: nil)
        expect(window.ignoresMouseEvents == true,
               "no scrub handler -> click-through, so it cannot steal a click from beneath")

        // Regression: the auto-hide is queued when the HUD appears, and starting a drag set a
        // flag without cancelling it — so the HUD vanished from under the pointer 1.1s after
        // it opened, no matter how long you were still holding the bar. Real bug, hit by hand.
        // The waits are what make this meaningful, so it costs a few seconds.
        hud.show(on: screen, symbol: "sun.max.fill", value: 0.5, mark: nil, onScrub: { _ in })
        track.onDragChanged?(true)
        RunLoop.current.run(until: Date().addingTimeInterval(1.6))
        expect(window.isVisible && window.alphaValue > 0.99,
               "still on screen 1.6s into a drag, well past the 1.1s auto-hide")

        track.onDragChanged?(false)
        expect(window.isVisible, "still up the instant the mouse comes up")
        RunLoop.current.run(until: Date().addingTimeInterval(1.8))
        expect(!window.isVisible, "hides once the drag ends and the clock restarts")

        // Regression: the hide's work item fires at 1.1s and starts a 0.35s fade; cancel()
        // on it after that is a no-op, and the fade's completion ordered the window out
        // unconditionally. A show() landing inside that fade window flashed half-faded and
        // vanished ~0.2s later, staying hidden for its whole display window. Probed live:
        // re-show at 1.29s read alpha 0.48 and the window was gone by 1.38s.
        hud.show(on: screen, symbol: "sun.max.fill", value: 0.5, mark: nil, onScrub: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(1.18))   // mid-fade: window is 1.1-1.45, and a loaded CI VM only ever lands LATER than asked
        hud.show(on: screen, symbol: "sun.max.fill", value: 0.6, mark: nil, onScrub: nil)
        expect(window.alphaValue > 0.99, "re-show mid-fade snaps alpha back to 1")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        expect(window.isVisible && window.alphaValue > 0.99,
               "still on screen 0.6s after a mid-fade re-show — the stale fade did not hide it")
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        expect(!window.isVisible, "and the re-show's own hide still fires afterwards")

        // Same root cause, drag flavour: a grab during the fade must stop the fade itself,
        // not just the (already-fired) work item — and survive until the mouse comes up.
        hud.show(on: screen, symbol: "sun.max.fill", value: 0.5, mark: nil, onScrub: { _ in })
        RunLoop.current.run(until: Date().addingTimeInterval(1.18))   // mid-fade: window is 1.1-1.45, and a loaded CI VM only ever lands LATER than asked
        track.onDragChanged?(true)
        expect(window.alphaValue > 0.99, "a grab mid-fade snaps alpha back to 1")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        expect(window.isVisible && window.alphaValue > 0.99,
               "held open by the drag, well past where the stale fade would have hidden it")
        expect(track.onScrub != nil, "the scrub handler survived the stale fade's cleanup")
        track.onDragChanged?(false)
        RunLoop.current.run(until: Date().addingTimeInterval(1.8))
        expect(!window.isVisible, "hides after the mid-fade drag ends")
    } else {
        expect(false, "found the HUD window and its track")
    }
} else {
    print("  skip  no display attached (CI) — HUD geometry needs a real screen")
}

// MARK: -

print("\n\(checks - failures)/\(checks) passed")
if failures > 0 { print("\(failures) FAILED") }
exit(failures == 0 ? 0 : 1)
