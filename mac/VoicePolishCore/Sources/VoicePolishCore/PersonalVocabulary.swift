import Foundation

/// 个人词库的统一读取入口，给三个识别路径共用同一份词表：
/// - 火山 ASR：corpus.context 的 dialog_ctx 上下文（实测 极速版/标准版/2.0 均生效；
///   旧的 {"hotwords":[...]} 内联格式只在流式接口文档里存在，录音文件接口会静默忽略）
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
    /// 但 2026-09-11 实测 1381 字符的上下文照样全部生效；100 词（约 650 字符）留有余量。
    static let maxWords = 100

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
