import XCTest
@testable import VoicePolishCore

/// 工单 #9：~/.config 被 root 占着 → 默认配置目录建不了 → 退到备用位置，而不是每次启动都像第一次。
final class ConfigStorageFallbackTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPrimaryUsableStaysPrimary() {
        let primary = root.appendingPathComponent("primary")
        let fallback = root.appendingPathComponent("fallback")
        let r = VoicePolishConfig.resolveStorageDirectory(primary: primary, fallback: fallback)
        XCTAssertEqual(r.directory, primary)
        XCTAssertNil(r.fallbackReason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: primary.path), "默认位置不存在时应当建出来")
    }

    func testPrimaryBlockedFallsBack() throws {
        // 用一个同名文件挡住默认位置：createDirectory 必失败，等价于「父目录属主是 root 建不了」
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let primary = blocked.appendingPathComponent("voicepolish")
        let fallback = root.appendingPathComponent("fallback")
        let r = VoicePolishConfig.resolveStorageDirectory(primary: primary, fallback: fallback)
        XCTAssertEqual(r.directory, fallback)
        XCTAssertNotNil(r.fallbackReason)
    }

    func testKeepsFallbackOnceUsed() throws {
        // 之前已在备用位置存过设置、默认位置又空着 → 继续用备用位置，别来回跳导致设置「丢了」
        let primary = root.appendingPathComponent("primary")
        let fallback = root.appendingPathComponent("fallback")
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: fallback.appendingPathComponent("config.json"))
        let r = VoicePolishConfig.resolveStorageDirectory(primary: primary, fallback: fallback)
        XCTAssertEqual(r.directory, fallback)
    }

    func testWriteFailureIsExposed() throws {
        // 目录本身是个文件 → config.json 写不进 → lastWriteFailure 有值，成功后清空
        let asFile = root.appendingPathComponent("not-a-dir")
        try Data().write(to: asFile)
        let config = VoicePolishConfig(configDir: asFile, secrets: InMemorySecretStore())
        config.save(value: "x", forKey: "k")
        XCTAssertNotNil(config.lastWriteFailure)
    }
}
