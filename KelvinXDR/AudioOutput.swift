//
//  AudioOutput.swift
//  KelvinXDR
//
//  Which device the system is actually playing through.
//
//  A monitor answering DDC's volume register (VCP 0x62) does not mean sound is coming out of
//  it — both LG panels here report audio while the Mac plays through its own speakers. Taking
//  the volume keys in that state drives a register nobody can hear, and swallows the keypress
//  so macOS cannot do the obvious thing either.
//

import CoreAudio
import Foundation

enum AudioOutput {
    /// Name of the current default output device, e.g. "MacBook Pro Speakers" or "LG Ultra HD".
    ///
    /// Matched against `NSScreen.localizedName` to decide whether a display owns the audio.
    /// ponytail: name matching, which is what MonitorControl settled on too. It is ambiguous
    /// with two identically-named monitors — the cursor breaks the tie. Add an explicit
    /// per-display override pref if that ever picks wrong.
    static var name: String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }

        address.mSelector = kAudioObjectPropertyName
        // Unmanaged, not CFString?: CoreAudio writes a +1 retained reference into this buffer
        // and ARC cannot see it happen, so the release has to be spelled out.
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
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
}
