import XCTest
@testable import VoicePolishCore

/// 本地改动：格式口令「改成要点」「结论先行」的识别（规则同 OutputLanguageCommandTests）
final class OutputFormatCommandTests: XCTestCase {
    private func detect(_ s: String) -> OutputFormatCommand? { OutputFormatCommand.detect(in: s) }
    private func parse(_ s: String) -> VoiceCommands { VoiceCommands.parse(s) }

    func testTrailingCommands() {
        let cases: [(String, String, OutputFormat, String)] = [
            ("明天三点开会，二楼会议室，带电脑，改成要点", "明天三点开会，二楼会议室，带电脑", .keyPoints, "改成要点"),
            ("明天三点开会，二楼会议室，带电脑改成要点", "明天三点开会，二楼会议室，带电脑", .keyPoints, "改成要点"),
            ("明天三点开会。整理成要点。", "明天三点开会", .keyPoints, "整理成要点"),
            ("明天三点开会 列成要点", "明天三点开会", .keyPoints, "列成要点"),
            ("明天三点开会，改成要点吧", "明天三点开会", .keyPoints, "改成要点"),
            ("因为排期太紧，所以下周再上线，结论先行", "因为排期太紧，所以下周再上线", .conclusionFirst, "结论先行"),
            ("因为排期太紧，所以下周再上线，先说结论。", "因为排期太紧，所以下周再上线", .conclusionFirst, "先说结论"),
        ]
        for (input, body, format, phrase) in cases {
            let cmd = detect(input)
            XCTAssertNotNil(cmd, "应识别：\(input)")
            XCTAssertEqual(cmd?.position, .trailing, input)
            XCTAssertEqual(cmd?.format, format, input)
            XCTAssertEqual(cmd?.matchedPhrase, phrase, input)
            XCTAssertEqual(cmd?.strippedText, body, input)
        }
    }

    func testLeadingCommandsNeedPause() {
        XCTAssertEqual(detect("改成要点，明天三点开会，二楼会议室")?.strippedText, "明天三点开会，二楼会议室")
        XCTAssertEqual(detect("改成要点，明天三点开会")?.position, .leading)
        XCTAssertEqual(detect("结论先行 下周再上线，因为排期太紧")?.format, .conclusionFirst)
        XCTAssertEqual(detect("先说结论：下周再上线")?.strippedText, "下周再上线")
        // 句首没有停顿：当正文
        XCTAssertNil(detect("改成要点的版本明天给你"))
        XCTAssertNil(detect("结论先行是写文档的好习惯"))
        XCTAssertNil(detect("先说结论再说理由比较好"))
    }

    func testMiddleIsContent() {
        XCTAssertNil(detect("他让我把这段改成要点再发群里"))
        XCTAssertNil(detect("写周报要结论先行，大家注意一下"))
    }

    func testNegationIsContent() {
        XCTAssertNil(detect("这段话不要改成要点"))
        XCTAssertNil(detect("这段话，别改成要点。"))
        XCTAssertNil(detect("这次不用结论先行"))
        XCTAssertNil(detect("这段话不要改成要点吧"))
    }

    func testCommandOnlyOrTooShortIsContent() {
        XCTAssertNil(detect("改成要点"))
        XCTAssertNil(detect("结论先行。"))
        XCTAssertNil(detect("好 改成要点"))
        XCTAssertNotNil(detect("好的收到 改成要点"))
        let p = parse("改成要点，用英文")
        XCTAssertNil(p.format)
        XCTAssertNil(p.language)
        XCTAssertEqual(p.strippedText, "改成要点，用英文")
        let q = parse("用英文，结论先行")
        XCTAssertTrue(q.isEmpty)
        XCTAssertEqual(q.strippedText, "用英文，结论先行")
    }

    func testLongestPhraseWins() {
        let cmd = detect("明天开会，整理成要点")
        XCTAssertEqual(cmd?.matchedPhrase, "整理成要点")
    }

    // MARK: - 与语言口令叠加

    func testCombinedWithLanguageTrailing() {
        let p = parse("明天三点开会，二楼会议室，改成要点，用英文")
        XCTAssertEqual(p.language?.target.id, "en")
        XCTAssertEqual(p.format?.format, .keyPoints)
        XCTAssertEqual(p.strippedText, "明天三点开会，二楼会议室")

        let q = parse("明天三点开会，二楼会议室，用英文，改成要点")
        XCTAssertEqual(q.language?.target.id, "en")
        XCTAssertEqual(q.format?.format, .keyPoints)
        XCTAssertEqual(q.strippedText, "明天三点开会，二楼会议室")
    }

    func testCombinedLeadingAndTrailing() {
        let p = parse("用英文，下周再上线，因为排期太紧，结论先行")
        XCTAssertEqual(p.language?.position, .leading)
        XCTAssertEqual(p.format?.position, .trailing)
        XCTAssertEqual(p.format?.format, .conclusionFirst)
        XCTAssertEqual(p.strippedText, "下周再上线，因为排期太紧")

        let q = parse("结论先行，用英文，下周再上线，因为排期太紧")
        XCTAssertEqual(q.language?.target.id, "en")
        XCTAssertEqual(q.format?.format, .conclusionFirst)
        XCTAssertEqual(q.strippedText, "下周再上线，因为排期太紧")
    }

    func testParseWithoutCommandsKeepsText() {
        let p = parse("明天三点开会")
        XCTAssertTrue(p.isEmpty)
        XCTAssertEqual(p.strippedText, "明天三点开会")
        let onlyLang = parse("明天三点开会，用英文")
        XCTAssertNil(onlyLang.format)
        XCTAssertEqual(onlyLang.strippedText, "明天三点开会")
        // 语言口令被否定、格式口令照常识别
        let neg = parse("这段不要翻译成英文，改成要点")
        XCTAssertNil(neg.language)
        XCTAssertEqual(neg.format?.format, .keyPoints)
        XCTAssertEqual(neg.strippedText, "这段不要翻译成英文")
    }

    func testDisabledFormatsAndLanguages() {
        XCTAssertNil(VoiceCommands.parse("明天开会，改成要点", formats: []).format)
        XCTAssertNil(VoiceCommands.parse("明天开会，用英文", languages: []).language)
    }

    // MARK: - prompt

    func testFormatPromptSectionsAndMarkers() {
        let user = AIPolisher.makeCloudASRPolishUserPrompt(for: "明天开会", outputFormat: .keyPoints)
        XCTAssertTrue(user.contains("【本次要求：改成要点】"))
        XCTAssertFalse(user.contains("用英文输出"))
        let en = OutputLanguage.builtin.first { $0.id == "en" }!
        let both = AIPolisher.makeCloudASRPolishUserPrompt(for: "明天开会", outputLanguage: en, outputFormat: .conclusionFirst)
        XCTAssertTrue(both.contains("【本次要求：结论先行】"))
        XCTAssertTrue(both.contains("【本次要求：用英文输出】"))

        let sys = AIPolisher.composedPromptForTesting(outputLanguage: nil, outputFormat: .keyPoints, rawRules: nil, appName: nil)
        XCTAssertTrue(sys.contains("## 输出格式要求：改成要点"))
        XCTAssertFalse(sys.contains("## 目标语言"))
        let plain = AIPolisher.composedPromptForTesting(outputLanguage: nil, outputFormat: nil, rawRules: nil, appName: nil)
        XCTAssertFalse(plain.contains("输出格式要求"))
        XCTAssertEqual(plain, AIPolisher.baseCloudASRPolishPrompt)
    }
}
