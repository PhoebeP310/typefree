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

    // 本地改动：侧栏角标 = 用户自己的有效词数（去重、去权重后缀、受上限截断，不含内置词）
    func testPersonalWordCountDedupesAndCaps() {
        XCTAssertEqual(PersonalVocabulary.personalWordCount(custom: ["Liam", "liam", "喊单|10", " "],
                                                            vocabularyTargets: ["喊单", "徐相"]), 3)
        XCTAssertEqual(PersonalVocabulary.personalWordCount(custom: (0..<(PersonalVocabulary.maxWords + 50)).map { "w\($0)" },  // 本地改动：随上限调整，确保超出上限
                                                            vocabularyTargets: ["徐相"]), PersonalVocabulary.maxWords)
        XCTAssertEqual(PersonalVocabulary.personalWordCount(custom: [], vocabularyTargets: []), 0)
    }

    func testPersonalWordCountMatchesCurrentWordsMinusBuiltinTail() {
        let custom = ["Cursor", "Liam"]          // Cursor 与内置词同名，算用户自己的
        let merged = PersonalVocabulary.mergeWords(builtin: PersonalVocabulary.builtinWords,
                                                   custom: custom, vocabularyTargets: ["徐相"])
        let personal = PersonalVocabulary.personalWordCount(custom: custom, vocabularyTargets: ["徐相"])
        XCTAssertEqual(personal, 3)
        XCTAssertEqual(merged.count - personal, PersonalVocabulary.builtinWords.count - 1, "剩下的是去掉同名 Cursor 后的内置词")
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
