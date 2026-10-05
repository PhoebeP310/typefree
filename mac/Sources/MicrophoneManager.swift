import Foundation
import CoreAudio
import AVFoundation
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension Notification.Name {
    static let voicePolishMicrophoneListDidChange = Notification.Name("VoicePolishMicrophoneListDidChange")
    static let voicePolishMicrophoneSelectionDidChange = Notification.Name("VoicePolishMicrophoneSelectionDidChange")
    static let voicePolishRecordingWillStart = Notification.Name("VoicePolishRecordingWillStart")
}

/// 麦克风枚举、选择、持久化、热插拔监听
///
/// 选择以 UID 为唯一键（USB 麦克风的名字会重复，UID 不会）。
/// 特殊值 `systemDefaultUID` 表示"跟随系统默认"。
final class MicrophoneManager {
    static let shared = MicrophoneManager()

    /// 哨兵：表示"跟随系统默认输入"
    static let systemDefaultUID = "__system_default__"

    struct Device: Equatable {
        let uid: String
        let name: String
        let deviceID: AudioDeviceID
        let isBuiltIn: Bool
    }

    private let configKey = "selected_microphone_uid"
    private let config = VoicePolishConfig.shared

    private(set) var devices: [Device] = []
    private(set) var selectedUID: String = MicrophoneManager.systemDefaultUID

    private init() {
        loadSelection()
        refreshDevices()
        startHotPlugListener()
    }

    // MARK: - 公开 API

    /// 当前实际生效的设备（如果选了"系统默认"，返回当前系统默认设备）
    var resolvedDevice: Device? {
        if selectedUID == Self.systemDefaultUID {
            guard let defaultID = systemDefaultInputDeviceID else { return nil }
            return devices.first(where: { $0.deviceID == defaultID })
        }
        return devices.first(where: { $0.uid == selectedUID })
    }

    /// 当前实际生效的 AudioDeviceID（供 AudioUnit 使用）
    var resolvedDeviceID: AudioDeviceID? {
        if selectedUID == Self.systemDefaultUID {
            return systemDefaultInputDeviceID
        }
        return devices.first(where: { $0.uid == selectedUID })?.deviceID
    }

    /// 用户在 UI 里看到的显示名
    /// - 选系统默认：`跟随系统默认（XXX）`
    /// - 选具体设备：`XXX`
    func displayName() -> String {
        if selectedUID == Self.systemDefaultUID {
            let following = systemDefaultDeviceName ?? "未知"
            return "跟随系统默认（\(following)）"
        }
        return resolvedDevice?.name ?? "未知设备"
    }

    /// 选择一个设备（uid == systemDefaultUID 表示跟随系统）
    func select(uid: String) {
        guard uid != selectedUID else { return }
        selectedUID = uid
        saveSelection()
        NotificationCenter.default.post(name: .voicePolishMicrophoneSelectionDidChange, object: nil)
    }

    /// 是否选了非默认麦克风（用于状态栏角标判断）
    var isUsingNonDefault: Bool {
        selectedUID != Self.systemDefaultUID
    }

    /// 推荐的麦克风（内置麦克风优先）
    var recommendedUID: String? {
        devices.first(where: { $0.isBuiltIn })?.uid
    }

    // MARK: - 持久化

    private func loadSelection() {
        if let uid = config.loadConfig()[configKey] as? String, !uid.isEmpty {
            selectedUID = uid
        } else {
            selectedUID = Self.systemDefaultUID
        }
    }

    private func saveSelection() {
        config.save(values: [configKey: selectedUID])
    }

    // MARK: - 设备枚举

    /// 重新扫描设备列表（公开供热插拔回调和手动刷新使用）
    func refreshDevices() {
        let newList = enumerateInputDevices()
        let changed = newList != devices
        devices = newList
        if changed {
            // 如果选中的麦克风被拔掉了，回退到系统默认
            if selectedUID != Self.systemDefaultUID,
               !devices.contains(where: { $0.uid == selectedUID }) {
                selectedUID = Self.systemDefaultUID
                saveSelection()
                NotificationCenter.default.post(name: .voicePolishMicrophoneSelectionDidChange, object: nil)
            }
            NotificationCenter.default.post(name: .voicePolishMicrophoneListDidChange, object: nil)
        }
    }

    /// 当前系统默认输入设备的名字（独立于用户的选择）
    var systemDefaultDeviceName: String? {
        guard let id = systemDefaultInputDeviceID else { return nil }
        return devices.first(where: { $0.deviceID == id })?.name
    }

    private var systemDefaultInputDeviceID: AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private func enumerateInputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInputStreams(deviceID: id) else { return nil }
            guard let name = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceNameCFString) else { return nil }
            guard !isPhantomAggregateDevice(deviceID: id, name: name) else { return nil }
            guard let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            let isBuiltIn = isBuiltInMicrophone(deviceID: id, name: name)
            return Device(uid: uid, name: name, deviceID: id, isBuiltIn: isBuiltIn)
        }
    }

    private func isBuiltInMicrophone(deviceID: AudioDeviceID, name: String) -> Bool {
        guard transportType(deviceID: deviceID) == kAudioDeviceTransportTypeBuiltIn else {
            return false
        }

        let lowercasedName = name.lowercased()
        let externalMarkers = ["外置", "external", "usb"]
        guard !externalMarkers.contains(where: { lowercasedName.contains($0.lowercased()) }) else {
            return false
        }

        let builtInMarkers = ["macbook", "mac book", "built-in", "built in", "internal", "内建", "内置"]
        return builtInMarkers.contains { lowercasedName.contains($0.lowercased()) }
    }

    private func isPhantomAggregateDevice(deviceID: AudioDeviceID, name: String) -> Bool {
        if name.hasPrefix("CADefaultDeviceAggregate") || name.hasPrefix("CADefault") {
            return true
        }
        if transportType(deviceID: deviceID) == kAudioDeviceTransportTypeAggregate {
            return true
        }
        if objectClass(deviceID: deviceID) == kAudioAggregateDeviceClassID {
            return true
        }
        return false
    }

    private func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return false }

        // ⚠ 必须按系统给的 size 分配，别再写成 `UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)`。
        // AudioBufferList 是变长结构：4 字节 mNumberBuffers + 尾部 mNumberBuffers 个 AudioBuffer。
        // arm64 上一个结构体只有 24 字节（= 1 个 buffer），而有 2 个输入流的设备系统要写 40 字节
        // → 每次枚举麦克风就越界写 16 字节，堆被写坏后进程会在随后任何地方崩（分配器报错、
        // 释放野对象、跳空地址都见过）。工单 #1005 的用户用 3.5mm 耳机麦、一天崩好几次就是这个；
        // owner 机器上所有设备恰好都 ≤24 字节，所以本地永远复现不出来。见 crash 报告分析 2026-09-21。
        let byteCount = max(Int(size), MemoryLayout<AudioBufferList>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount,
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else { return false }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for buf in buffers where buf.mNumberChannels > 0 {
            return true
        }
        return false
    }

    private func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var unmanaged: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &unmanaged)
        guard status == noErr, let cf = unmanaged?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private func transportType(deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : 0
    }

    private func objectClass(deviceID: AudioDeviceID) -> AudioClassID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioClassID>.size)
        var value = AudioClassID(0)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : 0
    }

    // MARK: - 热插拔监听

    private var hotPlugListenerInstalled = false

    private func startHotPlugListener() {
        guard !hotPlugListenerInstalled else { return }

        // Devices changed listener
        var addr1 = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block1: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshDevices() }
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr1, DispatchQueue.main, block1
        )

        // Default input device changed listener
        var addr2 = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block2: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.selectedUID == Self.systemDefaultUID {
                    NotificationCenter.default.post(name: .voicePolishMicrophoneSelectionDidChange, object: nil)
                }
            }
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr2, DispatchQueue.main, block2
        )

        hotPlugListenerInstalled = true
    }
}
