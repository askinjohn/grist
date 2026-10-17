import Foundation
import CoreAudio

/// Reads process activity only; does not record audio or inspect browser content.
enum MeetingAudioActivity {
    static func inputBundleIDs() -> [String] {
        var address = property(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = processes.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return processes.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { process in
            var input: UInt32 = 0
            var inputSize = UInt32(MemoryLayout<UInt32>.size)
            var inputAddress = property(kAudioProcessPropertyIsRunningInput)
            guard AudioObjectGetPropertyData(process, &inputAddress, 0, nil, &inputSize, &input) == noErr,
                  input != 0 else { return nil }
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAddress = property(kAudioProcessPropertyBundleID)
            guard AudioObjectGetPropertyData(process, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr,
                  let bundle else { return nil }
            return bundle.takeRetainedValue() as String
        }
    }

    private static func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

/// Stable identifiers keep tab-title changes from creating repeated prompts.
struct MeetingDetectionEpisode {
    private(set) var key: String?
    private var hits = 0
    private var misses = 0
    private var handled = false

    mutating func observe(_ candidate: String?) -> Bool {
        guard let candidate else {
            misses += 1
            if misses >= 4 { self = Self() }
            return false
        }
        misses = 0
        if key != candidate {
            key = candidate
            hits = 0
            handled = false
        }
        hits += 1
        guard hits >= 2, !handled else { return false }
        handled = true
        return true
    }

    mutating func dismiss() { handled = true }
}
