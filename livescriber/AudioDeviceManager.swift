// AudioDeviceManager.swift
// Enumerates CoreAudio input devices and tracks the user's selection.

import Foundation
import Combine
import CoreAudio
import AVFoundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

@MainActor
final class AudioDeviceManager: ObservableObject {
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var selectedDeviceID: AudioDeviceID? = nil

    var selectedDeviceName: String {
        inputDevices.first { $0.id == selectedDeviceID }?.name ?? "Default Microphone"
    }

    func loadDevices() {
        var propSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize
        ) == noErr else { return }

        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &deviceIDs
        )

        inputDevices = deviceIDs.compactMap { id in
            guard hasInputChannels(id), let name = deviceName(id) else { return nil }
            return AudioInputDevice(id: id, name: name, uid: deviceUID(id) ?? "")
        }

        if selectedDeviceID == nil {
            selectedDeviceID = defaultInputDeviceID() ?? inputDevices.first?.id
        }
    }

    // MARK: - Private helpers

    private func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }

        let capacity = Int(size)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, buffer) == noErr else { return false }
        let list = buffer.bindMemory(to: AudioBufferList.self, capacity: 1).pointee
        return list.mNumberBuffers > 0
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}
