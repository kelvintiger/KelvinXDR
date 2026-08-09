//
//  AudioOutput.swift
//  KelvinXDR
//
//  Which device the system is actually playing through, and its volume.
//
//  A monitor answering DDC's volume register (VCP 0x62) does not mean sound is coming out of
//  it — both LG panels here report audio while the Mac plays through its own speakers. Writing
//  that register moves a level nobody can hear. So the volume keys route by *ownership*: the
//  cursor's display when it genuinely owns the audio, the default output device otherwise.
//

import CoreAudio
import Foundation

enum AudioOutput {
    /// The device the system is playing through right now.
    static var defaultDevice: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// Name of the current default output device, e.g. "MacBook Pro Speakers" or "LG Ultra HD".
    ///
    /// Matched against `NSScreen.localizedName` to decide whether a display owns the audio.
    /// ponytail: name matching, which is what MonitorControl settled on too. It is ambiguous
    /// with two identically-named monitors — the cursor breaks the tie. Add an explicit
    /// per-display override pref if that ever picks wrong.
    static var name: String? {
        guard let device = defaultDevice else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        // Unmanaged, not CFString?: CoreAudio writes a +1 retained reference into this buffer
        // and ARC cannot see it happen, so the release has to be spelled out.
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name = name else { return nil }

        return name.takeRetainedValue() as String
    }

    /// Is `displayName` the device currently playing audio?
    ///
    /// NSScreen appends " (1)", " (2)" to tell identically-named displays apart — two LG Ultra
    /// HDs become "LG Ultra HD (1)" and "LG Ultra HD (2)" — while CoreAudio reports the plain
    /// model name. Comparing the two raw would never match, so the suffix comes off first.
    /// - output: defaults to the live device; passed explicitly so the matching can be
    ///   exercised without changing which device the machine is actually playing through.
    static func matches(displayName: String, output: String? = AudioOutput.name) -> Bool {
        guard let output = output else { return false }
        let stripped = displayName.replacingOccurrences(
            of: #" \(\d+\)$"#, with: "", options: .regularExpression)
        return stripped == output || displayName == output
    }

    // MARK: - Level

    /// The master control, element 0.
    ///
    /// ponytail: no per-channel fallback. A handful of USB and HDMI interfaces expose only
    /// per-channel controls and no master, and on those every read here returns nil — which
    /// makes `handleMediaKey` decline the key and hand it straight back to macOS, which adjusts
    /// the device correctly. The only thing lost is our own HUD. Verified unnecessary on this
    /// Mac: MacBook Pro Speakers answers element 0 for both volume and mute. Add elements 1
    /// and 2 here if a device ever turns up that needs them.
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// 0...1, or nil if the device exposes no master volume (optical out, some HDMI).
    static func volume(of device: AudioDeviceID) -> Float? {
        var address = address(kAudioDevicePropertyVolumeScalar)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return Float(min(max(value, 0), 1))
    }

    @discardableResult
    static func setVolume(_ value: Float, on device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyVolumeScalar)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var level = Float32(min(max(value, 0), 1))
        return AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &level) == noErr
    }

    /// nil when the device has no mute control, which makes the mute key pass through.
    static func isMuted(_ device: AudioDeviceID) -> Bool? {
        var address = address(kAudioDevicePropertyMute)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool, on device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyMute)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
