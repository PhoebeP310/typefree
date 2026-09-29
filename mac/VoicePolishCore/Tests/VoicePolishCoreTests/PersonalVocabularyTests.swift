import XCTest
@testable import VoicePolishCore

final class PersonalVocabularyTests: XCTestCase {

    func testMergeWordsPutsPersonalWordsBeforeBuiltin() {
        let words = PersonalVocabulary.mergeWords(
            builtin: ["Claude"],
            custom: ["小肚控制台"],
            vocabularyTargets: ["徐相"]
        )
        XCTAssertEqual(words, ["小肚控制台", "徐相", "Claude"])
    }

    func testLimitCutsBuiltinBeforePersonalWords() {
        let words = PersonalVocabulary.mergeWords(
            builtin: ["iPhone", "Git"],
            custom: [],
            vocabularyTargets: ["Qwen", "徐相"],
            limit: 3
        )
        XCTAssertEqual(words, ["Qwen", "徐相", "iPhone"])
    }

    func testBuiltinWordsHaveNoPersonalNames() {
        for word in ["王鑫", "小肚控制台", "小肚", "打新", "结构图", "消耗暴增", "OpenClaw", "polyMarket"] {
            XCTAssertFalse(PersonalVocabulary.builtinWords.contains(word), "\(word) 是个人词，不该随安装包发给所有用户")
        }
    }

    func testMergeWordsStripsWeightSuffix() {
        let words = PersonalVocabulary.mergeWords(
            builtin: [],
            custom: ["小肚控制台|10", " 热词 | 5 "],
            vocabularyTargets: []
        )
        XCTAssertEqual(words, ["小肚控制台", "热词"])
    }

    func testMergeWordsDeduplicatesIgnoringCase() {
        let words = PersonalVocabulary.mergeWords(
            builtin: ["Claude Code"],
            custom: ["claude code"],
            vocabularyTargets: ["CLAUDE CODE", "徐相"]
        )
        XCTAssertEqual(words, ["claude code", "徐相"])   // 用户自己的写法优先
    }

    func testMergeWordsSkipsEmptyAndRespectsLimit() {
        let words = PersonalVocabulary.mergeWords(
            builtin: ["", "  "],
            custom: ["a", "b", "c"],
            vocabularyTargets: ["d"],
            limit: 3
        )
        XCTAssertEqual(words, ["a", "b", "c"])
    }

    func testContextSentenceFormat() {
        XCTAssertEqual(
            PersonalVocabulary.contextSentence(for: ["热词", "小肚控制台"]),
            "用户常说的词：热词、小肚控制台"
        )
    }

    func testContextSentenceNilWhenEmpty() {
        XCTAssertNil(PersonalVocabulary.contextSentence(for: []))
    }
}

/// 2026-09-23：火山词库传法按官方文档改为「热词直传」（可叠加 dialog_ctx 提示句）
final class VolcanoVocabContextTests: XCTestCase {
    func testHotwordsFormatMatchesOfficialDoc() throws {
        let obj = try XCTUnwrap(PersonalVocabulary.volcanoContextObject(words: ["张鹤", "Claude Code"], mode: .hotwords))
        let hot = try XCTUnwrap(obj["hotwords"] as? [[String: String]])
        XCTAssertEqual(hot, [["word": "张鹤"], ["word": "Claude Code"]])
        XCTAssertNil(obj["context_type"], "只传热词时不应带 dialog_ctx")
    }

    func testBothPutsHotwordsAndDialogContextInOneObject() throws {
        let obj = try XCTUnwrap(PersonalVocabulary.volcanoContextObject(words: ["千问"], mode: .both))
        XCTAssertEqual((obj["hotwords"] as? [[String: String]])?.first?["word"], "千问")
        XCTAssertEqual(obj["context_type"] as? String, "dialog_ctx")
        let data = try XCTUnwrap(obj["context_data"] as? [[String: String]])
        XCTAssertEqual(data.first?["text"], "用户常说的词：千问")
    }

    func testLegacyContextModeUnchanged() throws {
        let obj = try XCTUnwrap(PersonalVocabulary.volcanoContextObject(words: ["热词"], mode: .context))
        XCTAssertNil(obj["hotwords"])
        XCTAssertEqual((obj["context_data"] as? [[String: String]])?.first?["text"], "用户常说的词：热词")
    }

    func testEmptyVocabularySendsNothing() {
        XCTAssertNil(PersonalVocabulary.volcanoContextObject(words: [], mode: .both))
    }
}
