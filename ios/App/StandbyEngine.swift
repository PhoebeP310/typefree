import AVFoundation
import Combine
import Foundation
import UIKit
import VoicePolishCore

/// 主 App 的待机中枢：开着麦克风在后台等键盘的指令，收到 start 开始收音，stop 后走识别 → 润色，
/// 结果写进 App Group 快照并通知键盘上屏。
final class StandbyEngine: ObservableObject {
    static let shared = StandbyEngine()

    enum Phase: Equatable {
        case off
        case idle
        case recording
        case processing
    }

    struct HistoryItem: Codable, Identifiable {
        let id: String
        let time: Date
        let text: String
        /// 这次用的写法（语气 / 篇幅 / 翻译），没选就是 nil
        var style: String?
    }

    @Published private(set) var phase: Phase = .off
    /// 本次开启用的方式（开启后改设置要关掉重开才生效）
    private(set) var activeMode: StandbyMode = StandbyMode.current
    @Published private(set) var expiresAt: Date?
    @Published private(set) var lastError: String? {
        didSet { if let lastError { DebugLog.write("错误：\(lastError)") } }
    }
    @Published private(set) var history: [HistoryItem] = []
    /// 键盘发来过指令 = 键盘已添加且开了完全访问（没有完全访问时键盘发不出指令）
    @Published private(set) var keyboardConnected = TypefreeShared.defaults.bool(forKey: StandbyEngine.keyboardSeenKey)
        || SharedBridge.shared.keyboardSeen()
    @Published var level: Float = 0

    private let bridge = SharedBridge.shared
    private let recorder = StandbyRecorder()
    private let pipeline: VoicePolishPipeline
    private var heartbeatTimer: Timer?
    private var currentSessionID: String?
    /// 本次处理用的风格（出结果时决定要不要去句号）
    private var currentStyle = StyleSelection()
    private var recordingStartedAt: Date?
    private let maxRecordingSeconds: TimeInterval = 5 * 60
    private static let historyKey = "recent_history"   // 老版本存在 UserDefaults，迁到文件
    private static let keyboardSeenKey = "keyboard_seen"
    /// 本次录音时长，出结果时记进统计
    private var lastRecordingMs = 0
    private static var historyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private init() {
        VoicePolishConfig.shared.reconcileSecrets()
        ProcessingMode.migrateUserDefaultsIfNeeded()
        let transcriber = CloudASRTranscriber()
        let polisher = AIPolisher()
        polisher.polishLogAppNameProvider = { "iPhone" }
        polisher.debugLog = { DebugLog.write($0) }
        transcriber.debugLog = { DebugLog.write($0) }
        pipeline = VoicePolishPipeline(aiPolisher: polisher, cloudTranscriber: transcriber)
        pipeline.debugLog = { DebugLog.write($0) }
        pipeline.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.handle(state) }
        }

        if let data = try? Data(contentsOf: Self.historyURL),
           let items = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            history = items
        } else if let data = TypefreeShared.defaults.data(forKey: Self.historyKey),
                  let items = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            history = items
            saveHistory()
            TypefreeShared.defaults.removeObject(forKey: Self.historyKey)
        }
        pruneHistory()

        recorder.onLevel = { [weak self] level in
            SharedBridge.shared.writeAudioLevel(level)
            DispatchQueue.main.async { self?.level = level }
        }
        recorder.onEngineLost = { [weak self] reason in
            self?.stopStandby(reason: reason)
        }

        DarwinNotifier.shared.observe(TypefreeShared.commandNotification) { [weak self] in
            self?.consumeCommand()
        }
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self?.stopStandby(reason: "被来电或其他 App 打断，语音输入已关闭")
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopStandby(reason: "系统音频服务重置，语音输入已关闭")
        }
        // 进程刚起来时把上一次残留的待机状态清掉，别让键盘以为还在待机
        publishStandby(active: false)
    }

    /// 这次录音是键盘发起的（区别于 App 内试说）
    var isKeyboardSession: Bool {
        guard let currentSessionID else { return false }
        return !currentSessionID.hasPrefix("in-app-")
    }

    private static var appStateName: String {
        switch UIApplication.shared.applicationState {
        case .active: return "前台"
        case .inactive: return "前台未激活"
        case .background: return "后台"
        @unknown default: return "未知"
        }
    }

    var isConfigured: Bool {
        CloudASRTranscriber().isConfigured()
    }

    // MARK: - 待机

    /// 开启待机；必须在前台调用（iOS 不允许后台起麦克风）
    @discardableResult
    func startStandby() -> Bool {
        DebugLog.write("开启：方式=\(StandbyMode.current.rawValue) 当前=\(phase) \(Self.appStateName)")
        lastError = nil
        guard AVAudioSession.sharedInstance().recordPermission == .granted else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted { self.startStandby() } else { self.lastError = "没有麦克风权限，请在 设置 → Typefree 里打开" }
                }
            }
            return false
        }
        if phase == .off {
            activeMode = StandbyMode.current
            let error: String?
            switch activeMode {
            case .alwaysOn:
                error = recorder.start()
            case .onDemand:
                error = recorder.start() ?? recorder.setInputMuted(true)
            }
            if let error {
                lastError = error
                publishStandby(active: false)
                return false
            }
            phase = .idle
        }
        extendExpiry()
        startHeartbeat()
        return true
    }

    func stopStandby(reason: String? = nil) {
        DebugLog.write("关闭：\(reason ?? "手动/超时") \(Self.appStateName)")
        if phase == .recording || phase == .processing, let sessionID = currentSessionID {
            pipeline.cancelCurrent()
            bridge.writeError(sessionID: sessionID, message: reason ?? "已停止")
        }
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        recorder.stop()
        phase = .off
        expiresAt = nil
        currentSessionID = nil
        level = 0
        bridge.writeAudioLevel(0)
        if let reason { lastError = reason }
        publishStandby(active: false)
    }

    private func extendExpiry() {
        expiresAt = Date().addingTimeInterval(StandbyDuration.current.interval)
        publishStandby(active: true)
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: TypefreeShared.heartbeatInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func tick() {
        guard phase != .off else { return }
        if phase == .recording, let started = recordingStartedAt,
           Date().timeIntervalSince(started) > maxRecordingSeconds {
            finishRecording()
        }
        if phase == .idle, let expiresAt, Date() >= expiresAt {
            stopStandby()
            return
        }
        publishStandby(active: true)
    }

    private func publishStandby(active: Bool) {
        let now = Date().timeIntervalSince1970
        bridge.writeStandbyStatus(.init(active: active,
                                        expiresAt: expiresAt?.timeIntervalSince1970 ?? now,
                                        heartbeat: now))
        DarwinNotifier.shared.post(TypefreeShared.stateNotification)
    }

    // MARK: - 指令

    /// 从键盘跳过来时：typefree://record?session=<id> 直接开始收音
    func handle(url: URL) {
        guard url.scheme == TypefreeShared.urlScheme else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let sessionID = items.first(where: { $0.name == "session" })?.value
        guard startStandby() else {
            if let sessionID { bridge.writeError(sessionID: sessionID, message: lastError ?? "开启失败") }
            return
        }
        if url.host == "record", let sessionID {
            markKeyboardConnected()
            beginRecording(sessionID: sessionID)
        }
    }

    private func consumeCommand() {
        guard let command = bridge.readCommand() else { return }
        bridge.clearCommand()
        DebugLog.write("收到键盘指令：\(command.kind.rawValue) 当前=\(phase) \(Self.appStateName)")
        markKeyboardConnected()
        switch command.kind {
        case .start:
            // 已关闭：不回话，键盘 1.5 秒等不到「在录」会自己跳过来重新开启
            guard phase != .off else { return }
            beginRecording(sessionID: command.sessionID)
        case .stop:
            guard command.sessionID == currentSessionID, phase == .recording else { return }
            finishRecording()
        }
    }

    private func beginRecording(sessionID: String) {
        if phase == .processing { pipeline.cancelCurrent() }
        if phase == .recording { _ = recorder.endCapture() }
        currentSessionID = sessionID
        if activeMode == .onDemand {
            if let error = recorder.setInputMuted(false) {
                let session = AVAudioSession.sharedInstance()
                DebugLog.write("开麦失败时：会话类别=\(session.category.rawValue) 别的 App 在放声音=\(session.isOtherAudioPlaying) \(Self.appStateName)")
                lastError = error
                phase = .idle
                bridge.writeError(sessionID: sessionID, message: error)
                DarwinNotifier.shared.post(TypefreeShared.stateNotification)
                return
            }
        }
        recorder.beginCapture()
        recordingStartedAt = Date()
        phase = .recording
        bridge.writeRecording(sessionID: sessionID)
        extendExpiry()
    }

    private func finishRecording() {
        guard let sessionID = currentSessionID else { return }
        let samples = recorder.endCapture()
        if activeMode == .onDemand { _ = recorder.setInputMuted(true) }
        level = 0
        bridge.writeAudioLevel(0)
        recordingStartedAt = nil
        // 不到 0.3 秒基本是误触
        lastRecordingMs = samples.count * 1000 / 16000
        guard samples.count > 16000 * 3 / 10 else {
            phase = .idle
            bridge.writeError(sessionID: sessionID, message: "说话时间太短")
            DarwinNotifier.shared.post(TypefreeShared.stateNotification)
            return
        }
        phase = .processing
        bridge.writeProcessing(sessionID: sessionID)
        DarwinNotifier.shared.post(TypefreeShared.stateNotification)
        // 键盘发起的这一次：带上键盘里选的语气 / 优化 / 翻译
        ToneCustomization.reload()
        let style = isKeyboardSession ? bridge.readStyle() : StyleSelection()
        currentStyle = style
        pipeline.sessionStyle = style.isEmpty ? nil
            : VoicePolishPipeline.SessionStyle(rules: style.rules, outputLanguage: style.translate.map { Self.outputLanguage(for: $0) },
                                               systemPrompt: style.systemPrompt)
        pipeline.saveToHistory = !style.transient
        DebugLog.write("本次风格：\(style.isEmpty ? "无" : style.summary)\(style.transient ? "（回复想法，不记历史）" : "")")
        pipeline.process(samples: samples, mode: .cloudOnly)
    }

    // MARK: - 流水线结果

    private func handle(_ state: VoicePolishPipeline.State) {
        guard let sessionID = currentSessionID else { return }
        switch state {
        case .transcribing, .polishing:
            return
        case .done(let raw):
            let text = currentStyle.tones.contains(.formal) ? raw : PeriodStyle.strip(raw)
            bridge.writeDone(sessionID: sessionID, text: text)
            if !currentStyle.transient {
                appendHistory(text, style: currentStyle.isEmpty ? nil : currentStyle.historyLabel)
                InputStats.shared.record(charCount: text.count, durationMs: lastRecordingMs)
            }
        case .empty:
            bridge.writeError(sessionID: sessionID, message: "没听清，再说一次")
        case .error(let message):
            bridge.writeError(sessionID: sessionID, message: message)
            lastError = message
        }
        if phase == .processing { phase = .idle }
        extendExpiry()
    }

    /// 键盘长按选的翻译目标 → 核心库的输出语言。粤语不在内置列表里：name 会原样进「翻译成自然、地道的 X」，写清楚要港式口语写法
    private static func outputLanguage(for target: TranslateTarget) -> OutputLanguage {
        switch target {
        case .english:
            return OutputLanguage.builtin.first { $0.id == "en" }
                ?? OutputLanguage(id: "en", name: "英文", tag: "EN", phrases: [], enabled: true)
        case .cantonese:
            return OutputLanguage(id: "yue", name: "粤语口语（港式写法，用「佢」「唔」「嘅」「咗」「喺」「啲」这类粤语字，繁体字；不是普通话书面语）",
                                  tag: "粤", phrases: [], enabled: true)
        }
    }

    // MARK: - 历史

    private func appendHistory(_ text: String, style: String?) {
        history.insert(HistoryItem(id: UUID().uuidString, time: Date(), text: text, style: style), at: 0)
        pruneHistory()
        saveHistory()
    }

    func deleteHistory(ids: Set<String>) {
        history.removeAll { ids.contains($0.id) }
        saveHistory()
    }

    /// 按「保留历史」删掉过期的；永久也设个上限，免得文件无限变大
    func pruneHistory() {
        let before = history.count
        if let days = HistoryRetention.current.days {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            history.removeAll { $0.time < cutoff }
        }
        if history.count > HistoryRetention.maxItems { history.removeLast(history.count - HistoryRetention.maxItems) }
        if history.count != before { saveHistory() }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: Self.historyURL, options: .atomic)
        }
    }

    /// 键盘出现过（有完全访问）就算连通：App 回到前台、首页试用输入框里切出键盘时调
    func refreshKeyboardConnected() {
        if !keyboardConnected, bridge.keyboardSeen() { markKeyboardConnected() }
    }

    private func markKeyboardConnected() {
        guard !keyboardConnected else { return }
        TypefreeShared.defaults.set(true, forKey: Self.keyboardSeenKey)
        DispatchQueue.main.async { self.keyboardConnected = true }
    }

    // MARK: - App 内试录

    func toggleTestRecording() {
        switch phase {
        case .recording:
            finishRecording()
        case .idle:
            beginRecording(sessionID: "in-app-" + UUID().uuidString)
        case .off:
            if startStandby() { beginRecording(sessionID: "in-app-" + UUID().uuidString) }
        case .processing:
            break
        }
    }
}

/// 历史保留多久
enum HistoryRetention: Int, CaseIterable, Identifiable {
    case forever = 0
    case month = 30
    case week = 7

    static let maxItems = 5000
    private static let key = "history_retention_days"

    var id: Int { rawValue }
    var days: Int? { rawValue == 0 ? nil : rawValue }

    var title: String {
        switch self {
        case .forever: return "永久"
        case .month: return "30 天"
        case .week: return "7 天"
        }
    }

    static var current: HistoryRetention {
        get { HistoryRetention(rawValue: TypefreeShared.defaults.integer(forKey: key)) ?? .forever }
        set { TypefreeShared.defaults.set(newValue.rawValue, forKey: key) }
    }
}
