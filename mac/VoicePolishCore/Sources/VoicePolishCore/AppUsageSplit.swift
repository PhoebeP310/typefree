import Foundation

// 本地改动：首页「今日按应用 / 本周按应用」卡片的数据。
/// 纯函数：把历史记录按前台应用汇总字数，取前 N 个，其余合并成「其他」。
/// 每条字数口径与 InputStats 一致：用交付文字 output 的字数，output 为空时退回识别原文 asr。
public enum AppUsageSplit {
    public struct Slice: Equatable {
        public let app: String
        public let chars: Int
        public init(app: String, chars: Int) {
            self.app = app
            self.chars = chars
        }
    }

    public static let otherName = "其他"
    public static let unknownName = "未知应用"

    /// - Parameters:
    ///   - entries: 历史记录（time 为 "yyyy-MM-dd HH:mm:ss"）
    ///   - from / to: 闭区间日期 "yyyy-MM-dd"
    ///   - top: 单独列出的应用个数，超出部分合并成「其他」
    /// - Returns: 按字数从多到少；「其他」固定排最后；没有数据返回空数组
    public static func compute(entries: [AIPolisher.PolishLog], from: String, to: String,
                               top: Int = 4) -> [Slice] {
        var byApp: [String: Int] = [:]
        for e in entries {
            if e.kind == "ask" { continue }                 // 问 AI 已下线，不计
            let day = String(e.time.prefix(10))
            guard day >= from, day <= to else { continue }
            let text = e.output.isEmpty ? e.asr : e.output
            let chars = text.count
            guard chars > 0 else { continue }
            let name = e.app.trimmingCharacters(in: .whitespacesAndNewlines)
            byApp[name.isEmpty ? unknownName : name, default: 0] += chars
        }
        let sorted = byApp.map { Slice(app: $0.key, chars: $0.value) }
            .sorted { $0.chars != $1.chars ? $0.chars > $1.chars : $0.app < $1.app }
        guard sorted.count > top else { return sorted }
        let rest = sorted.dropFirst(top).reduce(0) { $0 + $1.chars }
        return Array(sorted.prefix(top)) + [Slice(app: otherName, chars: rest)]
    }
}
