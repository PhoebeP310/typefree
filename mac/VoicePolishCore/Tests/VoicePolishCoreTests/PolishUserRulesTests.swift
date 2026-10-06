import XCTest
@testable import VoicePolishCore

/// 本地改动：polish_user_rules（用户自定义写作规则）拼 prompt 段的测试
final class PolishUserRulesTests: XCTestCase {

    private let rules: [String: Any] = [
        "global": ["不要使用破折号"],
        "apps": [
            "WEA": ["用中文全角标点", "不要添加 emoji"],
            "Cursor": ["所有细节都不能删"],
        ],
    ]

    func testNoRulesReturnsEmpty() {
        XCTAssertEqual(AIPolisher.userRulesPromptSection(rawRules: nil, appName: "Cursor"), "")
        XCTAssertEqual(AIPolisher.userRulesPromptSection(rawRules: "bad", appName: "Cursor"), "")
        XCTAssertEqual(AIPolisher.userRulesPromptSection(rawRules: [String: Any](), appName: "Cursor"), "")
        XCTAssertEqual(AIPolisher.userRulesPromptSection(rawRules: ["global": [], "apps": ["WEA": ["x"]]], appName: "Safari"), "")
    }

    func testGlobalOnlyWhenAppDoesNotMatch() {
        let s = AIPolisher.userRulesPromptSection(rawRules: rules, appName: "Google Chrome")
        XCTAssertEqual(s, "\n\n## 用户的写作规则（优先遵守）\n- 不要使用破折号")
    }

    func testGlobalOnlyWhenAppNameMissing() {
        let s = AIPolisher.userRulesPromptSection(rawRules: rules, appName: nil)
        XCTAssertEqual(s, "\n\n## 用户的写作规则（优先遵守）\n- 不要使用破折号")
    }

    func testAppRulesMatchCaseInsensitiveSubstring() {
        let s = AIPolisher.userRulesPromptSection(rawRules: rules, appName: "wea-desktop")
        XCTAssertEqual(s, "\n\n## 用户的写作规则（优先遵守）\n- 不要使用破折号\n- 用中文全角标点\n- 不要添加 emoji")
        XCTAssertFalse(s.contains("所有细节"))
    }

    func testAppRulesWithoutGlobal() {
        let s = AIPolisher.userRulesPromptSection(rawRules: ["apps": ["cursor": ["所有细节都不能删"]]], appName: "Cursor")
        XCTAssertEqual(s, "\n\n## 用户的写作规则（优先遵守）\n- 所有细节都不能删")
    }

    func testBlankAndDuplicateRulesDropped() {
        let raw: [String: Any] = ["global": ["  ", "A", 3, "A"], "apps": ["": ["B"], "Cur": ["A", " C "]]]
        let s = AIPolisher.userRulesPromptSection(rawRules: raw, appName: "Cursor")
        XCTAssertEqual(s, "\n\n## 用户的写作规则（优先遵守）\n- A\n- C")
    }
}

/// 本地改动：polish_user_rules.english 只在输出语言是英文时附加
final class PolishUserRulesEnglishTests: XCTestCase {
    private let rules: [String: Any] = [
        "global": ["不要使用破折号"],
        "english": ["英文输出用短句", "with 不要缩写成 w/"],
    ]
    private let en = OutputLanguage.builtin.first { $0.id == "en" }!
    private let ja = OutputLanguage.builtin.first { $0.id == "ja" }!

    func testEnglishRulesOnlyForEnglishOutput() {
        let none = AIPolisher.userRulesPromptSection(rawRules: rules, appName: nil)
        XCTAssertEqual(none, "\n\n## 用户的写作规则（优先遵守）\n- 不要使用破折号")
        let japanese = AIPolisher.userRulesPromptSection(rawRules: rules, appName: nil, outputLanguage: ja)
        XCTAssertFalse(japanese.contains("英文输出用短句"))
        let english = AIPolisher.userRulesPromptSection(rawRules: rules, appName: nil, outputLanguage: en)
        XCTAssertEqual(english, "\n\n## 用户的写作规则（优先遵守）\n- 不要使用破折号\n- 英文输出用短句\n- with 不要缩写成 w/")
    }

    func testEnglishRulesAloneAndInComposedPrompt() {
        let only: [String: Any] = ["english": ["Thx"]]
        XCTAssertEqual(AIPolisher.userRulesPromptSection(rawRules: only, appName: "WEA"), "")
        XCTAssertEqual(AIPolisher.userRulesPromptSection(rawRules: only, appName: "WEA", outputLanguage: en),
                       "\n\n## 用户的写作规则（优先遵守）\n- Thx")
        let sysEN = AIPolisher.composedPromptForTesting(outputLanguage: en, outputFormat: nil, rawRules: rules, appName: nil)
        XCTAssertTrue(sysEN.contains("## 目标语言"))
        XCTAssertTrue(sysEN.contains("- 英文输出用短句"))
        let sysZH = AIPolisher.composedPromptForTesting(outputLanguage: nil, outputFormat: .keyPoints, rawRules: rules, appName: nil)
        XCTAssertFalse(sysZH.contains("英文输出用短句"))
    }
}
