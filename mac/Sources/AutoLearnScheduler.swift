import Foundation
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

/// 全自动个人化学习调度器：从本地历史成稿里挖个人词汇（写入词库）+ 更新风格画像。
/// 设计原则（owner 2026-07 定）：零弹窗零确认——自动发现、自动入库、自动生效；
/// 用户的反悔通道是词库页（可看可删，删掉的词记入 dismissed 永不再学）和「自动学习」总开关。
/// 隐私：全部本地统计；画像与词条只拼进润色提示词，不上传任何语料。
final class AutoLearnScheduler {

    static let shared = AutoLearnScheduler()

    var debugLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.voicepolish.autolearn", qos: .utility)
    private let config = VoicePolishConfig.shared
    private var newRecordsSinceRun = 0

    /// 词库里自动词的总量上限（含纠错学习学到的），防止挤占手动词的注入预算
    private let autoWordCap = 60
    /// 每次最多回看这么多条历史
    private let historyWindow = 300

    private struct State: Codable {
        var lastRunAt: Date?
        var minedWords: [String] = []      // 本调度器加过的词，用于识别"用户删了哪个"
        var dismissedWords: [String] = []  // 用户删过的自动词，永不再学
    }

    private init() {}

    // MARK: - 触发

    /// App 启动后调用：延迟几秒在后台跑一次（距上次运行超 6 小时才真跑）。
    func scheduleLaunchRun() {
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self = self else { return }
            let last = self.loadState().lastRunAt
            let due = last.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true
            if due { self.run() }
        }
    }

    /// 每次成功投递文字后调用：攒满 5 条新记录，或距上次运行超 24 小时就跑。
    func noteRecordDelivered() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.newRecordsSinceRun += 1
            let last = self.loadState().lastRunAt
            let stale = last.map { Date().timeIntervalSince($0) > 24 * 3600 } ?? true
            if self.newRecordsSinceRun >= 5 || stale { self.run() }
        }
    }

    // MARK: - 主流程（串行队列上执行）

    private func run() {
        guard config.bool(forKey: "term_corrections_auto_learn_enabled", defaultValue: true) else {
            StyleProfileStore.clear()   // 关掉学习就不再用旧画像影响润色（词库词条保留，用户可在词库页处理）
            debugLog?("AutoLearn: 总开关关闭，跳过（已清除风格画像）")
            return
        }

        newRecordsSinceRun = 0
        var state = loadState()
        defer {
            state.lastRunAt = Date()
            saveState(state)
        }

        // 从成稿挖词默认停用（2026-09-11）：成稿是识别+润色自己的输出，已认对的词加进词表没增益，
        // 认错的写法（Claude 听成 Cloud）反而被当成常用词越学越牢，还挖进 in/Pro/Max 这类通用词占名额。
        let miningEnabled = config.bool(forKey: "vocab_mining_enabled", defaultValue: false)
        // 风格画像只在「交给润色用」时才统计（2026-09-23）：注入从 7-03 起一直在观察期、默认关，
        // 之前照样每 6 小时解密历史算一遍、存着不用，白算。要用时打开 style_profile_injection_enabled 即可。
        let styleEnabled = config.bool(forKey: "style_profile_injection_enabled", defaultValue: false)
        if !styleEnabled { StyleProfileStore.clear() }
        guard miningEnabled || styleEnabled else {
            debugLog?("AutoLearn: 挖词与风格画像都未启用，跳过（改过的词进词库不走这里）")
            return
        }

        let logs = PolishHistoryStore().load(limit: historyWindow)   // 新→旧
        guard !logs.isEmpty else {
            StyleProfileStore.clear()
            debugLog?("AutoLearn: 无历史记录（未开启保存或已清空），本轮跳过")
            return
        }

        if miningEnabled {
            mineVocabulary(from: logs, state: &state)
        }
        if styleEnabled {
            updateStyleProfile(from: logs)
        }
    }

    // MARK: - 词汇挖掘

    private func mineVocabulary(from logs: [AIPolisher.PolishLog], state: inout State) {
        let entries = (config.loadConfig()["term_corrections"] as? [[String: Any]]) ?? []

        // 已有词：词库正写+误写 + 内置/自定义热词（currentWords 已合并三来源）
        var existing = Set<String>()
        for entry in entries {
            if let target = entry["target"] as? String { existing.insert(norm(target)) }
            for variant in (entry["variants"] as? [String]) ?? [] { existing.insert(norm(variant)) }
        }
        for word in PersonalVocabulary.currentWords() { existing.insert(norm(word)) }

        let autoTargets = entries
            .filter { ($0["source"] as? String) == "auto" }
            .compactMap { $0["target"] as? String }

        // 上轮还在、这轮没了的自动词 = 用户手动删了 → 永不再学
        let currentAutoLower = Set(autoTargets.map(norm))
        let deleted = state.minedWords.filter { !currentAutoLower.contains(norm($0)) }
        if !deleted.isEmpty {
            state.dismissedWords.append(contentsOf: deleted)
            if state.dismissedWords.count > 500 {
                state.dismissedWords.removeFirst(state.dismissedWords.count - 500)
            }
            state.minedWords.removeAll { word in deleted.contains { norm($0) == norm(word) } }
            debugLog?("AutoLearn: 用户删过、不再学：count=\(deleted.count)")
        }

        let samples = logs.compactMap { log -> VocabularyMiner.Sample? in
            let text = log.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2 else { return nil }
            return VocabularyMiner.Sample(text: text, day: String(log.time.prefix(10)))
        }

        let newWords = VocabularyMiner.newWords(
            from: samples,
            existingLowercased: existing,
            dismissedLowercased: Set(state.dismissedWords.map(norm)),
            remainingCapacity: autoWordCap - autoTargets.count
        )
        guard !newWords.isEmpty else { return }

        state.minedWords.append(contentsOf: newWords)
        appendAutoEntries(newWords)
        debugLog?("AutoLearn: 新学 \(newWords.count) 个词")
    }

    /// 往 term_corrections 追加自动词条。主线程做读-改-写，避免与设置窗的保存互相覆盖。
    private func appendAutoEntries(_ words: [String]) {
        DispatchQueue.main.async { [config] in
            var entries = (config.loadConfig()["term_corrections"] as? [[String: Any]]) ?? []
            let known = Set(entries.compactMap { ($0["target"] as? String)?.lowercased() })
            var appended = false
            for word in words where !known.contains(word.lowercased()) {
                entries.append(["target": word, "variants": [String](), "category": "其他", "source": "auto"])
                appended = true
            }
            guard appended else { return }
            config.save(values: ["term_corrections": entries])
            NotificationCenter.default.post(name: .voicePolishTermCorrectionsDidChange, object: nil)
        }
    }

    // MARK: - 风格画像

    private func updateStyleProfile(from logs: [AIPolisher.PolishLog]) {
        // 全局层：人身特征（中英混说/句子节奏/语气词），跟人走
        let outputs = logs.map(\.output)
        let globalSection = StyleProfiler.globalPromptSection(fromOutputs: outputs)

        // 场景层：场合特征（列表/感叹号/敬语/分段），按当时输入到的 App 分组各学各的，
        // 工作软件里的列表习惯不会串到朋友聊天里（other 场景是大杂烩，不学）
        var sceneSections: [String: String] = [:]
        let grouped = Dictionary(grouping: logs) { SceneCategory.classify(appName: $0.app) }
        for (scene, sceneLogs) in grouped where scene != .other {
            let samples = sceneLogs.map { StyleProfiler.Sample(output: $0.output, asr: $0.asr) }
            if let section = StyleProfiler.scenePromptSection(scene: scene, samples: samples) {
                sceneSections[scene.rawValue] = section
            }
        }

        if globalSection != nil || !sceneSections.isEmpty {
            StyleProfileStore.save(StyleProfileSnapshot(
                globalSection: globalSection,
                sceneSections: sceneSections,
                recordCount: outputs.count,
                computedAt: Date()
            ))
            debugLog?("AutoLearn: 风格画像已更新（全局\(globalSection != nil ? "✓" : "—")、场景 \(sceneSections.count) 个，基于 \(outputs.count) 条成稿）")
        } else {
            StyleProfileStore.clear()
            debugLog?("AutoLearn: 成稿不足或无显著风格信号，暂无画像")
        }
    }

    // MARK: - 状态存取

    private var stateFileURL: URL {
        config.configFileURL.deletingLastPathComponent().appendingPathComponent("auto_learn_state.json")
    }

    private func loadState() -> State {
        guard let data = try? Data(contentsOf: stateFileURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return State()
        }
        return state
    }

    private func saveState(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateFileURL, options: .atomic)
    }

    private func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
