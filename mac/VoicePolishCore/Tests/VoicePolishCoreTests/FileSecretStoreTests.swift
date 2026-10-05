#if os(macOS)
import XCTest
@testable import VoicePolishCore

// 本地改动：FileSecretStore（钥匙串 → 本地 0600 文件）的单元测试，全部在临时目录里跑，不碰真实钥匙串。
final class FileSecretStoreTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("nested/secrets.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vpsecret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func perms(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func rawJSON() throws -> [String: String] {
        let data = try Data(contentsOf: file)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    func testRoundTripCreatesDirAndFileWithStrictPerms() throws {
        let store = FileSecretStore(fileURL: file, legacyReader: nil)
        XCTAssertNil(store.get("k"))
        if case .notFound = store.lookup("k") {} else { XCTFail("expected notFound") }
        XCTAssertTrue(store.set("k", "v1"))
        XCTAssertEqual(store.get("k"), "v1")
        XCTAssertEqual(try perms(file), 0o600)
        XCTAssertEqual(try perms(file.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try rawJSON(), ["k": "v1"])
    }

    func testPermsReenforcedOnEveryWrite() throws {
        let store = FileSecretStore(fileURL: file, legacyReader: nil)
        XCTAssertTrue(store.set("a", "1"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertTrue(store.set("b", "2"))
        XCTAssertEqual(try perms(file), 0o600)
    }

    func testAtomicOverwriteKeepsOtherEntriesAndLeavesNoTempFiles() throws {
        let store = FileSecretStore(fileURL: file, legacyReader: nil)
        XCTAssertTrue(store.set("a", "1"))
        let inodeBefore = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        XCTAssertTrue(store.set("b", "2"))
        XCTAssertTrue(store.set("a", "1b"))
        let inodeAfter = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        XCTAssertNotEqual(inodeBefore, inodeAfter, "应通过 rename 替换整个文件，而非原地改写")
        XCTAssertEqual(try rawJSON(), ["a": "1b", "b": "2"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["secrets.json"])
    }

    func testDeleteWritesTombstoneAndBlocksLegacyResurrection() throws {
        var legacyCalls = 0
        let store = FileSecretStore(fileURL: file, legacyReader: { _ in legacyCalls += 1; return .found("old") })
        XCTAssertTrue(store.set("k", "v"))
        XCTAssertTrue(store.set("k", nil))
        XCTAssertNil(store.get("k"))
        XCTAssertTrue(store.set("k", ""))
        XCTAssertNil(store.get("k"))
        XCTAssertEqual(legacyCalls, 0, "清除过的条目不应再从钥匙串迁移回来")
    }

    func testMigratesFromLegacyOnceAndPersists() throws {
        var legacyCalls = 0
        let store = FileSecretStore(fileURL: file, legacyReader: { account in
            legacyCalls += 1
            return account == "k" ? .found("legacy") : .notFound
        })
        XCTAssertEqual(store.get("k"), "legacy")
        XCTAssertEqual(store.get("k"), "legacy")
        XCTAssertEqual(legacyCalls, 1)
        XCTAssertEqual(try rawJSON(), ["k": "legacy"])
        XCTAssertEqual(try perms(file), 0o600)

        // 新实例（模拟重启）直接从文件读，不再走钥匙串
        let reopened = FileSecretStore(fileURL: file, legacyReader: { _ in XCTFail("should not hit legacy"); return .notFound })
        XCTAssertEqual(reopened.get("k"), "legacy")
    }

    func testLegacyNotFoundIsNotFoundAndCachedInProcess() {
        var legacyCalls = 0
        let store = FileSecretStore(fileURL: file, legacyReader: { _ in legacyCalls += 1; return .notFound })
        if case .notFound = store.lookup("missing") {} else { XCTFail("expected notFound") }
        if case .notFound = store.lookup("missing") {} else { XCTFail("expected notFound") }
        XCTAssertEqual(legacyCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "钥匙串没有时不应写文件")
    }

    func testLegacyErrorPropagatesSoHistoryKeyIsNotRegenerated() {
        let store = FileSecretStore(fileURL: file, legacyReader: { _ in .error("boom") })
        if case .error = store.lookup(HistoryCrypto.keyAccount) {} else { XCTFail("expected error") }
        XCTAssertNil(HistoryCrypto.historyKey(secrets: store))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "读不到旧密钥时绝不能生成新密钥写入")
    }

    func testCorruptFileIsErrorAndIsNotOverwritten() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let store = FileSecretStore(fileURL: file, legacyReader: { _ in .found("x") })
        if case .error = store.lookup("k") {} else { XCTFail("expected error") }
        XCTAssertFalse(store.set("k", "v"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not json")
    }

    func testHistoryKeyMigratedValueIsReused() throws {
        let b64 = Data(repeating: 7, count: 32).base64EncodedString()
        let store = FileSecretStore(fileURL: file, legacyReader: { $0 == HistoryCrypto.keyAccount ? .found(b64) : .notFound })
        let key = try XCTUnwrap(HistoryCrypto.historyKey(secrets: store))
        XCTAssertEqual(key.withUnsafeBytes { Data(Array($0)) }, Data(repeating: 7, count: 32))
        XCTAssertEqual(try rawJSON()[HistoryCrypto.keyAccount], b64)
    }

    func testCLIExitCodeInterpretation() {
        if case .found(let v) = LegacyKeychainCLI.interpret(exitCode: 0, stdout: Data("abc\n".utf8)) {
            XCTAssertEqual(v, "abc")
        } else { XCTFail("expected found") }
        if case .notFound = LegacyKeychainCLI.interpret(exitCode: 44, stdout: Data()) {} else { XCTFail("44 = notFound") }
        if case .error = LegacyKeychainCLI.interpret(exitCode: 51, stdout: Data()) {} else { XCTFail("other = error") }
        if case .error = LegacyKeychainCLI.interpret(exitCode: -1, stdout: Data()) {} else { XCTFail("timeout = error") }
        if case .error = LegacyKeychainCLI.interpret(exitCode: 0, stdout: Data()) {} else { XCTFail("empty = error") }
    }

    func testCLIReadOfNonexistentItemIsNotFound() {
        // 真跑一次 security CLI：随机 service 一定不存在，应得到 44 → notFound（只读，不改钥匙串）
        let r = LegacyKeychainCLI.read(service: "com.voicepolish.test-\(UUID().uuidString)", account: "none")
        if case .notFound = r {} else { XCTFail("expected notFound, got \(r)") }
    }
}
#endif
