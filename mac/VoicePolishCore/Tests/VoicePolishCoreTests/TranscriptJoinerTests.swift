import XCTest
@testable import VoicePolishCore

final class TranscriptJoinerTests: XCTestCase {

    func testEnglishSegmentsGetSpace() {
        XCTAssertEqual(TranscriptJoiner.join(["hello", "world"]), "hello world")
        XCTAssertEqual(TranscriptJoiner.join(["hello ", " world"]), "hello world")
        XCTAssertEqual(TranscriptJoiner.join(["Thank you.", "See you."]), "Thank you. See you.")
        XCTAssertEqual(TranscriptJoiner.join(["Really?", "Yes,", "of course"]), "Really? Yes, of course")
    }

    /// 火山逐句结果的真实形态：句尾自带空格，以前去掉空格后直接相连成 "today.I think"
    func testVolcanoUtterancesWithTrailingSpace() {
        let utterances = ["Thank you for coming today. ",
                          "I think the new version works much better. Let's ship it next week, OK?"]
        XCTAssertEqual(TranscriptJoiner.join(utterances),
                       "Thank you for coming today. I think the new version works much better. Let's ship it next week, OK?")
    }

    func testChineseStaysTight() {
        XCTAssertEqual(TranscriptJoiner.join(["你好", "世界"]), "你好世界")
        XCTAssertEqual(TranscriptJoiner.join(["今天开会。", "明天再说。"]), "今天开会。明天再说。")
        XCTAssertEqual(TranscriptJoiner.join(["价格是", "100块"]), "价格是100块")
    }

    func testMixedChineseAndEnglish() {
        // 两边都是英文单词才补空格
        XCTAssertEqual(TranscriptJoiner.join(["我们用 Claude", "Code 写代码"]), "我们用 Claude Code 写代码")
        XCTAssertEqual(TranscriptJoiner.join(["我用的是 iPhone", "17 Pro"]), "我用的是 iPhone 17 Pro")
        // 一边是中文 / 全角标点就不补
        XCTAssertEqual(TranscriptJoiner.join(["用 ChatGPT", "写的"]), "用 ChatGPT写的")
        XCTAssertEqual(TranscriptJoiner.join(["好的。", "OK"]), "好的。OK")
        XCTAssertEqual(TranscriptJoiner.join(["你说", "Hello"]), "你说Hello")
    }

    func testPunctuationAtStartOfNextSegmentNoSpace() {
        XCTAssertEqual(TranscriptJoiner.join(["hello", ", world"]), "hello, world")
        XCTAssertEqual(TranscriptJoiner.join(["wait", "..."]), "wait...")
    }

    func testEmptyAndWhitespacePartsSkipped() {
        XCTAssertEqual(TranscriptJoiner.join([]), "")
        XCTAssertEqual(TranscriptJoiner.join(["", "  ", "hello", "\n", "world"]), "hello world")
        XCTAssertEqual(TranscriptJoiner.join(["  你好  "]), "你好")
    }

    func testStreamingSessionUsesJoiner() {
        XCTAssertEqual(StreamingTranscriptionSession.join(["Thank you.", "See you."]), "Thank you. See you.")
        XCTAssertEqual(StreamingTranscriptionSession.join(["你好", "世界"]), "你好世界")
    }
}
