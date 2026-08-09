//
//  Detent.swift
//  KelvinXDR
//
//  Where a key press lands on the built-in panel's 0...159% scale.
//
//  Measured on this panel, macOS's own brightness scale is piecewise-geometric in emitted
//  light, with a knee exactly at notch 8: each notch below 50% multiplies light by 1.662, each
//  notch above by 1.1725, to four decimals every time. That curve lives *inside*
//  DisplayServices — the 0...1 value we hand it is already the perceptual coordinate — so
//  below 100% the correct thing is a plain 1/16 step and no curve of our own. Adding one would
//  double-apply it and make this the only brightness control on the machine that feels wrong.
//
//  Above 100% there is no Apple curve to inherit: gamma scaling is linear in light. A flat
//  1/16 step there would be +6.25% light against the +17.25% of the backlight notch you just
//  came off, so crossing 100% would feel like hitting molasses. Continuing Apple's own upper
//  ratio instead makes 50%...159% one uninterrupted geometric progression.
//

import Foundation

enum Detent {
    /// Apple's scale: 16 notches from off to full backlight.
    static let notchesToMax: Float = 16

    /// Light multiplier per notch above 50%, measured via DisplayServicesGetLinearBrightness.
    static let xdrRatio: Float = 1.1725

    /// Slider value -> notch coordinate. The two branches agree at 1.0 (both give 16), so the
    /// 100% boundary is continuous and needs no special case in `next`.
    static func notch(_ level: Float) -> Float {
        level < 1.0 ? level * notchesToMax
                    : notchesToMax + log(level) / log(xdrRatio)
    }

    static func level(_ notch: Float) -> Float {
        notch <= notchesToMax ? notch / notchesToMax
                              : pow(xdrRatio, notch - notchesToMax)
    }

    /// The next detent from `current`, clamped to `ceiling`.
    ///
    /// Strictly the next grid point in the direction of travel: floor going up, ceil coming
    /// down. Rounding to nearest looks equivalent but is not — from an off-grid position it
    /// steps forward correctly and skips a detent going back.
    ///
    /// - fine: quarter notches, for Option+Shift. Below 100% that is exactly the 1/64 macOS
    ///   uses; above it, a 1.0407 light ratio.
    static func next(from current: Float, up: Bool, ceiling: Float, fine: Bool) -> Float {
        // A grid point computed back through log/pow rarely lands exactly on the integer it
        // came from, and a bare floor() would then hand back the value we started on — the
        // press would do nothing.
        let epsilon: Float = 1e-4
        let grid: Float = fine ? 0.25 : 1
        let position = notch(current) / grid
        let target = up ? (position + epsilon).rounded(.down) + 1
                        : (position - epsilon).rounded(.up) - 1
        return min(max(level(target * grid), 0), ceiling)
    }
}
