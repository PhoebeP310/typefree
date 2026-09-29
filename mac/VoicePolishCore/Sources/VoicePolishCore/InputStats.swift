import Foundation

public struct DailyRecord: Codable, Equatable {
    public let date: String        // "2026-03-30"
    public var charCount: Int
    public var sessionCount: Int
    /// 其中计入免费周额度的字数：未买断 + 自带 Key 的交付。
    /// 试用期走代理（用官方 Key）的交付只进 charCount，不进这里——否则试用刚结束
    /// 切自带 Key 时，试用期说的字会把整周免费额度直接吃光。
    public var quotaCharCount: Int

    public init(date: String, charCount: Int = 0, sessionCount: Int = 0, quotaCharCount: Int = 0) {
        self.date = date
        self.charCount = charCount
        self.sessionCount = sessionCount
        self.quotaCharCount = quotaCharCount
    }

    /// 旧版统计文件没有 quotaCharCount 字段 → 按 0 处理（老记录不占额度，升级后本周从零起算）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        charCount = try c.decode(Int.self, forKey: .charCount)
        sessionCount = try c.decode(Int.self, forKey: .sessionCount)
        quotaCharCount = try c.decodeIfPresent(Int.self, forKey: .quotaCharCount) ?? 0
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
    public func record(charCount: Int, countsTowardFreeQuota: Bool = false) {
        guard charCount > 0 else { return }
        var records = loadRecords()
        let todayStr = dateFormatter.string(from: Date())

        if let index = records.firstIndex(where: { $0.date == todayStr }) {
            records[index].charCount += charCount
            records[index].sessionCount += 1
            if countsTowardFreeQuota { records[index].quotaCharCount += charCount }
        } else {
            records.append(DailyRecord(date: todayStr, charCount: charCount, sessionCount: 1,
                                       quotaCharCount: countsTowardFreeQuota ? charCount : 0))
        }

        saveRecords(records)
    }

    // MARK: - 查询

    public func today() -> DailyRecord {
        let todayStr = dateFormatter.string(from: Date())
        return loadRecords().first(where: { $0.date == todayStr })
            ?? DailyRecord(date: todayStr)
    }

    /// 本周一的 "yyyy-MM-dd"。固定周一起算，不随系统地区设置漂移（免费周额度按此重置）。
    private func currentWeekStartString() -> String? {
        var cal = Calendar.current
        cal.firstWeekday = 2
        guard let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start else { return nil }
        return dateFormatter.string(from: weekStart)
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
