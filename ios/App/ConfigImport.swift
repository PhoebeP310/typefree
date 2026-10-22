import Foundation
import VoicePolishCore

/// 把 Mac 端导出的设置（识别 / 润色 Key、热词、纠错词、润色规则）导入 iPhone。
/// 导出脚本：ios/scripts/export_mac_config.sh，生成的 JSON 经通用剪贴板贴过来。
enum ConfigImport {
    static let pushedFileName = "typefree-import.json"

    /// 只搬和识别、润色有关的项；Mac 专属的（开机自启、Dock 图标、提示音等）不搬
    static let importableKeys: Set<String> = [
        "bigasr_version", "bigasr_include_builtin_hot_words", "bigasr_app_id",
        "bigasr_boosting_table_name", "bigasr_boosting_table_id",
        "bigasr_correct_table_name", "bigasr_correct_table_id",
        "hot_words", "hot_words_groups", "term_corrections",
        "polish_provider", "polish_user_rules",
        "qwen_polish_model", "deepseek_polish_model", "doubao_polish_model", "zhipu_polish_model",
        "output_languages", "default_output_language", "output_language_command_enabled",
    ]

    static let secretKeys: Set<String> = [
        "ark_api_key", "dashscope_api_key", "bigasr_api_key",
        "bigasr_access_token", "zhipu_api_key", "deepseek_api_key",
    ]

    struct Summary {
        let settingCount: Int
        let secretCount: Int
        let hotWordCount: Int
    }

    enum ImportError: LocalizedError {
        case notExport
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .notExport: return "剪贴板里不是 Typefree 导出的设置。先在 Mac 上跑导出脚本，再回来点导入。"
            case .writeFailed: return "写入失败，请重试"
            }
        }
    }

    static func importFromJSON(_ text: String) throws -> Summary {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["typefree_export"] != nil else {
            throw ImportError.notExport
        }
        let config = (root["config"] as? [String: Any] ?? [:]).filter { importableKeys.contains($0.key) }
        let secrets = (root["secrets"] as? [String: Any] ?? [:])
            .compactMapValues { $0 as? String }
            .filter { secretKeys.contains($0.key) && !$0.value.isEmpty }

        var values = config
        // 手机上删过的热词（记在 hot_words_blocked）导入时跳过，免得一导入全回来
        let blocked = VoicePolishConfig.shared.loadConfig()[SyncedHotWords.blockedKey] as? [String] ?? []
        if !blocked.isEmpty {
            for word in blocked {
                let r = SyncedHotWords.block(word, hotWords: values[SyncedHotWords.hotWordsKey] as? [String] ?? [],
                                             groupMap: values[SyncedHotWords.groupsKey] as? [String: [String]],
                                             blocked: blocked)
                values[SyncedHotWords.hotWordsKey] = r.hotWords
                if let g = r.groups { values[SyncedHotWords.groupsKey] = g }
            }
        }
        for (key, value) in secrets { values[key] = value }
        VoicePolishConfig.shared.save(values: values)

        if secrets.contains(where: { VoicePolishConfig.shared.string(forKey: $0.key) != $0.value }) {
            throw ImportError.writeFailed
        }
        let hotWords = (config["hot_words"] as? [Any])?.count ?? 0
        return Summary(settingCount: config.count, secretCount: secrets.count, hotWordCount: hotWords)
    }
}
