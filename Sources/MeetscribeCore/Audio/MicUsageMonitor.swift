import CoreAudio
import Foundation

/// Lightweight CoreAudio probes — no timers, no ML, no network.
/// Adapted from diarize (MIT).
public enum MicUsageMonitor {
    private static let ignoredInputBundleIDs: Set<String> = [
        "com.apple.CoreSpeech",
        "com.apple.SpeechRecognitionCore",
        "com.apple.accessibility.AXVisualSupportAgent",
    ]

    public static func defaultInputIsRunningSomewhere() -> Bool {
        guard let device = defaultInputDeviceID() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }

    public static func foreignMicInputCount(excludingPIDs excluded: Set<pid_t> = []) -> Int? {
        guard #available(macOS 14.4, *) else { return nil }
        guard let processes = processObjectIDs() else { return nil }

        var count = 0
        for process in processes {
            guard isRunningInput(process) else { continue }
            guard let pid = pid(of: process), !excluded.contains(pid) else { continue }
            if let bundle = bundleID(of: process), ignoredInputBundleIDs.contains(bundle) { continue }
            count += 1
        }
        return count
    }

    private static func defaultInputDeviceID() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr,
              deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    @available(macOS 14.4, *)
    private static func processObjectIDs() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return nil
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &ids
        ) == noErr else {
            return nil
        }
        return ids
    }

    @available(macOS 14.4, *)
    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }

    @available(macOS 14.4, *)
    private static func pid(of process: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr else {
            return nil
        }
        return pid
    }

    @available(macOS 14.4, *)
    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleRef: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &bundleRef) == noErr,
              let bundleRef else {
            return nil
        }
        return bundleRef as String
    }
}
