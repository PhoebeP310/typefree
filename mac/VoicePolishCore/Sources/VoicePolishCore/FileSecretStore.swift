import Foundation

#if os(macOS)
// 本地改动：把敏感凭证从钥匙串挪到本地文件 ~/.config/voicepolish/secrets.json（0600）。
//
// 背景：本 fork 用自签证书（Typefree Local Signing）签名，非 Apple 签发的签名下，
// 钥匙串条目的旧式 ACL / partition list 绑定的是每次编译的 cdhash，于是每次重编安装后
// 系统都会弹「Typefree 想要使用钥匙串中的机密信息」。
// 取舍：同一批条目本来就能被本机进程用 `/usr/bin/security find-generic-password -w`
// 无提示读出，改存 0600 文件并不会实质降低实际防护，却能彻底消除每次重编的弹窗。
// 钥匙串里的原条目保留不动，作为备份；本类绝不删除或修改钥匙串条目。
//
// 文件格式：扁平 JSON {account: value}。value 为空串 = 用户主动清除过（墓碑），
// 此时不再从钥匙串迁移，避免把已删掉的凭证从备份里「复活」。
public final class FileSecretStore: SecretStoring {
    /// 本地改动：App 运行时的默认存储（~/.config/voicepolish/secrets.json，首次缺失时从钥匙串迁移）。
    public static let shared = FileSecretStore()

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voicepolish/secrets.json")
    }

    /// 旧值读取器：account -> 结果。nil 表示不做迁移（测试用）。
    public typealias LegacyReader = (String) -> SecretLookup

    public let fileURL: URL
    private let legacyReader: LegacyReader?
    private let lock = NSLock()
    /// 本进程内已确认钥匙串里也没有的 account，避免每次读取都起一个 security 子进程。
    private var legacyMisses: Set<String> = []

    public init(fileURL: URL = FileSecretStore.defaultFileURL,
                legacyReader: LegacyReader? = { LegacyKeychainCLI.read(service: "com.voicepolish.secret", account: $0) }) {
        self.fileURL = fileURL
        self.legacyReader = legacyReader
    }

    public func get(_ account: String) -> String? {
        if case .found(let value) = lookup(account) { return value }
        return nil
    }

    public func lookup(_ account: String) -> SecretLookup {
        lock.lock(); defer { lock.unlock() }

        let dict: [String: String]
        switch readFile() {
        case .success(let d): dict = d
        case .failure(let reason):
            // 文件存在但读不了 / 解析不了：按「读不到」处理，绝不能当成「没有」
            // （否则 HistoryCrypto 会重新生成历史密钥，旧记录永久不可读）。
            return .error(reason.description)
        }

        if let value = dict[account] {
            return value.isEmpty ? .notFound : .found(value)   // 空串 = 墓碑
        }

        // 文件里没有这个 account：一次性从钥匙串迁移（经 security CLI，不触发 UI）。
        guard let legacyReader = legacyReader, !legacyMisses.contains(account) else { return .notFound }
        switch legacyReader(account) {
        case .found(let value):
            var updated = dict
            updated[account] = value
            if let reason = writeFile(updated) {
                // 写不进文件也照样返回读到的值；下次读取会再迁移一次。
                NSLog("[secret] %@: migrated from keychain but failed to persist (%@)", account, reason)
            }
            return .found(value)
        case .notFound:
            legacyMisses.insert(account)
            return .notFound
        case .error(let reason):
            // 钥匙串里可能有值只是这次没读出来：返回 .error，调用方（如历史密钥）不得据此生成新值。
            return .error("legacy keychain read failed: \(reason)")
        }
    }

    @discardableResult
    public func set(_ account: String, _ value: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard case .success(var dict) = readFile() else { return false }   // 读不了就不覆盖，免得丢其它条目
        if let value = value, !value.isEmpty {
            dict[account] = value
        } else {
            dict[account] = ""   // 墓碑：记住「用户清除过」，不再从钥匙串迁移
        }
        return writeFile(dict) == nil
    }

    // MARK: - 文件读写

    private func readFile() -> Result<[String: String], FileError> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return .success([:]) }
        guard let data = try? Data(contentsOf: fileURL) else {
            return .failure(FileError("secrets file unreadable"))
        }
        if data.isEmpty { return .success([:]) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(FileError("secrets file is not a JSON object"))
        }
        var dict: [String: String] = [:]
        for (k, v) in obj {
            guard let s = v as? String else { return .failure(FileError("secrets file has non-string value")) }
            dict[k] = s
        }
        return .success(dict)
    }

    /// 原子写：同目录临时文件（创建即 0600）→ rename 覆盖。返回 nil 表示成功，否则为失败原因。
    private func writeFile(_ dict: [String: String]) -> String? {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            let tmp = dir.appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
            guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                return "failed to create temp file"
            }
            // createFile 受 umask 影响只会更严，这里再显式收紧一次
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if rename(tmp.path, fileURL.path) != 0 {
                let err = String(cString: strerror(errno))
                try? fm.removeItem(at: tmp)
                return "rename failed: \(err)"
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private struct FileError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
}

/// 本地改动：经 `/usr/bin/security` 读取旧钥匙串条目。CLI 读取不走 App 自身的钥匙串 ACL，
/// 因而不会因为 cdhash 变了而弹窗；只读，绝不写入或删除条目。
public enum LegacyKeychainCLI {
    /// security 的「条目不存在」退出码（errSecItemNotFound 的 CLI 表示）。
    static let itemNotFoundExitCode: Int32 = 44

    public static func read(service: String, account: String?, timeout: TimeInterval = 10) -> SecretLookup {
        var args = ["find-generic-password", "-s", service]
        if let account = account { args += ["-a", account] }
        args.append("-w")
        guard let result = run("/usr/bin/security", args, timeout: timeout) else {
            return .error("failed to run security CLI")
        }
        return interpret(exitCode: result.status, stdout: result.stdout)
    }

    /// 退出码语义：0 = 读到；44 = 确实没有；其它（含超时被终止）= 读不到。
    static func interpret(exitCode: Int32, stdout: Data) -> SecretLookup {
        switch exitCode {
        case 0:
            guard var value = String(data: stdout, encoding: .utf8) else {
                return .error("security CLI output is not UTF-8")
            }
            if value.hasSuffix("\n") { value.removeLast() }
            return value.isEmpty ? .error("security CLI returned empty value") : .found(value)
        case itemNotFoundExitCode:
            return .notFound
        default:
            return .error("security CLI exit code \(exitCode)")
        }
    }

    private static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, stdout: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        // 输出很小（一行），先读到 EOF 再等退出；超时则终止，按「读不到」处理。
        var data = Data()
        let reader = DispatchQueue.global(qos: .userInitiated)
        let readDone = DispatchSemaphore(value: 0)
        reader.async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
            return (status: -1, stdout: Data())
        }
        _ = readDone.wait(timeout: .now() + 2)
        return (status: process.terminationStatus, stdout: data)
    }
}
#endif
