import Foundation

// 本地改动：首页「洞察」的纯计算：三张指标（累计口述字数 / 平均口述速度 / 总口述时间）的数值与格式化，
// 以及热力图的格子排布（按周分列、月份标签、深浅档）。只吃 InputStats 的日记录，便于测试；日期一律 "yyyy-MM-dd"。
public enum DictationInsights {
    /// 一段「数字 + 单位」，界面上数字大号、单位小号。如 ("13", "小时")。
    public struct ValuePart: Equatable {
        public let value: String
        public let unit: String
        public init(_ value: String, _ unit: String) { self.value = value; self.unit = unit }
    }

    public struct Totals: Equatable {
        public let chars: Int             // 有史以来口述字数
        public let durationMs: Int        // 有时长数据的日子累计录音时长
        public let speedPerMinute: Int?   // 每分钟字数；没有任何时长数据为 nil
    }

    /// 速度只用有时长的日子：字数 / 分钟数（老记录没有时长，算进去会把速度虚高）。
    public static func totals(records: [DailyRecord]) -> Totals {
        let chars = records.reduce(0) { $0 + $1.charCount }
        let timed = records.filter { $0.durationMs > 0 }
        let ms = timed.reduce(0) { $0 + $1.durationMs }
        let timedChars = timed.reduce(0) { $0 + $1.charCount }
        let speed: Int? = ms > 0 ? Int((Double(timedChars) / (Double(ms) / 60_000)).rounded()) : nil
        return Totals(chars: chars, durationMs: ms, speedPerMinute: speed)
    }

    /// 字数紧凑写法：不到 1 万照常带千分位；≥1 万写 x.xK；≥100 万写 x.xM（末尾 .0 省掉）。
    public static func compactCount(_ n: Int) -> String {
        func oneDecimal(_ v: Double) -> String {
            let r = (v * 10).rounded() / 10
            return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
        }
        if n < 10_000 {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.locale = Locale(identifier: "en_US_POSIX")
            f.usesGroupingSeparator = true
            f.groupingSeparator = ","
            return f.string(from: NSNumber(value: n)) ?? "\(n)"
        }
        let k = Double(n) / 1000
        if n < 1_000_000 && (k * 10).rounded() / 10 < 1000 { return oneDecimal(k) + "K" }
        return oneDecimal(Double(n) / 1_000_000) + "M"
    }

    /// 总口述时间：≥1 小时「H 小时 M 分钟」（整点只写小时）；≥1 分钟「N 分钟」；更短「N 秒」。
    public static func durationParts(ms: Int) -> [ValuePart] {
        let seconds = max(0, ms) / 1000
        if seconds < 60 { return [ValuePart("\(seconds)", "秒")] }
        let minutes = seconds / 60
        if minutes < 60 { return [ValuePart("\(minutes)", "分钟")] }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? [ValuePart("\(h)", "小时")] : [ValuePart("\(h)", "小时"), ValuePart("\(m)", "分钟")]
    }

    /// 回填用：把历史记录按天汇总录音时长。entries 为 (time "yyyy-MM-dd HH:mm:ss", 录音毫秒)；
    /// 只有当天有时长的条数 ≥ 日统计里的次数（历史覆盖了当天全部输入）才给这天的值，
    /// 否则时长只覆盖一部分输入，速度会被算高，宁可这天不计。
    public static func durationsByDay(entries: [(time: String, durationMs: Int)],
                                      records: [DailyRecord]) -> [String: Int] {
        var sum: [String: Int] = [:], count: [String: Int] = [:]
        for e in entries where e.durationMs > 0 && e.time.count >= 10 {
            let day = String(e.time.prefix(10))
            sum[day, default: 0] += e.durationMs
            count[day, default: 0] += 1
        }
        var out: [String: Int] = [:]
        for r in records where r.charCount > 0 {
            if let s = sum[r.date], (count[r.date] ?? 0) >= r.sessionCount { out[r.date] = s }
        }
        return out
    }
}

/// 本地改动：首页「洞察」热力图（GitHub 式）：每列一周、每行一个星期几，最新一周在最右。
/// 周起点跟随 App 统一的「周一起算」（InputStats 周统计同口径），行从上到下为 一 … 日。
public struct ActivityHeatmap: Equatable {
    public struct Cell: Equatable {
        public let date: String
        public let chars: Int
        public let level: Int        // 0 = 没用；1…4 深浅档（见 ActivityRhythm.intensityLevel）
        public let isFuture: Bool    // 本周还没到的日子：画空心格
        public let isToday: Bool
    }

    public struct MonthLabel: Equatable {
        public let column: Int
        public let text: String
    }

    public let columns: [[Cell]]          // 从早到晚，每列 7 格
    public let monthLabels: [MonthLabel]
    public let maxChars: Int              // 窗口内（不含未来）单日最多字数
    public let hasEarlier: Bool           // 窗口之前还有使用记录（可往前翻页）

    public static let monthNames = ["一月", "二月", "三月", "四月", "五月", "六月",
                                    "七月", "八月", "九月", "十月", "十一月", "十二月"]

    /// 行标签：周一起算 → 一 二 三 四 五 六 日
    public static func weekdayLabels(firstWeekday: Int = 2) -> [String] {
        let names = ["日", "一", "二", "三", "四", "五", "六"]   // 下标 0 = 周日（Calendar weekday 1）
        return (0..<7).map { names[(firstWeekday - 1 + $0) % 7] }
    }

    /// 在给定宽度里能放几列：格子最小 minCell、间距 gap，最多 maxColumns 列，至少 1 列。
    public static func columnsThatFit(width: CGFloat, minCell: CGFloat, gap: CGFloat, maxColumns: Int) -> Int {
        guard width > 0 else { return 1 }
        let n = Int((width + gap) / (minCell + gap))
        return max(1, min(maxColumns, n))
    }

    /// - Parameters:
    ///   - weeks: 显示几列（周）
    ///   - pageOffset: 往前翻了几页（每页 weeks 周），0 = 最新一页
    public static func compute(records: [DailyRecord], today: Date = Date(), weeks: Int, pageOffset: Int = 0,
                               firstWeekday: Int = 2, calendar: Calendar = .current) -> ActivityHeatmap {
        var cal = calendar
        cal.firstWeekday = firstWeekday
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = cal
        f.timeZone = cal.timeZone

        var byDate: [String: Int] = [:]
        for r in records { byDate[r.date, default: 0] += r.charCount }

        let todayStart = cal.startOfDay(for: today)
        let todayKey = f.string(from: todayStart)
        guard weeks > 0, let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: todayStart)?.start,
              let lastColStart = cal.date(byAdding: .day, value: -7 * weeks * max(0, pageOffset), to: thisWeekStart),
              let firstColStart = cal.date(byAdding: .day, value: -7 * (weeks - 1), to: lastColStart)
        else { return ActivityHeatmap(columns: [], monthLabels: [], maxChars: 0, hasEarlier: false) }

        // 先收集原始格子，再按窗口最大值分档
        var raw: [[(date: Date, key: String, chars: Int, future: Bool)]] = []
        for w in 0..<weeks {
            var col: [(Date, String, Int, Bool)] = []
            for d in 0..<7 {
                guard let day = cal.date(byAdding: .day, value: 7 * w + d, to: firstColStart) else { continue }
                let key = f.string(from: day)
                let future = day > todayStart
                col.append((day, key, future ? 0 : (byDate[key] ?? 0), future))
            }
            raw.append(col)
        }
        let maxChars = raw.flatMap { $0 }.map(\.2).max() ?? 0
        let columns = raw.map { col in
            col.map { c in
                Cell(date: c.1, chars: c.2, level: ActivityRhythm.intensityLevel(chars: c.2, maxChars: maxChars),
                     isFuture: c.3, isToday: c.1 == todayKey)
            }
        }

        // 月份标签：某列里有当月 1 号，就在这一列下面写这个月；
        // 第一列没有 1 号时补写它所在的月份（离下一个标签至少 3 列才写，免得挤在一起）
        var labels: [MonthLabel] = []
        for (i, col) in raw.enumerated() {
            if let first = col.first(where: { cal.component(.day, from: $0.0) == 1 }) {
                labels.append(MonthLabel(column: i, text: monthNames[cal.component(.month, from: first.0) - 1]))
            }
        }
        if let top = raw.first?.first, (labels.first?.column ?? Int.max) >= 3 {
            labels.insert(MonthLabel(column: 0, text: monthNames[cal.component(.month, from: top.0) - 1]), at: 0)
        }

        let firstKey = f.string(from: firstColStart)
        let hasEarlier = byDate.contains { $0.key < firstKey && $0.value > 0 }
        return ActivityHeatmap(columns: columns, monthLabels: labels, maxChars: maxChars, hasEarlier: hasEarlier)
    }
}
