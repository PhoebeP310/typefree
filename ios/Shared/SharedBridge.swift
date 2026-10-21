import Foundation
import Security
import VoicePolishCore

/// 主 App ↔ 键盘的数据通道，存在共享钥匙串里。
/// 不用 App Group：免费 Apple ID 用命令行签名时 App Group 注册不了，而描述文件自带 `<TeamID>.*` 钥匙串通配，
/// 同一团队的 App 和扩展可以直接共用一个钥匙串组。接口和 VoicePolishCore.AppGroupBridge 对齐。
final class SharedBridge {
    static let shared = SharedBridge()

    private let service = "com.phoebep310.typefree.bridge"
    private let accessGroup = SharedContainer.keychainAccessGroup
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - 录音指令（键盘 → 主 App）

    func writeCommand(_ command: RecordingSessionCommand) { write(command, "command") }
    func readCommand() -> RecordingSessionCommand? { read(RecordingSessionCommand.self, "command") }
    func clearCommand() { delete("command") }

    // MARK: - 本次风格（键盘 → 主 App，发 start 前写）

    func writeStyle(_ style: StyleSelection) { write(style, "style") }
    func readStyle() -> StyleSelection { read(StyleSelection.self, "style") ?? StyleSelection() }

    // MARK: - 录音快照（主 App → 键盘）

    func readSnapshot() -> RecordingSessionSnapshot? { read(RecordingSessionSnapshot.self, "snapshot") }
    func writeRecording(sessionID: String) { writeSnapshot(.recording, sessionID) }
    func writeProcessing(sessionID: String) { writeSnapshot(.processing, sessionID) }
    func writeDone(sessionID: String, text: String) { writeSnapshot(.done, sessionID, text: text) }
    func writeError(sessionID: String, message: String) { writeSnapshot(.error, sessionID, error: message) }

    private func writeSnapshot(_ status: RecordingSessionStatus, _ sessionID: String, text: String? = nil, error: String? = nil) {
        write(RecordingSessionSnapshot(sessionID: sessionID, status: status, text: text, errorMessage: error), "snapshot")
    }

    // MARK: - 待机状态

    func writeStandbyStatus(_ status: AppGroupBridge.StandbyStatus) { write(status, "standby") }
    func readStandbyStatus() -> AppGroupBridge.StandbyStatus? { read(AppGroupBridge.StandbyStatus.self, "standby") }

    // MARK: - 音量（录音时主 App 每 0.1 秒写一次）

    private var lastLevelWrite: TimeInterval = 0
    private let levelLock = NSLock()

    func writeAudioLevel(_ level: Float) {
        let now = Date().timeIntervalSince1970
        levelLock.lock()
        let due = now - lastLevelWrite >= 0.1 || level == 0
        if due { lastLevelWrite = now }
        levelLock.unlock()
        guard due else { return }
        write(min(max(level, 0), 1), "level")
    }

    func readAudioLevel() -> Float { read(Float.self, "level") ?? 0 }

    // MARK: - 钥匙串

    private func baseQuery(_ account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    private func write<T: Encodable>(_ value: T, _ account: String) {
        guard let data = try? encoder.encode(value) else { return }
        let query = baseQuery(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            // 锁屏时主 App 在后台也要能写
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess { NSLog("[SharedBridge] add %@ failed: %d", account, addStatus) }
        } else if status != errSecSuccess {
            NSLog("[SharedBridge] update %@ failed: %d", account, status)
        }
    }

    private func read<T: Decodable>(_ type: T.Type, _ account: String) -> T? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
