import Foundation
import AVFoundation

/// 历史音频仓库：把 16kHz 单声道 Float32 样本编码为 AAC `.m4a` 存盘，并管理其生命周期。
/// 纯本地，不上传、不跨设备同步。文件名固定为 "<id>.m4a"。
public final class AudioClipStore {
    static let audioMagic = Data("VPENC1".utf8)

    private let directory: URL
    private let fileManager = FileManager.default
    private let encryptor: Encryptor?
    private let encryptNewFiles: Bool

    public init(directory: URL, encryptor: Encryptor? = nil, encryptNewFiles: Bool = false) {
        self.directory = directory
        self.encryptor = encryptor
        self.encryptNewFiles = encryptNewFiles
    }

    /// 默认仓库：<配置目录>/audio/
    /// macOS = ~/.config/voicepolish/audio/；iOS = App Group 容器/audio/
    public static func defaultStore(config: VoicePolishConfig = .shared) -> AudioClipStore {
        let dir = config.configDirectoryURL.appendingPathComponent("audio", isDirectory: true)
        return AudioClipStore(directory: dir, encryptor: HistoryCrypto.defaultEncryptor(), encryptNewFiles: true)
    }

    public var directoryURL: URL { directory }

    public func fileName(for id: String) -> String { "\(id).m4a" }

    public func url(forFileName name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    public func exists(_ name: String?) -> Bool {
        guard let name = name, !name.isEmpty else { return false }
        return fileManager.fileExists(atPath: url(forFileName: name).path)
    }

    // MARK: - 写入

    /// 把样本编码为 AAC m4a 落盘，成功返回文件名（如 "<id>.m4a"），失败返回 nil。
    /// 采用先写临时文件再原子改名，避免裁剪/读取时读到半截文件。
    @discardableResult
    public func save(samples: [Float], sampleRate: Double = 16000, id: String) -> String? {
        guard !samples.isEmpty else { return nil }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let name = fileName(for: id)
        let finalURL = url(forFileName: name)
        // 临时文件必须以 .m4a 结尾：AVAudioFile 按扩展名定容器，.tmp 结尾会默默写成 CAF（浏览器不认）
        let tmpURL = directory.appendingPathComponent("\(id).tmp.m4a")
        try? fileManager.removeItem(at: tmpURL)

        guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: sampleRate,
                                            channels: 1,
                                            interleaved: false) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 24000,  // 24kbps 单声道语音，体积小、可懂度足够
        ]

        do {
            let file = try AVAudioFile(forWriting: tmpURL, settings: settings)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                                frameCapacity: AVAudioFrameCount(samples.count)) else {
                try? fileManager.removeItem(at: tmpURL)
                return nil
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress, let dst = buffer.floatChannelData?[0] {
                    dst.update(from: base, count: samples.count)
                }
            }
            try file.write(from: buffer)
        } catch {
            try? fileManager.removeItem(at: tmpURL)
            return nil
        }
        defer { try? fileManager.removeItem(at: tmpURL) }

        try? fileManager.removeItem(at: finalURL)
        if encryptNewFiles {
            guard let encryptor = encryptor,
                  let plain = try? Data(contentsOf: tmpURL),
                  let sealed = encryptor.seal(plain) else { return nil }
            var data = Self.audioMagic
            data.append(sealed)
            do {
                try data.write(to: finalURL, options: .atomic)
            } catch {
                return nil
            }
            return name
        }

        do {
            try fileManager.moveItem(at: tmpURL, to: finalURL)
        } catch {
            try? fileManager.removeItem(at: tmpURL)
            return nil
        }
        return name
    }

    // MARK: - 读取（供重新转写用）

    /// 把存档音频解码回 16kHz 单声道 Float32 样本。
    public func loadSamples(fileName name: String) -> [Float]? {
        guard let data = loadData(fileName: name) else { return nil }
        let tmpURL = fileManager.temporaryDirectory
            .appendingPathComponent("voicepolish-history-\(UUID().uuidString).m4a")
        do {
            try data.write(to: tmpURL, options: .atomic)
        } catch {
            return nil
        }
        defer { try? fileManager.removeItem(at: tmpURL) }

        guard let file = try? AVAudioFile(forReading: tmpURL) else { return nil }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            return nil
        }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    // 本地改动：存档音频的时长（毫秒），只读文件头里的帧数，不解码。首页「洞察」回填录音时长用。
    public func durationMs(fileName name: String) -> Int? {
        guard let data = loadData(fileName: name) else { return nil }
        let tmpURL = fileManager.temporaryDirectory
            .appendingPathComponent("voicepolish-duration-\(UUID().uuidString).m4a")
        guard (try? data.write(to: tmpURL, options: .atomic)) != nil else { return nil }
        defer { try? fileManager.removeItem(at: tmpURL) }
        guard let file = try? AVAudioFile(forReading: tmpURL), file.fileFormat.sampleRate > 0 else { return nil }
        return Int(Double(file.length) / file.fileFormat.sampleRate * 1000)
    }

    public func loadData(fileName name: String) -> Data? {
        let fileURL = url(forFileName: name)
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else { return nil }
        if data.starts(with: Self.audioMagic) {
            guard let encryptor = encryptor else { return nil }
            return encryptor.open(data.dropFirst(Self.audioMagic.count))
        }
        return Self.looksLikePlaintextAudio(data) ? data : nil
    }

    public static func looksLikePlaintextM4A(_ data: Data) -> Bool {
        data.count > 8 && data.subdata(in: 4..<8) == Data("ftyp".utf8)
    }

    /// 早期 .tmp 坑写出的「名为 .m4a、实为 CAF」历史录音：头 4 字节是 "caff"。
    public static func looksLikePlaintextCAF(_ data: Data) -> Bool {
        data.count > 8 && data.prefix(4) == Data("caff".utf8)
    }

    /// 未加密的历史音频：标准 m4a（ftyp）或早期遗留的 CAF（caff）。两者都要纳入加密迁移与读取。
    public static func looksLikePlaintextAudio(_ data: Data) -> Bool {
        looksLikePlaintextM4A(data) || looksLikePlaintextCAF(data)
    }

    // MARK: - 删除 / 清理

    public func delete(fileName name: String?) {
        guard let name = name, !name.isEmpty else { return }
        try? fileManager.removeItem(at: url(forFileName: name))
    }

    /// 清空所有音频（清空历史时用）。
    public func deleteAll() {
        try? fileManager.removeItem(at: directory)
    }

    /// 孤儿清理：删掉 audio/ 下所有不在 keep 集合里的文件（含残留 .tmp）。
    public func pruneOrphans(keeping keep: Set<String>) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where !keep.contains(name) {
            try? fileManager.removeItem(at: url(forFileName: name))
        }
    }

    /// 当前音频目录总占用字节数（历史页显示用）。
    public func totalBytes() -> Int64 {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var total: Int64 = 0
        for name in names {
            if let attrs = try? fileManager.attributesOfItem(atPath: url(forFileName: name).path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    public func migrateAll() {
        guard let encryptor = encryptor,
              let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".m4a") && !name.contains(".tmp.") {
            let url = url(forFileName: name)
            guard let data = try? Data(contentsOf: url),
                  !data.starts(with: Self.audioMagic),
                  Self.looksLikePlaintextAudio(data),
                  let sealed = encryptor.seal(data) else { continue }
            var encrypted = Self.audioMagic
            encrypted.append(sealed)
            try? encrypted.write(to: url, options: .atomic)
        }
    }
}
