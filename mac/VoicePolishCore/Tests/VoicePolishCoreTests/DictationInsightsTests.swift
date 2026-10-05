import XCTest
@testable import VoicePolishCore

// 本地改动：首页「洞察」纯计算的测试
final class DictationInsightsTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone
        return f.date(from: s)!
    }

    func testCompactCount() {
        XCTAssertEqual(DictationInsights.compactCount(0), "0")
        XCTAssertEqual(DictationInsights.compactCount(9_999), "9,999")
        XCTAssertEqual(DictationInsights.compactCount(10_000), "10K")
        XCTAssertEqual(DictationInsights.compactCount(93_700), "93.7K")
        XCTAssertEqual(DictationInsights.compactCount(93_749), "93.7K")
        XCTAssertEqual(DictationInsights.compactCount(999_990), "1M", "四舍五入到 1000.0K 时改写成 M")
        XCTAssertEqual(DictationInsights.compactCount(1_250_000), "1.3M")
    }

    func testDurationParts() {
        XCTAssertEqual(DictationInsights.durationParts(ms: 0), [.init("0", "秒")])
        XCTAssertEqual(DictationInsights.durationParts(ms: 45_900), [.init("45", "秒")])
        XCTAssertEqual(DictationInsights.durationParts(ms: 61_000), [.init("1", "分钟")])
        XCTAssertEqual(DictationInsights.durationParts(ms: 3_600_000), [.init("1", "小时")])
        XCTAssertEqual(DictationInsights.durationParts(ms: (13 * 60 + 36) * 60_000 + 5_000), [.init("13", "小时"), .init("36", "分钟")])
    }

    func testTotalsSpeedOnlyUsesTimedDays() {
        let records = [
            DailyRecord(date: "2026-10-01", charCount: 1000, sessionCount: 5),                       // 老记录，无时长
            DailyRecord(date: "2026-10-02", charCount: 300, sessionCount: 2, durationMs: 120_000),  // 300 字 / 2 分钟
        ]
        let t = DictationInsights.totals(records: records)
        XCTAssertEqual(t.chars, 1300)
        XCTAssertEqual(t.durationMs, 120_000)
        XCTAssertEqual(t.speedPerMinute, 150)
        XCTAssertNil(DictationInsights.totals(records: [records[0]]).speedPerMinute)
    }

    func testDurationsByDayRequiresFullCoverage() {
        let records = [DailyRecord(date: "2026-10-03", charCount: 100, sessionCount: 2),
                       DailyRecord(date: "2026-10-04", charCount: 100, sessionCount: 2)]
        let entries: [(time: String, durationMs: Int)] = [
            ("2026-10-03 10:00:00", 5_000), ("2026-10-03 11:00:00", 7_000),
            ("2026-10-04 10:00:00", 9_000),                                 // 只覆盖一次，不计
            ("2026-10-04 11:00:00", 0),
        ]
        XCTAssertEqual(DictationInsights.durationsByDay(entries: entries, records: records), ["2026-10-03": 12_000])
    }

    func testBackfillOnlyFillsZeroDays() {
        let records = [DailyRecord(date: "2026-10-03", charCount: 100, sessionCount: 2),
                       DailyRecord(date: "2026-10-04", charCount: 100, sessionCount: 2, durationMs: 1_000)]
        let out = InputStats.backfilled(records: records, durationsByDay: ["2026-10-03": 12_000, "2026-10-04": 99_000])
        XCTAssertEqual(out.map(\.durationMs), [12_000, 1_000])
    }

    func testRecordAccumulatesDurationAndOldFileDecodes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"[{"date":"2026-01-01","sessionCount":1,"charCount":10,"quotaCharCount":0}]"#.utf8).write(to: url)
        let stats = InputStats(fileURL: url)
        XCTAssertEqual(stats.allDailyRecords().first?.durationMs, 0, "旧文件没有 durationMs 按 0")
        stats.record(charCount: 20, durationMs: 3_000)
        stats.record(charCount: 30, durationMs: 4_000)
        XCTAssertEqual(stats.today().durationMs, 7_000)
        XCTAssertEqual(stats.today().charCount, 50)
    }

    func testHeatmapLayoutMondayStart() {
        // 2026-10-05 是周一；3 列 = 9-21 周、9-28 周、10-05 周
        let records = [DailyRecord(date: "2026-10-05", charCount: 400, sessionCount: 1),
                       DailyRecord(date: "2026-09-30", charCount: 100, sessionCount: 1),
                       DailyRecord(date: "2026-08-01", charCount: 50, sessionCount: 1)]
        let h = ActivityHeatmap.compute(records: records, today: date("2026-10-05"), weeks: 3, calendar: cal)
        XCTAssertEqual(h.columns.count, 3)
        XCTAssertEqual(h.columns[0].first?.date, "2026-09-21")
        XCTAssertEqual(h.columns[2].first?.date, "2026-10-05")
        XCTAssertTrue(h.columns[2][0].isToday)
        XCTAssertFalse(h.columns[2][0].isFuture)
        XCTAssertTrue(h.columns[2][1].isFuture, "本周还没到的日子")
        XCTAssertEqual(h.maxChars, 400)
        XCTAssertEqual(h.columns[2][0].level, 4)
        XCTAssertEqual(h.columns[1][2].level, 1, "9-30 是 100/400")
        XCTAssertEqual(h.columns[0][0].level, 0)
        XCTAssertTrue(h.hasEarlier, "8-01 在窗口之前")
        // 10 月 1 日落在第 2 列；第 1 列补写九月，但离十月只差 1 列 → 不写
        XCTAssertEqual(h.monthLabels, [.init(column: 1, text: "十月")])
    }

    func testHeatmapPagingAndMonthLabels() {
        let h = ActivityHeatmap.compute(records: [], today: date("2026-10-05"), weeks: 10, pageOffset: 1, calendar: cal)
        // 第 2 页最后一列 = 10-05 前 10 周 = 7-27 那周
        XCTAssertEqual(h.columns.last?.first?.date, "2026-07-27")
        XCTAssertEqual(h.columns.first?.first?.date, "2026-05-25")
        XCTAssertEqual(h.monthLabels, [.init(column: 1, text: "六月"), .init(column: 5, text: "七月"), .init(column: 9, text: "八月")])
        XCTAssertFalse(h.hasEarlier)
        XCTAssertTrue(h.columns.flatMap { $0 }.allSatisfy { !$0.isFuture })
    }

    func testWeekdayLabelsAndColumnFit() {
        XCTAssertEqual(ActivityHeatmap.weekdayLabels(), ["一", "二", "三", "四", "五", "六", "日"])
        XCTAssertEqual(ActivityHeatmap.weekdayLabels(firstWeekday: 1).first, "日")
        XCTAssertEqual(ActivityHeatmap.columnsThatFit(width: 1000, minCell: 10, gap: 3, maxColumns: 26), 26)
        XCTAssertEqual(ActivityHeatmap.columnsThatFit(width: 129, minCell: 10, gap: 3, maxColumns: 26), 10)
        XCTAssertEqual(ActivityHeatmap.columnsThatFit(width: 0, minCell: 10, gap: 3, maxColumns: 26), 1)
    }
}
