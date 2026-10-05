import Foundation
import NaturalLanguage

/// 纠错学词（工单 #1013，2026-09-23 A 方案）：用户改一次识别错的词，就把改对的那个词加进词库当热词。
///
/// 和以前的区别（Ray 拍板）：
/// - 以前同一个错要改两次才入库，入库的是「错法 → 正写」强制替换规则；替换不看上下文，会误伤（「千分之一」→「千问之一」）。
/// - 现在改一次就入库，而且**只加词、不生成替换规则**。词进了热词，识别模型下次听到相近的音会优先用它，但仍看上下文。
///
/// 选词规则照火山官方《热词与上下文最佳实践》（2026-08-25）：只放专有名词（人名、品牌、术语），
/// 通用词不要放（「添加过多无关热词会增加误识别风险」），2~6 个字最好，热词不支持除空格外的标点。
/// 所以学之前先过 `isLearnableWord`：常用词（系统中文词典里有的）、以虚词开头结尾的半截词、带标点的、太长的都不学。
///
/// 学到的词写回词库时仍是老格式（target + 空 variants + source=auto），词库页和老代码都认；
/// 「哪天学到的」另记在 `ledgerKey` 这份小账本里，用来限量（最早学的先让位）和撤销。
/// 限量只动账本里的词：用户手动加的、以前版本留下的词一律不碰。
///
/// 删过的不再学（2026-09-23）：学到的词被用户在词库页删掉，记进 `dismissedKey` 名单，
/// 以后再改同一个错也不自动加回来——用户已经表态不要这个词。
/// 学到当场点「撤销」只删这一次（Ray 拍板）：误点、或为了重测而撤销，都不该把词永久拉黑。
public enum VocabularyLearning {
    /// 配置里记录「自动学到的词 + 学到日期」的键：[{"word": "张鹤", "learned_at": "2026-09-23"}]
    public static let ledgerKey = "learned_vocabulary_ledger"
    /// 用户在词库页删掉的学到的词，不再自动学：["张鹤", …]
    public static let dismissedKey = "learned_vocabulary_dismissed"
    /// 自动学到的词最多留多少个（官方：宁缺毋滥；词库给识别模型的总词数另有 100 的上限）
    public static let maxLearnedWords = 30

    // MARK: - 选词

    /// 这个词值不值得加进热词。
    public static func isLearnableWord(_ raw: String) -> Bool {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return false }
        // 只允许文字、数字、空格：官方「热词不支持除换行和空格之外的标点符号」
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " "))
        guard word.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard !word.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) else { return false }

        let hasLatin = word.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        let cjkCount = word.unicodeScalars.filter { isCJK($0) }.count

        if cjkCount > 0 && !hasLatin {
            // 纯中文：2~10 个字（官方热词表单词上限 10 个中文字）
            guard (2...10).contains(word.count) else { return false }
            // 只由数字和时间单位组成的（周三、星期三、十点、三号、两个）是在改内容，不是认错了字。
            // 系统中文词典收不全这类词（2026-09-23 实测「周三」「周四」都不在里面），单独拦。
            if word.allSatisfy({ numeralChars.contains($0) || timeUnitChars.contains($0) }) { return false }
            if let first = word.first, edgeBlockedStart.contains(first) { return false }
            if let last = word.last, edgeBlockedEnd.contains(last) { return false }
            // 系统中文词典里就有的是常用词：识别本来就认得，加成热词只会添乱
            if chineseEmbedding?.contains(word) == true { return false }
            return true
        }

        // 含英文：总长不超过 30（官方英文热词上限 30 个字母）
        guard word.count <= 30, hasLatin || cjkCount > 0 else { return false }
        // 纯小写的单个英文常用词（for、code…）不学；品牌写法（Claude、OpenWiki、GitHub）照学
        if !word.contains(" "), cjkCount == 0, word == word.lowercased(),
           englishEmbedding?.contains(word) == true {
            return false
        }
        return true
    }

    /// 把「改动处」扩成完整的词。纠错提取为了区分度只多带一两个字，常常是半截：
    /// 「况思远 → 邝思远」提取出来是「了邝」，「尹俊文 → 殷俊文」是「殷俊」。当热词必须是完整的词。
    /// 做法（系统自带的中文分词和实体识别，2026-09-23 实测人名能整名认出）：
    /// 1. 改动处落在人名 / 地名 / 机构名里，就取整个名字；
    /// 2. 否则取覆盖改动处的分词结果（「Claude Code」「小肚」）；
    /// 3. 两头的虚词去掉（「了邝」→「邝」，单字随后会被选词规则拒掉）。
    public static func expandToWord(_ target: String, in sentence: String) -> String {
        expand(target, in: sentence).word
    }

    public struct ExpandedWord {
        public let word: String
        /// 系统实体识别认出这是人名 / 地名 / 机构名
        public let isNamedEntity: Bool
    }

    /// 同 expandToWord，另外告诉调用方这个词是不是专名（人名 / 地名 / 机构名）。
    public static func expand(_ target: String, in sentence: String) -> ExpandedWord {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let range = sentence.range(of: trimmed) else { return ExpandedWord(word: trimmed, isNamedEntity: false) }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = sentence
        var entity: Range<String.Index>?
        tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, r in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag), r.overlaps(range) {
                entity = r
                return false
            }
            return true
        }
        if let entity { return ExpandedWord(word: String(sentence[entity]), isNamedEntity: true) }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentence
        var lower = range.lowerBound, upper = range.upperBound
        tokenizer.enumerateTokens(in: sentence.startIndex..<sentence.endIndex) { r, _ in
            if r.overlaps(range) {
                lower = min(lower, r.lowerBound)
                upper = max(upper, r.upperBound)
            }
            return r.lowerBound < range.upperBound
        }
        var word = String(sentence[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
        while let f = word.first, edgeBlockedStart.contains(f) { word.removeFirst() }
        while let l = word.last, edgeBlockedEnd.contains(l) { word.removeLast() }
        return ExpandedWord(word: word, isNamedEntity: false)
    }

    /// 这一版输入框内容是不是「正在打拼音、还没确认」的中间状态：里面有一串英文字母，
    /// 既不在出字原文里、也不在最终文字里（「我打算和lv俊梅去吃个饭」）。这种版本不能拿来学，否则会学进「lv」。
    public static func looksLikeComposition(_ snapshot: String, delivered: String, final: String) -> Bool {
        let runs = asciiLetterRuns(snapshot)
        guard !runs.isEmpty else { return false }
        let known = Set(asciiLetterRuns(delivered) + asciiLetterRuns(final))
        return runs.contains { !known.contains($0) }
    }

    private static func asciiLetterRuns(_ s: String) -> [String] {
        var runs: [String] = [], cur = ""
        for u in s.unicodeScalars {
            if (65...90).contains(u.value) || (97...122).contains(u.value) { cur.unicodeScalars.append(u) }
            else if !cur.isEmpty { runs.append(cur.lowercased()); cur = "" }
        }
        if !cur.isEmpty { runs.append(cur.lowercased()) }
        return runs
    }

    /// 这处修改该不该学（自动学词用）：
    /// - 读音相近（MishearingCheck）→ 学，这是典型的「听错了」；
    /// - 读音规则判不像，但改的是人名 / 地名 / 机构名，或含英文的词 → 也学。
    ///   2026-09-23 Ray 实测：「李俊梅 → 吕俊梅」只改了一个字，lǐ / lǚ 读音规则判不像，以前直接当「改内容」跳过；
    ///   Typeless 同样的改法会学。改名字、改品牌写法几乎都是在纠正识别，不是改内容。
    /// - 其余读音不像的（「周四 → 周三」）是在改内容，不学。
    public static func shouldLearn(variant: String, target: String, in sentence: String) -> Bool {
        if MishearingCheck.isLikelyMishearing(old: variant, new: target) { return true }
        let expanded = expand(target, in: sentence)
        let hasLatin = expanded.word.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        return expanded.isNamedEntity || hasLatin
    }

    static let numeralChars: Set<Character> = Set("零〇一二三四五六七八九十百千万亿两几半0123456789")
    static let timeUnitChars: Set<Character> = Set("点分秒号月日年周天个岁次元块毛角时刻星期礼拜")

    /// 专名几乎不会以这些字开头 / 结尾；出现了多半是改字时带进来的半截词（「么法」「说无」）
    static let edgeBlockedStart: Set<Character> = Set("么的了着过吗呢吧啊呀哦嗯就也都还又很太更最被把给让说和与或而且但")
    static let edgeBlockedEnd: Set<Character> = Set("的了着过吗呢吧啊呀哦嗯么们和与或")

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value)
    }

    private static let chineseEmbedding: NLEmbedding? = NLEmbedding.wordEmbedding(for: .simplifiedChinese)
    private static let englishEmbedding: NLEmbedding? = NLEmbedding.wordEmbedding(for: .english)

    // MARK: - 加词 / 限量 / 撤销（纯函数，便于测试）

    public struct Update {
        public var entries: [[String: Any]]
        public var ledger: [[String: String]]
        /// 这次新加进词库的词（弹「已加入词库」提示用）
        public var added: [String]
        /// 因超过上限被挤出去的老词
        public var evicted: [String]
        /// 更新后的「不再学」名单（含这次发现的、用户在词库页删掉的学到的词）
        public var dismissed: [String]
    }

    /// 把一批学到的词加进词库。已在词库里的词不重复加（若是以前学到的，刷新日期让它晚点被挤掉）。
    public static func addLearnedWords(_ words: [String],
                                       entries: [[String: Any]],
                                       ledger: [[String: String]],
                                       dismissed: [String] = [],
                                       today: String,
                                       cap: Int = maxLearnedWords) -> Update {
        var entries = entries
        // 账本里有、词库里却没了 = 用户在词库页删掉了：记进「不再学」
        var dismissed = dismissed
        for word in deletedLearnedWords(ledger: ledger, entries: entries)
        where !dismissed.contains(where: { $0.lowercased() == word.lowercased() }) {
            dismissed.append(word)
        }
        let dismissedKeys = Set(dismissed.map { $0.lowercased() })
        var ledger = pruneLedger(ledger, entries: entries)
        var added: [String] = []

        var seen = Set<String>()
        for raw in words {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = word.lowercased()
            guard !word.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            guard !dismissedKeys.contains(key) else { continue }   // 用户删过 / 撤销过的，不再学

            if entries.contains(where: { target(of: $0)?.lowercased() == key }) {
                if let i = ledger.firstIndex(where: { $0["word"]?.lowercased() == key }) {
                    ledger[i]["learned_at"] = today
                }
                continue
            }
            entries.append(["target": word, "variants": [String](), "category": "其他", "source": "auto"])
            ledger.append(["word": word, "learned_at": today])
            added.append(word)
        }

        var evicted: [String] = []
        while ledger.count > cap {
            // 最早学到的先让位；这次刚加的不挤
            let candidates = ledger.enumerated().filter { !added.contains($0.element["word"] ?? "") }
            guard let oldest = candidates.min(by: { ($0.element["learned_at"] ?? "", $0.offset) < ($1.element["learned_at"] ?? "", $1.offset) }) else { break }
            let word = oldest.element["word"] ?? ""
            ledger.remove(at: oldest.offset)
            entries.removeAll { isLearnedEntry($0, word: word) }
            evicted.append(word)
        }
        return Update(entries: entries, ledger: ledger, added: added, evicted: evicted, dismissed: dismissed)
    }

    /// 撤销：只删账本里有的、而且仍是「自动 + 无错法」的词条；用户手动加的同名词不动。
    /// 只管这一次，不进「不再学」名单：下次再改同样的错还会学（Ray 2026-09-23 拍板）。
    public static func removeLearnedWords(_ words: [String],
                                          entries: [[String: Any]],
                                          ledger: [[String: String]]) -> (entries: [[String: Any]], ledger: [[String: String]], removed: [String]) {
        var entries = entries
        var ledger = ledger
        var removed: [String] = []
        for raw in words {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let i = ledger.firstIndex(where: { $0["word"]?.lowercased() == key }) else { continue }
            let word = ledger[i]["word"] ?? raw
            ledger.remove(at: i)
            let before = entries.count
            entries.removeAll { isLearnedEntry($0, word: word) }
            if entries.count < before { removed.append(word) }
        }
        return (entries, ledger, removed)
    }

    /// 账本里有、词库里已经没有的学到的词（用户在词库页删掉了）
    static func deletedLearnedWords(ledger: [[String: String]], entries: [[String: Any]]) -> [String] {
        ledger.compactMap { item in
            guard let word = item["word"], !entries.contains(where: { isLearnedEntry($0, word: word) }) else { return nil }
            return word
        }
    }

    /// 账本里的词如果已经不在词库里（用户在词库页删了），账本也跟着删
    static func pruneLedger(_ ledger: [[String: String]], entries: [[String: Any]]) -> [[String: String]] {
        ledger.filter { item in
            guard let word = item["word"] else { return false }
            return entries.contains { isLearnedEntry($0, word: word) }
        }
    }

    private static func target(of entry: [String: Any]) -> String? {
        (entry["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLearnedEntry(_ entry: [String: Any], word: String) -> Bool {
        guard target(of: entry)?.lowercased() == word.lowercased() else { return false }
        let variants = entry["variants"] as? [String] ?? []
        return (entry["source"] as? String) == "auto" && variants.isEmpty
    }

    public static func dayString(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
