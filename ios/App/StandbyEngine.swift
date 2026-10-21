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
    }

    @Published private(set) var phase: Phase = .off
    /// 本次开启用的方式（开启后改设置要关掉重开才生效）
    private(set) var activeMode: StandbyMode = StandbyMode.current
    @Published private(set) var expiresAt: Date?
    @Published private(set) var lastError: String? {
        didSet { if let lastError { DebugLog.write("错误：\(lastError)") } }
    }
    @Published private(set) var history: [HistoryItem] = []
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
    private static let historyKey = "recent_history"

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

        if let data = TypefreeShared.defaults.data(forKey: Self.historyKey),
           let items = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            history = items
        }

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
            beginRecording(sessionID: sessionID)
        }
    }

    private func consumeCommand() {
        guard let command = bridge.readCommand() else { return }
        bridge.clearCommand()
        DebugLog.write("收到键盘指令：\(command.kind.rawValue) 当前=\(phase) \(Self.appStateName)")
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
        let style = isKeyboardSession ? bridge.readStyle() : StyleSelection()
        currentStyle = style
        let english = OutputLanguage.builtin.first { $0.id == "en" }
        pipeline.sessionStyle = style.isEmpty ? nil
            : VoicePolishPipeline.SessionStyle(rules: style.rules, outputLanguage: style.translate ? english : nil,
                                               systemPrompt: style.systemPrompt)
        DebugLog.write("本次风格：\(style.isEmpty ? "无" : style.summary)")
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
            appendHistory(text)
        case .empty:
            bridge.writeError(sessionID: sessionID, message: "没听清，再说一次")
        case .error(let message):
            bridge.writeError(sessionID: sessionID, message: message)
            lastError = message
        }
        if phase == .processing { phase = .idle }
        extendExpiry()
    }

    private func appendHistory(_ text: String) {
        history.insert(HistoryItem(id: UUID().uuidString, time: Date(), text: text), at: 0)
        if history.count > 30 { history.removeLast(history.count - 30) }
        if let data = try? JSONEncoder().encode(history) {
            TypefreeShared.defaults.set(data, forKey: Self.historyKey)
        }
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
