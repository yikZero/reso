import CoreAudio
import AudioToolbox
import Foundation

// MARK: - Audio Input Device

struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID
}

// MARK: - Audio Device Manager

@MainActor
@Observable
final class AudioDeviceManager {
    var availableDevices: [AudioInputDevice] = []

    private static let selectedUIDKey = "SPSelectedAudioDeviceUID"
    private static let selectedNameKey = "SPSelectedAudioDeviceName"
    private var listenerRegistered = false
    private var onDeviceListChanged: (() -> Void)?

    var selectedDeviceUID: String? {
        get { UserDefaults.standard.string(forKey: Self.selectedUIDKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Self.selectedUIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedUIDKey)
                UserDefaults.standard.removeObject(forKey: Self.selectedNameKey)
            }
        }
    }

    var selectedDeviceName: String? {
        UserDefaults.standard.string(forKey: Self.selectedNameKey)
    }

    func selectDevice(uid: String?, name: String?) {
        if let uid {
            UserDefaults.standard.set(uid, forKey: Self.selectedUIDKey)
            UserDefaults.standard.set(name, forKey: Self.selectedNameKey)
        } else {
            selectedDeviceUID = nil
        }
    }

    func refreshDevices() {
        availableDevices = Self.enumerateInputDevices()
    }

    static func enumerateInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        var result: [AudioInputDevice] = []

        for deviceID in deviceIDs {
            var transportType: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(deviceID, &transportAddr, 0, nil, &transportSize, &transportType) == noErr {
                if transportType == kAudioDeviceTransportTypeAggregate { continue }
            }

            var inputAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddr, 0, nil, &inputSize) == noErr else { continue }
            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(inputSize))
            defer { bufferListPtr.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &inputAddr, 0, nil, &inputSize, bufferListPtr) == noErr else { continue }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uid) == noErr else { continue }

            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &name) == noErr else { continue }

            result.append(AudioInputDevice(
                id: uid as String,
                name: name as String,
                deviceID: deviceID
            ))
        }

        return result.sorted { $0.name < $1.name }
    }

    func resolvedDeviceID() -> AudioDeviceID {
        guard let uid = selectedDeviceUID else { return kAudioObjectUnknown }
        if let device = availableDevices.first(where: { $0.id == uid }) {
            return device.deviceID
        }
        print("[AudioDeviceManager] selected device \(uid) not found, using system default")
        return kAudioObjectUnknown
    }

    func isSelectedDeviceAvailable() -> Bool {
        guard let uid = selectedDeviceUID else { return true }
        return availableDevices.contains { $0.id == uid }
    }

    func startListening(onChanged: @escaping () -> Void) {
        self.onDeviceListChanged = onChanged
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            deviceListCallback,
            selfPtr
        )
        listenerRegistered = true
        refreshDevices()
    }

    func stopListening() {
        guard listenerRegistered else { return }
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            deviceListCallback,
            selfPtr
        )
        listenerRegistered = false
    }
}

private func deviceListCallback(
    _: AudioObjectID,
    _: UInt32,
    _: UnsafePointer<AudioObjectPropertyAddress>,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let manager = Unmanaged<AudioDeviceManager>.fromOpaque(clientData).takeUnretainedValue()
    Task { @MainActor in
        manager.refreshDevices()
        manager.onDeviceListChanged?()
    }
    return noErr
}
