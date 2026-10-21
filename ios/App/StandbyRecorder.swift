import AVFoundation
import Foundation

/// 待机录音器：音频引擎在待机期间一直开着（iOS 不允许后台从零开始录音），
/// 只用 isCapturing 开关决定要不要把样本收进来。输出 16kHz 单声道 Float32，和 Mac 端一致。
final class StandbyRecorder {
    var onLevel: ((Float) -> Void)?
    /// 引擎被系统停掉（来电、路由变化后重启失败等）
    var onEngineLost: ((String) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let queue = DispatchQueue(label: "typefree.standby.recorder")

    // 以下只在 queue 上读写
    private var capturing = false
    private var samples: [Float] = []
    /// 开始指令到达前最近一小段声音，避免第一个字被吃掉
    private var preRoll: [Float] = []
    private let preRollLimit = 16000 / 4

    private var configObserver: NSObjectProtocol?

    var isRunning: Bool { engine?.isRunning ?? false }

    /// 开启待机：激活音频会话并启动引擎。必须在前台调用。返回 nil 表示成功。
    func start() -> String? {
        if isRunning { return nil }
        let session = AVAudioSession.sharedInstance()
        do {
            // 和别的 App 的声音混播，不打断正在放的音乐；蓝牙耳机只用 A2DP 听，录音仍走机身麦克风
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            return "音频会话打不开：\(error.localizedDescription)"
        }
        return startEngine()
    }

    func stop() {
        _ = setInputMuted(false)
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        teardownEngine()
        queue.sync {
            capturing = false
            samples.removeAll()
            preRoll.removeAll()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 说话时才开麦：引擎一直开着，不说话时用系统级输入静音（iOS 17+）
    // 后台新建 / 恢复麦克风都会被系统拒绝（2003329396，2026-10-21 真机日志），所以引擎必须常开，
    // 这里只验证静音时状态栏橙点会不会消失。

    /// 设置系统级输入静音；返回 nil 表示成功
    func setInputMuted(_ muted: Bool) -> String? {
        guard #available(iOS 17.0, *) else { return "需要 iOS 17 以上" }
        do {
            try AVAudioApplication.shared.setInputMuted(muted)
            DebugLog.write("输入静音=\(muted) 成功")
            return nil
        } catch {
            let code = (error as NSError).code
            DebugLog.write("输入静音=\(muted) 失败 \(code)")
            return "麦克风\(muted ? "静音" : "取消静音")失败（\(code)）：\(error.localizedDescription)"
        }
    }

    func beginCapture() {
        queue.sync {
            samples = preRoll
            preRoll.removeAll()
            capturing = true
        }
    }

    /// 结束本次收音，返回 16kHz 样本
    func endCapture() -> [Float] {
        queue.sync {
            capturing = false
            let out = samples
            samples.removeAll()
            return out
        }
    }

    var capturedSeconds: Double {
        queue.sync { Double(samples.count) / 16000 }
    }

    private func startEngine() -> String? {
        teardownEngine()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            return "没有检测到麦克风"
        }
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return "麦克风启动失败（\((error as NSError).code)）：\(error.localizedDescription)"
        }
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // 插拔耳机等路由变化会让引擎停下，重启一次；后台起不来就交给上层结束待机
            guard let self else { return }
            if let error = self.startEngine() {
                self.onEngineLost?(error)
            }
        }
        return nil
    }

    private func teardownEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))

        queue.async { [weak self] in
            guard let self else { return }
            if self.capturing {
                self.samples.append(contentsOf: chunk)
                self.onLevel?(Self.level(of: chunk))
            } else {
                self.preRoll.append(contentsOf: chunk)
                if self.preRoll.count > self.preRollLimit {
                    self.preRoll.removeFirst(self.preRoll.count - self.preRollLimit)
                }
            }
        }
    }

    /// 和 Mac 端 AudioRecorder 同一套音量算法
    private static func level(of chunk: [Float]) -> Float {
        guard !chunk.isEmpty else { return 0 }
        var sum: Float = 0
        var peak: Float = 0
        for v in chunk {
            sum += v * v
            peak = max(peak, abs(v))
        }
        let rms = sqrt(sum / Float(chunk.count))
        return min(max(peak * 6, rms * 15), 1)
    }
}
