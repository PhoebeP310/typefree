import Foundation

public struct DailyRecord: Codable, Equatable {
    public let date: String        // "2026-03-30"
    public var charCount: Int
    public var sessionCount: Int
    /// 其中计入免费周额度的字数：未买断 + 自带 Key 的交付。
    /// 试用期走代理（用官方 Key）的交付只进 charCount，不进这里——否则试用刚结束
    /// 切自带 Key 时，试用期说的字会把整周免费额度直接吃光。
    public var quotaCharCount: Int
    // 本地改动：当天累计录音时长（毫秒），首页「洞察」算总口述时间 / 平均口述速度用。
    // 记在日统计里而不是从历史现算，历史保留期改短也不影响累计。0 = 当天没有时长数据（老记录）。
    public var durationMs: Int

    public init(date: String, charCount: Int = 0, sessionCount: Int = 0, quotaCharCount: Int = 0, durationMs: Int = 0) {
        self.date = date
        self.charCount = charCount
        self.sessionCount = sessionCount
        self.quotaCharCount = quotaCharCount
        self.durationMs = durationMs
    }

    /// 旧版统计文件没有 quotaCharCount 字段 → 按 0 处理（老记录不占额度，升级后本周从零起算）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        charCount = try c.decode(Int.self, forKey: .charCount)
        sessionCount = try c.decode(Int.self, forKey: .sessionCount)
        quotaCharCount = try c.decodeIfPresent(Int.self, forKey: .quotaCharCount) ?? 0
        // 本地改动：旧文件没有 durationMs → 0（启动时由历史记录一次性回填）
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
    }
}

public struct StatsPeriod {
    public let label: String       // "今天" / "3月29日" / "2026年1月"
    public let charCount: Int
    public let sessionCount: Int

    public init(label: String, charCount: Int, sessionCount: Int) {
        self.label = label
        self.charCount = charCount
        self.sessionCount = sessionCount
    }
}

public final class InputStats {
    public static let shared = InputStats()

    private let fileURL: URL?
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            #if os(iOS)
            self.fileURL = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: "group.com.voicepolish.shared")?
                .appendingPathComponent("input_stats.json")
            #else
            // 跟配置目录走（默认 ~/.config/voicepolish，写不进时 VoicePolishConfig 会退到 Application Support）
            let configDir = VoicePolishConfig.shared.configDirectoryURL
            try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            self.fileURL = configDir.appendingPathComponent("input_stats.json")
            #endif
        }
    }

    // MARK: - 记录

    /// - Parameter countsTowardFreeQuota: 本次交付是否计入免费周额度
    ///   （仅未买断 + 自带 Key 的交付传 true；试用期走代理的交付传 false）。
    /// - Parameter durationMs: 本次录音时长（毫秒），本地改动：累加进当天的 durationMs
    public func record(charCount: Int, durationMs: Int = 0, countsTowardFreeQuota: Bool = false) {
        guard charCount > 0 else { return }
        var records = loadRecords()
        let todayStr = dateFormatter.string(from: Date())
        let dur = max(0, durationMs)

        if let index = records.firstIndex(where: { $0.date == todayStr }) {
            records[index].charCount += charCount
            records[index].sessionCount += 1
            records[index].durationMs += dur
            if countsTowardFreeQuota { records[index].quotaCharCount += charCount }
        } else {
            records.append(DailyRecord(date: todayStr, charCount: charCount, sessionCount: 1,
                                       quotaCharCount: countsTowardFreeQuota ? charCount : 0, durationMs: dur))
        }

        saveRecords(records)
    }

    // 本地改动：老记录没有录音时长，启动时按历史记录回填一次（只填 durationMs 为 0 的日子）
    public func backfillDurations(_ durationsByDay: [String: Int]) {
        let records = loadRecords()
        let filled = Self.backfilled(records: records, durationsByDay: durationsByDay)
        if filled != records { saveRecords(filled) }
    }

    /// 纯函数版本：durationMs 为 0 的日子用 durationsByDay 里的值补上，已有时长的日子不动。
    public static func backfilled(records: [DailyRecord], durationsByDay: [String: Int]) -> [DailyRecord] {
        records.map { r in
            guard r.durationMs == 0, let d = durationsByDay[r.date], d > 0 else { return r }
            var copy = r
            copy.durationMs = d
            return copy
        }
    }

    // MARK: - 查询

    public func today() -> DailyRecord {
        let todayStr = dateFormatter.string(from: Date())
        return loadRecords().first(where: { $0.date == todayStr })
            ?? DailyRecord(date: todayStr)
    }

    /// 本周一的 "yyyy-MM-dd"。固定周一起算，不随系统地区设置漂移（免费周额度按此重置）。
    // 本地改动：改为 public，首页「按应用」卡片按同一周起点筛历史记录
    public func currentWeekStartString() -> String? {
        Self.weekStartString(for: Date(), calendar: .current)
    }

    // 本地改动：周起点抽成静态函数，「上周同期」与本周共用同一套周一起算规则
    static func weekStartString(for date: Date, calendar: Calendar) -> String? {
        var cal = calendar
        cal.firstWeekday = 2
        guard let weekStart = cal.dateInterval(of: .weekOfYear, for: date)?.start else { return nil }
        return dayKeyFormatter(cal).string(from: weekStart)
    }

    private static func dayKeyFormatter(_ cal: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = cal
        f.timeZone = cal.timeZone
        return f
    }

    // 本地改动：上周同期 = 上周一 至 上周里与今天同一个星期几（含当天），用来和本周至今对比
    public func lastWeekSamePeriodTotal(today: Date = Date()) -> (chars: Int, sessions: Int) {
        Self.lastWeekSamePeriodTotal(records: loadRecords(), today: today, calendar: .current)
    }

    /// 纯函数版本，便于测试：records 为日记录，today 决定「本周第几天」。
    public static func lastWeekSamePeriodTotal(records: [DailyRecord], today: Date,
                                               calendar: Calendar) -> (chars: Int, sessions: Int) {
        guard let thisStartStr = weekStartString(for: today, calendar: calendar) else { return (0, 0) }
        let f = dayKeyFormatter(calendar)
        guard let thisStart = f.date(from: thisStartStr),
              let lastStart = calendar.date(byAdding: .day, value: -7, to: thisStart),
              let lastSameDay = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: today))
        else { return (0, 0) }
        let from = f.string(from: lastStart), to = f.string(from: lastSameDay)
        let hit = records.filter { $0.date >= from && $0.date <= to }
        return (hit.reduce(0) { $0 + $1.charCount }, hit.reduce(0) { $0 + $1.sessionCount })
    }

    // 本地改动：「上周同期」卡片的副标题：本周至今 vs 上周同期
    public static func weekOverWeekText(current: Int, previous: Int) -> String {
        guard previous > 0 else { return "上周同期没有使用" }
        let pct = Int((Double(current - previous) / Double(previous) * 100).rounded())
        if pct > 0 { return "本周 ↑\(pct)%" }
        if pct < 0 { return "本周 ↓\(-pct)%" }
        return "本周持平"
    }

    public func currentWeekTotal() -> (chars: Int, sessions: Int) {
        guard let startStr = currentWeekStartString() else { return (0, 0) }
        let records = loadRecords().filter { $0.date >= startStr }
        return (records.reduce(0) { $0 + $1.charCount },
                records.reduce(0) { $0 + $1.sessionCount })
    }

    /// 本周（周一起）计入免费额度的字数：只含未买断 + 自带 Key 的交付，不含试用期用量。
    public func currentWeekQuotaChars() -> Int {
        guard let startStr = currentWeekStartString() else { return 0 }
        return loadRecords().filter { $0.date >= startStr }.reduce(0) { $0 + $1.quotaCharCount }
    }

    public func currentMonthTotal() -> (chars: Int, sessions: Int) {
        let cal = Calendar.current
        let now = Date()
        guard let monthStart = cal.dateInterval(of: .month, for: now)?.start else {
            return (0, 0)
        }
        let startStr = dateFormatter.string(from: monthStart)
        let records = loadRecords().filter { $0.date >= startStr }
        return (records.reduce(0) { $0 + $1.charCount },
                records.reduce(0) { $0 + $1.sessionCount })
    }

    /// 全部日记录（只读副本，给首页「节律」卡片算连续天数用）
    public func allDailyRecords() -> [DailyRecord] { loadRecords() }

    public func allTimeTotal() -> (chars: Int, sessions: Int) {
        let records = loadRecords()
        return (records.reduce(0) { $0 + $1.charCount },
                records.reduce(0) { $0 + $1.sessionCount })
    }

    public func periodsForDisplay() -> [StatsPeriod] {
        let records = loadRecords().sorted { $0.date > $1.date } // 最新在前
        let todayStr = dateFormatter.string(from: Date())
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        let cutoffStr = dateFormatter.string(from: cutoffDate)

        var periods: [StatsPeriod] = []

        // 最近 90 天按天显示
        let recentRecords = records.filter { $0.date >= cutoffStr }
        for record in recentRecords {
            let label: String
            if record.date == todayStr {
                label = "今天"
            } else {
                label = formatDayLabel(record.date)
            }
            periods.append(StatsPeriod(label: label, charCount: record.charCount, sessionCount: record.sessionCount))
        }

        // 更早的按月汇总
        let olderRecords = records.filter { $0.date < cutoffStr }
        var monthBuckets: [String: (chars: Int, sessions: Int)] = [:]
        for record in olderRecords {
            let monthKey = String(record.date.prefix(7)) // "2026-01"
            let existing = monthBuckets[monthKey] ?? (0, 0)
            monthBuckets[monthKey] = (existing.chars + record.charCount, existing.sessions + record.sessionCount)
        }
        for monthKey in monthBuckets.keys.sorted().reversed() {
            let bucket = monthBuckets[monthKey]!
            let label = formatMonthLabel(monthKey)
            periods.append(StatsPeriod(label: label, charCount: bucket.chars, sessionCount: bucket.sessions))
        }

        return periods
    }

    // MARK: - 格式化

    private func formatDayLabel(_ dateStr: String) -> String {
        guard let date = dateFormatter.date(from: dateStr) else { return dateStr }
        let display = DateFormatter()
        display.dateFormat = "M月d日"
        display.locale = Locale(identifier: "zh_CN")
        return display.string(from: date)
    }

    private func formatMonthLabel(_ monthKey: String) -> String {
        // "2026-01" → "2026年1月"
        let parts = monthKey.split(separator: "-")
        guard parts.count == 2, let year = parts.first, let month = Int(parts[1]) else {
            return monthKey
        }
        return "\(year)年\(month)月"
    }

    // MARK: - 存储

    private func loadRecords() -> [DailyRecord] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([DailyRecord].self, from: data)) ?? []
    }

    private func saveRecords(_ records: [DailyRecord]) {
        guard let fileURL else { return }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
