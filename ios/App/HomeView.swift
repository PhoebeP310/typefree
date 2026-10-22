import AVFoundation
import SwiftUI
import UIKit
import VoicePolishCore

/// 首页：后台待机 · 统计 · 使用天数热力图；还没设置好时顶部换成三步清单
struct HomeView: View {
    @EnvironmentObject private var engine: StandbyEngine
    @Binding var configured: Bool
    @State private var stats = HomeStats.load()

    private var keyboardAdded: Bool { engine.keyboardConnected || KeyboardDetector.isAdded }
    private var setupDone: Bool { configured && engine.keyboardConnected }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        LogoMark().frame(width: 24, height: 24)
                        Text("Typefree").font(.system(size: 26, weight: .bold))
                    }
                    .frame(height: 56)

                    if !setupDone {
                        Text(setupStepsLeft == 1 ? "还差一步" : "还差 \(setupStepsLeft) 步")
                            .font(.system(size: 22, weight: .bold))
                            .padding(.horizontal, 4)
                        SetupChecklist(keysDone: configured, keyboardAdded: keyboardAdded,
                                       fullAccess: engine.keyboardConnected, configured: $configured)
                        if keyboardAdded && !engine.keyboardConnected {
                            KeyboardCheckField()
                        }
                    }

                    StandbyCard(enabled: configured)

                    if setupDone {
                        statsCard
                        activityCard
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(Color(.systemBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear {
            stats = HomeStats.load()
            engine.refreshKeyboardConnected()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            engine.refreshKeyboardConnected()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if !setupDone { engine.refreshKeyboardConnected() }
        }
        .onReceive(engine.$history) { _ in stats = HomeStats.load() }
    }

    private var setupStepsLeft: Int {
        [configured, keyboardAdded, engine.keyboardConnected].filter { !$0 }.count
    }

    private var statsCard: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                  spacing: 22) {
            StatCell(number: HomeStats.format(stats.todayChars), unit: "字", label: "今天")
            StatCell(number: HomeStats.format(stats.weekChars), unit: "字",
                     label: stats.weekChange.map { "本周 · 比上周 \($0)" } ?? "本周")
            StatCell(number: stats.speed.map { "\($0)" } ?? "—", unit: "字/分", label: "平均语速")
            StatCell(number: stats.savedHours, unit: stats.savedUnit, label: "省下的打字时间")
        }
        .padding(20)
        .background(Card())
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                StatCell(number: "\(stats.activeDays)", unit: "天", label: "用过的天数")
                Spacer()
                StatCell(number: "\(stats.currentStreak)", unit: "天", label: "连续在用")
                Spacer()
                StatCell(number: "\(stats.longestStreak)", unit: "天", label: "最长连续")
            }
            Heatmap(levels: stats.heatmap)
        }
        .padding(20)
        .background(Card())
    }
}

// MARK: - 待机卡片

struct StandbyCard: View {
    @EnvironmentObject private var engine: StandbyEngine
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(Color(.systemBackground))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.primary))
                VStack(alignment: .leading, spacing: 3) {
                    Text("后台待机").font(.system(size: 17, weight: .semibold))
                    if let status {
                        HStack(spacing: 6) {
                            Circle().fill(status.color).frame(width: 7, height: 7)
                            Text(status.text)
                        }
                        .font(.footnote)
                        .foregroundColor(status.color)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { engine.phase != .off },
                    set: { on in on ? requestAndStart() : engine.stopStandby() }
                ))
                .labelsHidden()
                .tint(.green)
                .disabled(!enabled)
            }
            if let error = engine.lastError, engine.phase == .off {
                Text(error).font(.footnote).foregroundColor(.red)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Card())
        .opacity(enabled ? 1 : 0.45)
    }

    private var status: (text: String, color: Color)? {
        switch engine.phase {
        case .off: return nil
        case .idle: return ("键盘可直接说话", Color(red: 0.14, green: 0.54, blue: 0.24))
        case .recording: return ("正在听", .red)
        case .processing: return ("整理中", .orange)
        }
    }

    private func requestAndStart() {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            engine.startStandby()
        default:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { if granted { engine.startStandby() } }
            }
        }
    }
}

/// 第三步的确认：在这里切到 Typefree 键盘，键盘一出现就报到，这一步当场打勾
struct KeyboardCheckField: View {
    @State private var text = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe").foregroundColor(.secondary)
            TextField("点这里，切到 Typefree 键盘确认一下", text: $text)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Card(radius: 16))
    }
}

// MARK: - 三步清单

struct SetupChecklist: View {
    let keysDone: Bool
    let keyboardAdded: Bool
    let fullAccess: Bool
    @Binding var configured: Bool

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink {
                ImportSettingsView(configured: $configured)
            } label: {
                SetupStep(number: 1, title: "导入识别和润色的 Key", done: keysDone, action: nil)
            }
            .disabled(keysDone)
            Divider().padding(.leading, 54)
            SetupStep(number: 2, title: "添加 Typefree 键盘", done: keyboardAdded,
                      action: keyboardAdded ? nil : ("去设置", openSettings))
            Divider().padding(.leading, 54)
            SetupStep(number: 3, title: "打开「允许完全访问」", done: fullAccess,
                      action: keyboardAdded && !fullAccess ? ("去设置", openSettings) : nil)
        }
        .background(Card(radius: 16))
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

struct SetupStep: View {
    let number: Int
    let title: String
    let done: Bool
    let action: (String, () -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if done {
                    Circle().fill(Color.primary)
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy))
                        .foregroundColor(Color(.systemBackground))
                } else {
                    Circle().strokeBorder(Color(.systemGray3), lineWidth: 1.5)
                    Text("\(number)").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                }
            }
            .frame(width: 26, height: 26)
            Text(title)
                .foregroundColor(done ? .secondary : .primary)
                .strikethrough(done)
            Spacer()
            if let action {
                Button(action.0, action: action.1)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(.systemBackground))
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Capsule().fill(Color.primary))
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

/// 系统设置里加没加 Typefree 键盘：读全局的 AppleKeyboards 列表（读不到时只能等键盘第一次发指令）
enum KeyboardDetector {
    static let keyboardBundleID = "com.phoebep310.typefree.keyboard"

    static var isAdded: Bool {
        (UserDefaults.standard.object(forKey: "AppleKeyboards") as? [String])?.contains(keyboardBundleID) ?? false
    }
}

// MARK: - 统计

struct StatCell: View {
    let number: String
    let unit: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(number).font(.system(size: 28, weight: .bold)).monospacedDigit()
                Text(unit).font(.system(size: 14, weight: .semibold))
            }
            Text(label).font(.footnote).foregroundColor(.secondary).lineLimit(1)
        }
    }
}

struct HomeStats {
    var todayChars = 0
    var weekChars = 0
    var weekChange: String?
    var speed: Int?
    var savedHours = "0"
    var savedUnit = "分钟"
    var activeDays = 0
    var currentStreak = 0
    var longestStreak = 0
    /// 13 周 × 7 天，按列（周）排，每格 0...4；-1 = 未来的日子
    var heatmap: [[Int]] = []

    /// 手机打字按每分钟 40 字估算省下的时间
    static let typingCharsPerMinute = 40.0

    static func load() -> HomeStats {
        let input = InputStats.shared
        var s = HomeStats()
        s.todayChars = input.today().charCount
        s.weekChars = input.currentWeekTotal().chars
        s.weekChange = InputStats.weekOverWeekText(current: s.weekChars, previous: input.lastWeekSamePeriodTotal().chars)
        let records = input.allDailyRecords()
        let chars = records.reduce(0) { $0 + $1.charCount }
        let ms = records.reduce(0) { $0 + $1.durationMs }
        if ms > 0 { s.speed = Int(Double(chars) / (Double(ms) / 60000)) }
        let savedMinutes = max(0, Double(chars) / typingCharsPerMinute - Double(ms) / 60000)
        if savedMinutes >= 60 {
            s.savedHours = String(format: "%.1f", savedMinutes / 60)
            s.savedUnit = "小时"
        } else {
            s.savedHours = "\(Int(savedMinutes))"
        }

        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var byDay: [Date: Int] = [:]
        for r in records where r.charCount > 0 {
            if let d = formatter.date(from: r.date) { byDay[calendar.startOfDay(for: d)] = r.charCount }
        }
        s.activeDays = byDay.count

        let today = calendar.startOfDay(for: Date())
        var day = byDay[today] != nil ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        while byDay[day] != nil {
            s.currentStreak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        var run = 0
        var previous: Date?
        for d in byDay.keys.sorted() {
            if let p = previous, calendar.date(byAdding: .day, value: 1, to: p) == d { run += 1 } else { run = 1 }
            s.longestStreak = max(s.longestStreak, run)
            previous = d
        }

        // 13 周热力图：最后一列是本周（周日开头），按当天字数在所有活跃天里的位置分 4 档
        let sorted = byDay.values.sorted()
        func level(_ v: Int?) -> Int {
            guard let v, v > 0, !sorted.isEmpty else { return 0 }
            let rank = Double(sorted.firstIndex { $0 >= v } ?? sorted.count - 1) / Double(max(sorted.count - 1, 1))
            return min(4, 1 + Int(rank * 3.999))
        }
        let weekday = calendar.component(.weekday, from: today) - 1
        let start = calendar.date(byAdding: .day, value: -(weekday + 12 * 7), to: today)!
        s.heatmap = (0..<13).map { w in
            (0..<7).map { d in
                let date = calendar.date(byAdding: .day, value: w * 7 + d, to: start)!
                return date > today ? -1 : level(byDay[date])
            }
        }
        return s
    }

    static func format(_ n: Int) -> String {
        if n >= 10000 { return String(format: "%.1f万", Double(n) / 10000) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

struct Heatmap: View {
    let levels: [[Int]]
    private let cell: CGFloat = 19
    private let gap: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { d in
                        Text(["日", "", "二", "", "四", "", "六"][d])
                            .font(.system(size: 10)).foregroundColor(.secondary)
                            .frame(width: 14, height: cell)
                    }
                }
                HStack(spacing: gap) {
                    ForEach(levels.indices, id: \.self) { w in
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { d in
                                let v = levels[w][d]
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(v < 0 ? Color.clear : Self.color(v))
                                    .overlay(RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(v < 0 ? Color(.systemGray5) : .clear, lineWidth: 1))
                                    .frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("少")
                ForEach(0..<5, id: \.self) { RoundedRectangle(cornerRadius: 3).fill(Self.color($0)).frame(width: 12, height: 12) }
                Text("多")
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
    }

    static func color(_ level: Int) -> Color {
        switch level {
        case 0: return Color(.systemGray6)
        case 1: return Color(.systemGray4)
        case 2: return Color(.systemGray)
        case 3: return Color(.darkGray)
        default: return .primary
        }
    }
}

// MARK: - 通用

struct Card: View {
    var radius: CGFloat = 20
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(.secondarySystemBackground))
    }
}

/// Typefree 的四根竖条标志
struct LogoMark: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 24
            Path { p in
                for (x, y0, y1) in [(5.0, 10.0, 14.0), (9.5, 6.0, 18.0), (14.0, 8.5, 15.5), (18.5, 11.0, 13.0)] {
                    p.move(to: CGPoint(x: x * s, y: y0 * s))
                    p.addLine(to: CGPoint(x: x * s, y: y1 * s))
                }
            }
            .stroke(Color.primary, style: StrokeStyle(lineWidth: 2.6 * s, lineCap: .round))
        }
    }
}
