import Foundation

/// 个人词库的统一读取入口，给三个识别路径共用同一份词表：
/// - 火山 ASR：corpus.context 里「热词直传 hotwords + dialog_ctx 提示句」一起传（2026-09-23 按官方文档改，
///   16 句实测：组合 15/16 > 只用上下文 14/16 > 只用热词 11/16；极速版 / 标准版 / 2.0 均接受）
/// - 百炼 qwen3-asr-flash：system 消息上下文（官方的定制化识别机制）
/// - Omni：system 提示词附加词库段落
public enum PersonalVocabulary {

    /// 内置热词：只放不给提示就容易认错或写法不对的产品名。随安装包发给所有用户，不要放个人的人名/项目名。
    /// 2026-09-11 逐词实验（火山 2.0，不给提示 vs 给提示）：ChatGPT、OpenAI、GitHub、iPhone、WeChat、API 等
    /// 20 多个常见词不给提示也认对，已删（官方也建议别放通用词）；留下的如 Claude 不给提示会认成 CLOUD。
    static let builtinWords: [String] = [
        // AI 产品
        "Claude", "Claude Code", "Cursor", "Typeless", "DeepSeek", "Gemini",
        // 开发工具
        "Xcode", "Git", "fallback",
        // Apple 生态
        "Safari", "SwiftUI"
    ]

    /// 单次请求携带的词数上限。火山新文档（2026-07）写上下文上限 500 tokens，
    /// 但 2026-09-11 实测 1381 字符的上下文照样全部生效。
    // 本地改动：用户词库扩到约 145 个，160 词约 1000 字符，仍在原作者实测生效的 1381 字符以内。
    static let maxWords = 160

    // MARK: - 纯函数（可测试）

    /// 合并 自定义 + 个人词库正确词 + 内置，去掉 "词|权重" 的权重后缀，忽略大小写去重，超过 limit 截断。
    /// 个人的词排在前面：超出上限时先截掉内置的通用词，不挤掉用户自己的词。
    static func mergeWords(builtin: [String],
                           custom: [String],
                           vocabularyTargets: [String],
                           limit: Int = maxWords) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in custom + vocabularyTargets + builtin {
            let word = raw
                .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !word.isEmpty else { continue }
            let key = word.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(word)
            if result.count >= limit { break }
        }
        return result
    }

    // 本地改动：识别时实际带上的词里属于用户自己的那部分（hot_words + term_corrections 的 target，
    // 去重、受上限截断后）。个人词排在内置词前面，所以等于 currentWords() 去掉内置词那段；
    // 用户自己加的词恰好和内置词同名时仍算用户的，内置词开关不影响这个数。
    static func personalWordCount(custom: [String], vocabularyTargets: [String], limit: Int = maxWords) -> Int {
        mergeWords(builtin: [], custom: custom, vocabularyTargets: vocabularyTargets, limit: limit).count
    }

    /// 生成给 ASR 的提示句（与实测验证生效的措辞保持一致），词表为空时返回 nil。
    static func contextSentence(for words: [String]) -> String? {
        guard !words.isEmpty else { return nil }
        return "用户常说的词：" + words.joined(separator: "、")
    }

    /// 火山 corpus.context 里词库的传法（2026-09-23 按官方文档核对后新增）。
    ///
    /// 官方《录音文件识别极速版 HTTP》（2026-09-22 版）与《热词与上下文最佳实践》（2026-08-25 版）写明：
    /// - 词库这类固定专有名词，正规通道是「热词直传」：`{"hotwords":[{"word":"…"}]}`，非流式最多 5000 词；
    /// - `dialog_ctx` 上下文是给对话历史 / 场景描述用的，上限 800 tokens（极速版文档写 500），超出截断；
    /// - 两者可写在同一个 context 字段里，「上下文 + 热词的组合在非流式链路中效果最优」。
    /// 以前只用 dialog_ctx 塞一句「用户常说的词：…」——能用，但走的不是热词通道，而且词一多会被 token 上限截掉。
    public enum VolcanoVocabMode: String {
        case context    // 旧做法：只传 dialog_ctx 提示句
        case hotwords   // 只传热词直传列表
        case both       // 热词直传 + dialog_ctx 提示句（官方推荐的组合）
    }

    /// 组装火山 corpus.context 的 JSON 对象；词表为空时返回 nil。
    static func volcanoContextObject(words: [String], mode: VolcanoVocabMode) -> [String: Any]? {
        guard !words.isEmpty else { return nil }
        var obj: [String: Any] = [:]
        if mode == .hotwords || mode == .both {
            obj["hotwords"] = words.map { ["word": $0] }
        }
        if mode == .context || mode == .both, let sentence = contextSentence(for: words) {
            obj["context_type"] = "dialog_ctx"
            obj["context_data"] = [["text": sentence]]
        }
        return obj
    }

    /// 当前配置下火山 corpus.context 的 JSON 字符串；词库为空时返回 nil。
    /// 传法可用隐藏配置 `asr_vocab_mode`（context / hotwords / both）覆盖，便于对比实测。
    public static func volcanoContextJSON() -> String? {
        guard let obj = volcanoContextObject(words: currentWords(), mode: currentVolcanoVocabMode()),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    public static func currentVolcanoVocabMode() -> VolcanoVocabMode {
        (loadRawConfig()["asr_vocab_mode"] as? String).flatMap(VolcanoVocabMode.init(rawValue:)) ?? defaultVolcanoVocabMode
    }

    /// 默认传法：实测对比后确定（见 volcanoContextJSON 的说明）。
    static let defaultVolcanoVocabMode: VolcanoVocabMode = .both

    // MARK: - 从配置读取

    /// 当前配置下的完整词列表。
    public static func currentWords() -> [String] {
        let json = loadRawConfig()
        let includeBuiltin = (json["bigasr_include_builtin_hot_words"] as? Bool) ?? true
        let custom = json["hot_words"] as? [String] ?? []
        let targets = vocabularyTargets(from: json)
        return mergeWords(builtin: includeBuiltin ? builtinWords : [],
                          custom: custom,
                          vocabularyTargets: targets)
    }

    // 本地改动：侧栏「个人词库」角标用，按当前配置算用户自己的有效词数
    public static func currentPersonalWordCount() -> Int {
        let json = loadRawConfig()
        return personalWordCount(custom: json["hot_words"] as? [String] ?? [],
                                 vocabularyTargets: vocabularyTargets(from: json))
    }

    /// 给 ASR 的提示句，如 "用户常说的词：A、B、C"；词库为空时返回 nil。
    public static func asrContextSentence() -> String? {
        contextSentence(for: currentWords())
    }

    private static func vocabularyTargets(from json: [String: Any]) -> [String] {
        guard let entries = json["term_corrections"] as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            if let enabled = entry["enabled"] as? Bool, !enabled { return nil }
            guard let target = (entry["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !target.isEmpty else { return nil }
            return target
        }
    }

    private static func loadRawConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: VoicePolishConfig.shared.configFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }
}
