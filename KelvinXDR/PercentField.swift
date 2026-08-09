//
//  PercentField.swift
//  KelvinXDR
//
//  Typing a percentage instead of dragging for it.
//
//  This lives in the settings window rather than the menu, and not for want of trying. NSMenu
//  runs a modal tracking loop that keeps the keyboard for itself: plain characters go to its
//  type-select, so pressing "2" over a menu row jumps the highlight to an item beginning with
//  that letter instead of typing a 2. Only key *equivalents* — combinations with a modifier —
//  reach an item view, which is no way to enter a number. A real window has a real responder
//  chain and none of this applies.
//

import Cocoa

enum Percent {
    /// Percentage text -> 0...max fraction, or nil when there is no number in it.
    ///
    /// Clamps instead of rejecting: typing 500 into a control that stops at 159 plainly means
    /// "as high as it goes", and refusing it would only make you guess the ceiling.
    static func parse(_ text: String, max maxValue: Double) -> Double? {
        // A real decimal parse, not digit-filtering: filtering to digits turned "12.5" into
        // "125" — a dim request became a 125% boost. Comma accepted as the separator too,
        // for keyboards where that is what the numeric pad types.
        guard let range = text.range(of: #"[0-9]+(?:[.,][0-9]+)?"#, options: .regularExpression),
              let percent = Double(text[range].replacingOccurrences(of: ",", with: "."))
        else { return nil }
        return Swift.min(Swift.max(percent / 100, 0), maxValue)
    }

    static func text(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))" }
}

/// A small numeric field that commits on Return and reverts on Escape.
final class PercentField: NSTextField {
    var maxValue: Double = 1
    var onCommit: ((Double) -> Void)?

    /// What to put back on Escape, or when the entry has no number in it.
    var revertText: String = "" {
        didSet { if stringValue.isEmpty { stringValue = revertText } }
    }

    func commit() {
        guard let value = Percent.parse(stringValue, max: maxValue) else {
            stringValue = revertText
            return
        }
        // Show the clamped value rather than what was typed, so 500 visibly becomes 159.
        stringValue = Percent.text(value)
        revertText = stringValue
        onCommit?(value)
    }

    func revert() { stringValue = revertText }
}
