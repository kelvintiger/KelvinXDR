//
//  AppleBrightness.swift
//  KelvinXDR
//
//  Apple's native brightness protocol, for the built-in panel and Apple displays. This is
//  the real backlight, not a gamma trick.
//
//  DisplayServices is a private framework with no SDK stub, so these cannot be linked the
//  way the IOAVService symbols are — they have to be resolved at runtime.
//

import Cocoa

enum AppleBrightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Int32
    private typealias ChangedFn = @convention(c) (CGDirectDisplayID, Double) -> Void

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    private static let getFn: GetFn? = symbol("DisplayServicesGetBrightness", as: GetFn.self)
    private static let setFn: SetFn? = symbol("DisplayServicesSetBrightness", as: SetFn.self)
    private static let canFn: CanFn? = symbol("DisplayServicesCanChangeBrightness", as: CanFn.self)
    /// Tells the system the level moved, so its own UI and any observers stay in sync.
    private static let changedFn: ChangedFn? = symbol("DisplayServicesBrightnessChanged", as: ChangedFn.self)

    static func supported(_ display: CGDirectDisplayID) -> Bool {
        guard let canFn = canFn else { return false }
        return canFn(display) != 0
    }

    /// 0...1, or nil if this display has no native control.
    static func get(_ display: CGDirectDisplayID) -> Float? {
        guard let getFn = getFn else { return nil }
        var value: Float = 0
        guard getFn(display, &value) == 0 else { return nil }
        return value
    }

    @discardableResult
    static func set(_ display: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let setFn = setFn else { return false }
        let clamped = min(max(value, 0), 1)
        guard setFn(display, clamped) == 0 else { return false }
        changedFn?(display, Double(clamped))
        return true
    }
}
