import Foundation

/// 首页「节律」卡片的数据：近 N 天每天的字数（没用的日子补 0）、连续天数、活跃天数、最常在周几用。
/// 纯函数，只吃 InputStats 的日记录，便于测试；日期一律 "yyyy-MM-dd"。
public struct ActivityRhythm: Equatable {
    public struct Day: Equatable {
        public let date: String
        public let chars: Int
        public let sessions: Int
        public let weekday: Int      // 1 = 周日 … 7 = 周六（Calendar 口径）
        public let isToday: Bool
    }

    public let days: [Day]           // 从早到晚，最后一个是今天
    public let currentStreak: Int    // 截至今天连续使用了多少天（今天没用则从昨天往前数）
    public let bestStreak: Int       // 有史以来最长连续
    public let activeDays: Int       // 有史以来用过的天数
    public let busiestWeekday: Int?  // 近 8 周字数最多的周几（1=周日…7=周六）；没数据为 nil

    public static let weekdayNames = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    // 本地改动：节律圆点按字数分深浅档。0 = 没用（空心小圈），1…4 = 相对窗口内最多那天的比例，
    // 阈值 0.25 / 0.5 / 0.75（≤0.25 为 1 档，>0.75 为 4 档）。
    public static func intensityLevel(chars: Int, maxChars: Int) -> Int {
        guard chars > 0, maxChars > 0 else { return 0 }
        let r = Double(chars) / Double(maxChars)
        if r > 0.75 { return 4 }
        if r > 0.5 { return 3 }
        if r > 0.25 { return 2 }
        return 1
    }

    public static func compute(records: [DailyRecord], today: Date = Date(), days: Int = 42,
                               calendar: Calendar = .current) -> ActivityRhythm {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        let byDate = Dictionary(records.map { ($0.date, $0) }, uniquingKeysWith: { a, b in
            DailyRecord(date: a.date, charCount: a.charCount + b.charCount, sessionCount: a.sessionCount + b.sessionCount,
                        quotaCharCount: a.quotaCharCount + b.quotaCharCount)
        })
        let todayStart = calendar.startOfDay(for: today)

        var list: [Day] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let d = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            let key = f.string(from: d)
            let r = byDate[key]
            list.append(Day(date: key, chars: r?.charCount ?? 0, sessions: r?.sessionCount ?? 0,
                            weekday: calendar.component(.weekday, from: d), isToday: offset == 0))
        }

        // 连续天数：今天用过从今天数，没用过从昨天数（今天还没到晚上，不算断）
        var current = 0
        var cursor = todayStart
        if (byDate[f.string(from: cursor)]?.charCount ?? 0) == 0 {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while (byDate[f.string(from: cursor)]?.charCount ?? 0) > 0 {
            current += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }

        // 最长连续：按日期排序后找相邻天
        let activeDates = byDate.values.filter { $0.charCount > 0 }.map(\.date).sorted()
        var best = 0, run = 0
        var prevDate: Date?
        for key in activeDates {
            guard let d = f.date(from: key) else { continue }
            if let p = prevDate, let next = calendar.date(byAdding: .day, value: 1, to: p),
               calendar.isDate(next, inSameDayAs: d) {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            prevDate = d
        }

        // 最常在周几：近 8 周按周几累加
        var byWeekday = [Int](repeating: 0, count: 8)
        for offset in 0..<56 {
            guard let d = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            let chars = byDate[f.string(from: d)]?.charCount ?? 0
            byWeekday[calendar.component(.weekday, from: d)] += chars
        }
        let maxChars = byWeekday.max() ?? 0
        let busiest = maxChars > 0 ? byWeekday.firstIndex(of: maxChars) : nil

        return ActivityRhythm(days: list, currentStreak: current, bestStreak: best,
                              activeDays: activeDates.count, busiestWeekday: busiest)
    }
}
