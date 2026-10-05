import XCTest
@testable import VoicePolishCore

// 本地改动：首页统计改版（上周同期 / 按应用 / 节律深浅档）的单测
final class HomeStatsTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone
        return f.date(from: s)!.addingTimeInterval(15 * 3600)   // 当天下午，避开零点边界
    }
    private func rec(_ d: String, _ chars: Int, _ sessions: Int = 1) -> DailyRecord {
        DailyRecord(date: d, charCount: chars, sessionCount: sessions)
    }

    // MARK: - 上周同期

    func testLastWeekSamePeriodCoversMondayThroughSameWeekday() {
        // 今天 2026-10-01 周四 → 上周同期 = 9-21（周一）… 9-24（周四）
        let records = [
            rec("2026-09-20", 999),        // 上上周日，不算
            rec("2026-09-21", 100, 2),     // 上周一
            rec("2026-09-24", 50, 1),      // 上周四（同一天，算）
            rec("2026-09-25", 777),        // 上周五，超出同期，不算
            rec("2026-09-29", 300),        // 本周，不算
        ]
        let r = InputStats.lastWeekSamePeriodTotal(records: records, today: date("2026-10-01"), calendar: cal)
        XCTAssertEqual(r.chars, 150)
        XCTAssertEqual(r.sessions, 3)
    }

    func testLastWeekSamePeriodOnMondayIsOnlyLastMonday() {
        // 今天 2026-09-28 周一 → 只看 9-21
        let records = [rec("2026-09-21", 120), rec("2026-09-22", 80)]
        let r = InputStats.lastWeekSamePeriodTotal(records: records, today: date("2026-09-28"), calendar: cal)
        XCTAssertEqual(r.chars, 120)
    }

    func testLastWeekSamePeriodOnSundayIsWholeLastWeek() {
        // 今天 2026-10-04 周日 → 9-21…9-27 整周
        let records = [rec("2026-09-21", 1), rec("2026-09-27", 2), rec("2026-09-28", 4)]
        let r = InputStats.lastWeekSamePeriodTotal(records: records, today: date("2026-10-04"), calendar: cal)
        XCTAssertEqual(r.chars, 3)
    }

    func testWeekOverWeekText() {
        XCTAssertEqual(InputStats.weekOverWeekText(current: 123, previous: 100), "本周 ↑23%")
        XCTAssertEqual(InputStats.weekOverWeekText(current: 88, previous: 100), "本周 ↓12%")
        XCTAssertEqual(InputStats.weekOverWeekText(current: 100, previous: 100), "本周持平")
        XCTAssertEqual(InputStats.weekOverWeekText(current: 1001, previous: 1000), "本周持平", "不到 0.5% 四舍五入算持平")
        XCTAssertEqual(InputStats.weekOverWeekText(current: 0, previous: 100), "本周 ↓100%")
        XCTAssertEqual(InputStats.weekOverWeekText(current: 500, previous: 0), "上周同期没有使用")
        XCTAssertEqual(InputStats.weekOverWeekText(current: 0, previous: 0), "上周同期没有使用")
    }

    // MARK: - 按应用

    private func log(_ time: String, _ app: String, asr: String = "", output: String, kind: String? = nil) -> AIPolisher.PolishLog {
        AIPolisher.PolishLog(time: time, app: app, asr: asr, output: output, duration_ms: 0,
                             input_tokens: 0, output_tokens: 0, kind: kind)
    }

    func testAppSplitAggregatesTopFourAndMergesRest() {
        let entries = [
            log("2026-10-04 09:00:00", "Cursor", output: String(repeating: "字", count: 50)),
            log("2026-10-04 09:10:00", "Cursor", output: String(repeating: "字", count: 30)),
            log("2026-10-04 10:00:00", "WEA", output: String(repeating: "字", count: 60)),
            log("2026-10-04 11:00:00", "Google Chrome", output: String(repeating: "字", count: 40)),
            log("2026-10-04 12:00:00", "Notes", output: String(repeating: "字", count: 20)),
            log("2026-10-04 13:00:00", "Mail", output: String(repeating: "字", count: 10)),
            log("2026-10-04 14:00:00", "Slack", output: String(repeating: "字", count: 5)),
        ]
        let s = AppUsageSplit.compute(entries: entries, from: "2026-10-04", to: "2026-10-04")
        XCTAssertEqual(s.map(\.app), ["Cursor", "WEA", "Google Chrome", "Notes", "其他"])
        XCTAssertEqual(s.map(\.chars), [80, 60, 40, 20, 15])
    }

    func testAppSplitSkipsAskEmptyAndOutOfRangeAndFallsBackToASR() {
        let entries = [
            log("2026-10-04 09:00:00", "Cursor", asr: "问题", output: "很长的回答", kind: "ask"),
            log("2026-10-04 09:01:00", "Cursor", asr: "", output: ""),
            log("2026-10-03 23:59:59", "Cursor", output: "昨天的"),
            log("2026-10-04 09:02:00", "WEA", asr: "原文四字", output: ""),     // output 空 → 用 asr
            log("2026-10-04 09:03:00", "", output: "无名"),
        ]
        let s = AppUsageSplit.compute(entries: entries, from: "2026-10-04", to: "2026-10-04")
        XCTAssertEqual(s, [AppUsageSplit.Slice(app: "WEA", chars: 4), AppUsageSplit.Slice(app: "未知应用", chars: 2)])
        XCTAssertTrue(AppUsageSplit.compute(entries: [], from: "2026-10-04", to: "2026-10-04").isEmpty)
    }

    func testAppSplitWithExactlyFourAppsHasNoOther() {
        let entries = ["A", "B", "C", "D"].map { log("2026-10-04 09:00:00", $0, output: "xx") }
        let s = AppUsageSplit.compute(entries: entries, from: "2026-09-28", to: "2026-10-04")
        XCTAssertEqual(s.count, 4)
        XCTAssertFalse(s.contains { $0.app == "其他" })
    }

    // MARK: - 节律深浅档

    func testIntensityLevels() {
        XCTAssertEqual(ActivityRhythm.intensityLevel(chars: 0, maxChars: 100), 0)
        XCTAssertEqual(ActivityRhythm.intensityLevel(chars: 1, maxChars: 100), 1)
        XCTAssertEqual(ActivityRhythm.intensityLevel(chars: 25, maxChars: 100), 1)
        XCTAssertEqual(ActivityRhythm.intensityLevel(chars: 26, maxChars: 100), 2)
        XCTAssertEqual(ActivityRhythm.intensityLevel(chars: 50, maxChars: 100), 2)
        XCTAssertEqual(ActivityRhythm.intensityLevel(chars: 75, maxChars: 100), 3)
        XCTAssertEqual(ActivityRhythm.intensityLevel(chars: 76, maxChars: 100), 4)
        XCTAssertEqual(ActivityRhythm.intensityLevel(chars: 100, maxChars: 100), 4)
        XCTAssertEqual(ActivityRhythm.intensityLevel(chars: 5, maxChars: 0), 0)
    }
}
