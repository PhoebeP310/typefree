import XCTest
@testable import VoicePolishCore

/// 工单 #1033：没说话时识别模型把词库提示句当结果吐出来。
final class ContextEchoTests: XCTestCase {
    private let words = ["拉升", "Codex 协作", "关于副", "Node.js"]

    func testUserReportedEchoBecomesNoSpeech() {
        // 用户原样贴来的识别结果
        XCTAssertNil(PersonalVocabulary.removingContextEcho("用户常说的词：拉升、Codex 协作、关于副。   ", words: words))
    }

    func testEchoWithoutPrefixBecomesNoSpeech() {
        XCTAssertNil(PersonalVocabulary.removingContextEcho("拉升、Codex 协作、关于副。", words: words))
    }

    func testEchoMixedWithRealSpeechKeepsSpeech() {
        XCTAssertEqual(PersonalVocabulary.removingContextEcho("用户常说的词：拉升、Codex 协作。今天先把发版做完", words: words),
                       "今天先把发版做完")
    }

    func testNormalSpeechUntouched() {
        let s = "今天拉升了不少，Codex 协作也很顺。"
        XCTAssertEqual(PersonalVocabulary.removingContextEcho(s, words: words), s)
        XCTAssertEqual(PersonalVocabulary.removingContextEcho("拉升", words: words), "拉升")   // 只说一个词库词是正常的
    }

    func testDotInVocabWordDoesNotEndSentence() {
        XCTAssertNil(PersonalVocabulary.removingContextEcho("用户常说的词：Node.js、拉升", words: words))
    }

    func testPrefixMatchesContextSentence() {
        XCTAssertTrue(PersonalVocabulary.contextSentence(for: words)!.hasPrefix(PersonalVocabulary.contextSentencePrefix))
    }
}
