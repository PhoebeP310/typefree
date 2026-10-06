import Foundation

// 本地改动：词库页「自动同步的热词」的纯逻辑：按 hot_words_groups 分组（没归组的进「其他」）、
// 按词库页筛选（所有 / 自动学习 / 手动添加）过滤、删词时同步改 hot_words / hot_words_groups / hot_words_blocked。
// hot_words 和 hot_words_groups 由外部脚本每周写入；hot_words_blocked 由 App 写，脚本不会把里面的词加回来。
// 比较一律忽略大小写和首尾空白（与脚本的 norm = strip().casefold() 同口径）。
public enum SyncedHotWords {
    public static let hotWordsKey = "hot_words"
    public static let groupsKey = "hot_words_groups"
    public static let blockedKey = "hot_words_blocked"

    public static let manualGroup = "手动添加"
    public static let otherGroup = "其他"
    /// 脚本写分组的顺序；JSON 对象读进来顺序会丢，按这个排，不认识的组名按名字排在后面，「其他」永远最后
    public static let knownGroupOrder = ["手动添加", "识别纠错", "业务词", "同事", "会议里发现的同事"]

    public struct Group: Equatable {
        public let name: String
        public let words: [String]
        public init(name: String, words: [String]) { self.name = name; self.words = words }
    }

    /// 词库页筛选，与分段控件下标一致：0 = 所有，1 = 自动学习，2 = 手动添加
    public enum Filter: Int {
        case all = 0, autoLearned = 1, manual = 2
    }

    static func norm(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 去首尾空白、去空、忽略大小写去重（保留第一次出现的写法）
    public static func dedupe(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in words {
            let w = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty, seen.insert(norm(w)).inserted else { continue }
            out.append(w)
        }
        return out
    }

    /// 以 hot_words 为准分组：分组里有但 hot_words 里没有的词不显示；hot_words 里有但没进任何组的词归「其他」。
    /// 一个词出现在多个组时只算第一个组（按 knownGroupOrder）。词的写法取 hot_words 里的。
    public static func groups(hotWords: [String], groupMap: [String: [String]]?) -> [Group] {
        let words = dedupe(hotWords)
        var casing: [String: String] = [:]
        for w in words { casing[norm(w)] = w }

        let map = groupMap ?? [:]
        let known = knownGroupOrder.filter { map[$0] != nil }
        let unknown = map.keys.filter { !knownGroupOrder.contains($0) && $0 != otherGroup }.sorted()

        var assigned = Set<String>()
        var result: [Group] = []
        for name in known + unknown {
            var members: [String] = []
            for raw in map[name] ?? [] {
                let key = norm(raw)
                guard let w = casing[key], !assigned.contains(key) else { continue }
                assigned.insert(key)
                members.append(w)
            }
            if !members.isEmpty { result.append(Group(name: name, words: members)) }
        }
        let rest = words.filter { !assigned.contains(norm($0)) }
        if !rest.isEmpty { result.append(Group(name: otherGroup, words: rest)) }
        return result
    }

    /// 按筛选和搜索词过滤分组（query 为空不过滤，忽略大小写的子串匹配）；过滤后为空的组去掉。
    public static func filter(_ groups: [Group], by filter: Filter, query: String? = nil) -> [Group] {
        let q = query.map(norm) ?? ""
        return groups.compactMap { g in
            switch filter {
            case .all: break
            case .autoLearned: if g.name == manualGroup { return nil }
            case .manual: if g.name != manualGroup { return nil }
            }
            let words = q.isEmpty ? g.words : g.words.filter { norm($0).contains(q) }
            return words.isEmpty ? nil : Group(name: g.name, words: words)
        }
    }

    /// 本地改动：去掉已经是词库词条（term_corrections 的 target）的热词，免得同一个词在页面上出现两次；
    /// 去完为空的组一并去掉。比较忽略大小写和首尾空白。
    public static func excluding(_ groups: [Group], terms: [String]) -> [Group] {
        let taken = Set(terms.map(norm).filter { !$0.isEmpty })
        guard !taken.isEmpty else { return groups }
        return groups.compactMap { g in
            let words = g.words.filter { !taken.contains(norm($0)) }
            return words.isEmpty ? nil : Group(name: g.name, words: words)
        }
    }

    public struct BlockResult: Equatable {
        public let hotWords: [String]
        public let groups: [String: [String]]?
        public let blocked: [String]
    }

    /// 删一个热词：从 hot_words 和所有分组里拿掉（忽略大小写），删空的组一并去掉；
    /// 记进屏蔽表（忽略大小写去重）。groupMap 原本为 nil 时结果也保持 nil，不凭空写这个键。
    public static func block(_ word: String, hotWords: [String], groupMap: [String: [String]]?,
                             blocked: [String]) -> BlockResult {
        let key = norm(word)
        let newWords = hotWords.filter { norm($0) != key }
        let newGroups = groupMap.map { map -> [String: [String]] in
            var out: [String: [String]] = [:]
            for (name, ws) in map {
                let kept = ws.filter { norm($0) != key }
                if !kept.isEmpty { out[name] = kept }
            }
            return out
        }
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let newBlocked = trimmed.isEmpty ? dedupe(blocked) : dedupe(blocked + [trimmed])
        return BlockResult(hotWords: newWords, groups: newGroups, blocked: newBlocked)
    }

    /// 从屏蔽表里移除一个词（忽略大小写），下次同步脚本就可能把它加回来。
    public static func unblock(_ word: String, blocked: [String]) -> [String] {
        let key = norm(word)
        return dedupe(blocked).filter { norm($0) != key }
    }

    /// 读 config 里这三个键，算出删词后要写回的值（直接交给 VoicePolishConfig.save(values:)）。
    public static func blockValues(_ word: String, config json: [String: Any]) -> [String: Any] {
        let r = block(word,
                      hotWords: json[hotWordsKey] as? [String] ?? [],
                      groupMap: json[groupsKey] as? [String: [String]],
                      blocked: json[blockedKey] as? [String] ?? [])
        var values: [String: Any] = [hotWordsKey: r.hotWords, blockedKey: r.blocked]
        if let g = r.groups { values[groupsKey] = g }
        return values
    }
}
