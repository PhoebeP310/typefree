import XCTest
@testable import VoicePolishCore

/// 配置存不下来 / 读不出来时必须在日志里留痕。
/// 背景：工单 #1007 的用户「每次打开都是初始设置界面、快捷键改不了」，就是 config.json 写不进去，
/// 而当时写失败、读失败都是静默的，他发来的日志里一个字都看不到。
final class ConfigFailureLoggingTests: XCTestCase {

    private func tmpDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vpcfg-log-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 上一级目录不可写（模拟用户机器上 ~/.config 权限不对）→ 保存失败要记一条日志。
    /// 注意不能只把 config 目录本身设成只读：writeConfig 每次都会先把它 chmod 回 0o700，改了也白改。
    func testWriteFailureIsLogged() throws {
        let parent = tmpDir()
        let dir = parent.appendingPathComponent("voicepolish")   // 故意不建，让它建不出来
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: parent)
        }
        let config = VoicePolishConfig(configDir: dir, secrets: InMemorySecretStore())
        var logs: [String] = []
        config.debugLog = { logs.append($0) }

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)   // 上级只读
        config.save(bool: true, forKey: "onboarding_completed")

        XCTAssertFalse(config.bool(forKey: "onboarding_completed"), "写不进去时不该假装保存成功")
        XCTAssertEqual(logs.count, 1, "写失败必须记一条日志")
        XCTAssertTrue(logs[0].contains("配置写入失败"), "日志内容：\(logs[0])")
    }

    /// 文件在但内容坏了 → 记一条日志，且每个实例只记一次，不刷屏。
    func testCorruptFileIsLoggedOnce() {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try? "{ 这不是 JSON".write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let config = VoicePolishConfig(configDir: dir, secrets: InMemorySecretStore())
        var logs: [String] = []
        config.debugLog = { logs.append($0) }

        _ = config.string(forKey: "polish_provider")
        _ = config.string(forKey: "polish_provider")
        _ = config.bool(forKey: "onboarding_completed")

        XCTAssertEqual(logs.count, 1, "同一进程只记一次，避免刷屏")
        XCTAssertTrue(logs[0].contains("配置读取失败"), "日志内容：\(logs[0])")
    }

    /// 一切正常时不该多记任何日志（免得日志被噪声淹没）。
    func testHealthyConfigLogsNothing() {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = VoicePolishConfig(configDir: dir, secrets: InMemorySecretStore())
        var logs: [String] = []
        config.debugLog = { logs.append($0) }

        config.save(bool: true, forKey: "onboarding_completed")
        XCTAssertTrue(config.bool(forKey: "onboarding_completed"))
        XCTAssertTrue(logs.isEmpty, "正常读写不该记日志：\(logs)")
    }
}
