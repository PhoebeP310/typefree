import CryptoKit
import Foundation

public struct Encryptor {
    private let key: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
    }

    public func seal(_ plaintext: Data) -> Data? {
        try? AES.GCM.seal(plaintext, using: key).combined
    }

    public func open(_ ciphertext: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: ciphertext) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}

public enum HistoryCrypto {
    public static let linePrefix = "vpenc1:"
    static let keyAccount = "history_encryption_key"

    public enum LineState {
        case encrypted(String)
        case plaintext(AIPolisher.PolishLog)
        case unknown(String)
    }

    /// 钥匙串里没有密钥、但历史文件里已有加密记录时（旧密钥丢了）会广播一次，
    /// App 据此提示用户「旧记录无法再读取，新记录正常保存」。主线程投递。
    public static let keyRegeneratedNotification = Notification.Name("voicePolishHistoryKeyRegenerated")

    public static func defaultEncryptor() -> Encryptor? {
        guard let key = historyKey(logFile: AIPolisher.historyLogFileURL()) else { return nil }
        return Encryptor(key: key)
    }

    /// - logFile: 传入历史文件路径时，用来判断「钥匙串没密钥」是首次使用还是密钥丢失。
    public static func historyKey(secrets: SecretStoring? = nil, logFile: URL? = nil) -> SymmetricKey? {
        let store = secrets ?? defaultSecretStore()
        switch store.lookup(keyAccount) {
        case .found(let b64):
            guard let data = Data(base64Encoded: b64), data.count == 32 else {
                NSLog("[history] encryption key is corrupt; history encryption unavailable")
                return nil
            }
            return SymmetricKey(data: data)
        case .error(let reason):
            // 「读不到」≠「没有」：钥匙串被锁 / 用户拒绝授权 / access group 出错时若生成新密钥，
            // 旧记录会全部变成永久乱码。本次先不加密（新记录跳过、旧记录暂不显示），等能读到再说。
            // 本地改动：macOS 下存储已改为本地文件，日志措辞随之改为通用的 secret store。
            NSLog("[history] secret store lookup failed (\(reason)); history encryption unavailable this session")
            return nil
        case .notFound:
            break
        }

        // 确实没有密钥：首次使用，或密钥已丢。两种情况都要生成新密钥（否则历史功能永久瘫痪），
        // 区别只在于要不要告诉用户旧记录读不回来了。
        let hadEncryptedRecords = logFile.map(hasEncryptedRecords(at:)) ?? false

        let key = SymmetricKey(size: .bits256)
        let b64 = key.withUnsafeBytes { Data(Array($0)).base64EncodedString() }
        guard store.set(keyAccount, b64) else {
            NSLog("[history] failed to store encryption key; history will not be recorded")
            return nil
        }
        if hadEncryptedRecords {
            NSLog("[history] encryption key missing while encrypted records exist; generated a new key, older records are unreadable")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: keyRegeneratedNotification, object: nil)
            }
        }
        return key
    }

    /// 只看文件开头一段是否有 `vpenc1:` 行，避免为了判断而读整个文件。
    static func hasEncryptedRecords(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 64 * 1024), as: UTF8.self)
        return head.split(separator: "\n").contains { $0.hasPrefix(linePrefix) }
    }

    public static func encodeLine(_ log: AIPolisher.PolishLog, enc: Encryptor) -> String? {
        guard let json = try? JSONEncoder().encode(log),
              let cipher = enc.seal(json) else { return nil }
        return linePrefix + cipher.base64EncodedString()
    }

    public static func isEncryptedLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(linePrefix)
    }

    public static func classify(_ line: String, enc _: Encryptor?) -> LineState {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(linePrefix) {
            return .encrypted(line)
        }
        if let data = trimmed.data(using: .utf8),
           let log = try? JSONDecoder().decode(AIPolisher.PolishLog.self, from: data) {
            return .plaintext(log)
        }
        return .unknown(line)
    }

    public static func decodeLine(_ line: String, enc: Encryptor?) -> AIPolisher.PolishLog? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(linePrefix) {
            guard let enc = enc else { return nil }
            let b64 = String(trimmed.dropFirst(linePrefix.count))
            guard let data = Data(base64Encoded: b64),
                  let plain = enc.open(data) else { return nil }
            return try? JSONDecoder().decode(AIPolisher.PolishLog.self, from: plain)
        }
        if let data = trimmed.data(using: .utf8) {
            return try? JSONDecoder().decode(AIPolisher.PolishLog.self, from: data)
        }
        return nil
    }

    @discardableResult
    public static func migrateLogFile(at url: URL, secrets: SecretStoring? = nil) -> Bool {
        HistoryFileLock.withLock {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return true }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard lines.contains(where: {
                if case .plaintext = classify($0, enc: nil) { return true }
                return false
            }) else { return true }

            guard let key = historyKey(secrets: secrets, logFile: url) else { return false }
            let enc = Encryptor(key: key)
            var out: [String] = []

            for line in lines {
                switch classify(line, enc: enc) {
                case .encrypted(let raw), .unknown(let raw):
                    out.append(raw)
                case .plaintext(let log):
                    guard let encrypted = encodeLine(log, enc: enc) else { return false }
                    out.append(encrypted)
                }
            }

            let next = out.joined(separator: "\n") + (out.isEmpty ? "" : "\n")
            do {
                try next.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return false
            }

            guard let check = try? String(contentsOf: url, encoding: .utf8) else { return false }
            for line in check.split(separator: "\n", omittingEmptySubsequences: true) {
                if case .plaintext = classify(String(line), enc: enc) { return false }
            }
            return true
        }
    }

    private static func defaultSecretStore() -> SecretStoring {
        #if os(iOS)
        return KeychainSecretStore(accessGroup: "NHC4C4K7X7.com.voicepolish.shared")
        #else
        // 本地改动：macOS 改用本地文件存储（首次缺失时经 security CLI 从钥匙串迁移），运行时不再碰钥匙串。
        return FileSecretStore.shared
        #endif
    }
}
