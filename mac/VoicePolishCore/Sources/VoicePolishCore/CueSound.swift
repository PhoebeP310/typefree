import Foundation

/// 录音开始 / 结束提示音（工单 #1003）。
///
/// 不打包任何音频文件：声音都是这里现场合成的，原创、没有版权问题。App 播放和给 Ray 试听用的是同一份代码。
///
/// 第二版（2026-09-23）：第一版加了木琴 / 玻璃泛音、音区偏高（784–1900Hz）、音量偏大、完全干声，
/// Ray 听了说「廉价」。对照分析 Typeless 的提示音后改成这套配方：
///   · 近乎纯正弦（只留一丝二次谐波添暖），不要金属感泛音
///   · 中低音区（约 300–600Hz），不刺耳
///   · 两个音相隔约 0.13 秒：开始往上走、结束往下走；第一个音衰减得快，第二个音稍长
///   · 很轻（峰值约 -21dBFS），加一点小房间混响，尾音在左右散开，有空间感
/// 具体音程用我们自己的，不照搬对方的旋律。
public enum CueSound {
    public enum Style: String, CaseIterable {
        case fourth    // 四度：最接近 Typeless 那种感觉
        case fifth     // 五度：更开阔
        case third     // 大三度：更暖、更低
        case single    // 单音：最克制
        case knock     // 本地改动：指节敲木桌，闷闷的「咚」，不是乐音
        case mahjong   // 本地改动：麻将牌落桌（厚牌、偏闷）
        case woodfish  // 本地改动：低音木鱼，空心木头的「笃」
        case goStone   // 本地改动：围棋落子，石子「啪」+ 棋盘闷响
        case cork      // 本地改动：软木塞「啵」，音高往下滑

        /// 本地改动：敲击类（非乐音）
        public var isPercussive: Bool { [.knock, .mahjong, .woodfish, .goStone, .cork].contains(self) }

        public var displayName: String {
            switch self {
            case .fourth: return "四度双音"
            case .fifth: return "五度双音"
            case .third: return "三度双音"
            case .single: return "单音"
            case .knock: return "指节敲木桌"
            case .mahjong: return "麻将牌"
            case .woodfish: return "低音木鱼"
            case .goStone: return "围棋落子"
            case .cork: return "软木塞"
            }
        }
    }

    public enum Kind { case start, stop }

    public static let sampleRate: Double = 48_000
    /// 输出峰值（线性）。约 -21dBFS：比系统提示音轻得多，只是「知会一声」。
    static let targetPeak: Float = 0.09
    static let totalDuration: Double = 0.5
    static let noteGap: Double = 0.13

    /// 16-bit 立体声 WAV，可直接交给 AVAudioPlayer(data:)
    public static func wavData(style: Style, kind: Kind) -> Data {
        let (l, r) = stereoSamples(style: style, kind: kind)
        return wav(left: l, right: r)
    }

    /// 单声道混合（测试 / 分析用）
    public static func samples(style: Style, kind: Kind) -> [Float] {
        let (l, r) = stereoSamples(style: style, kind: kind)
        return zip(l, r).map { ($0 + $1) / 2 }
    }

    public static func stereoSamples(style: Style, kind: Kind) -> ([Float], [Float]) {
        let up = kind == .start
        let n = Int(totalDuration * sampleRate)
        var dry = [Float](repeating: 0, count: n)
        let lead = 0.004
        var wet: Float = 0.32
        if let hit = Hit.preset(style) {
            // 本地改动：敲击类：开始敲一下；结束敲两下，第二下低一点、轻一点
            if up {
                addHit(&dry, hit, pitch: 1.0, at: lead, amp: 1.0)
            } else {
                addHit(&dry, hit, pitch: 1.08, at: lead, amp: 1.0)
                addHit(&dry, hit, pitch: 0.9, at: lead + hit.doubleGap, amp: 0.75)
            }
            wet = 0.12   // 只留一点房间感，敲击声要干
        } else {
            // 音高（Hz）。双音：开始 = 低→高，结束 = 高→低
            let notes: [Double]
            switch style {
            case .fourth: notes = up ? [440.0, 587.33] : [440.0, 329.63]     // A4→D5 / A4→E4
            case .fifth:  notes = up ? [349.23, 523.25] : [523.25, 349.23]   // F4→C5 / C5→F4
            case .third:  notes = up ? [311.13, 392.0] : [392.0, 311.13]     // E♭4→G4 / G4→E♭4
            case .single: notes = up ? [587.33] : [440.0]                    // D5 / A4
            case .knock, .mahjong, .woodfish, .goStone, .cork: notes = []
            }
            for (i, f) in notes.enumerated() {
                let isLast = i == notes.count - 1
                addNote(&dry, freq: f, at: lead + Double(i) * noteGap,
                        amp: isLast ? 1.0 : 0.85, decay: isLast ? 0.065 : 0.05)
            }
        }
        var (wl, wr) = reverb(dry)
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0..<n {
            l[i] = dry[i] + wet * wl[i]
            r[i] = dry[i] + wet * wr[i]
        }
        // 结尾 25ms 淡出，混响尾巴不留咔声
        let fade = Int(0.025 * sampleRate)
        for j in 0..<fade {
            let g = Float(j) / Float(fade)
            l[n - 1 - j] *= g; r[n - 1 - j] *= g
        }
        let peak = max(l.map(abs).max() ?? 0, r.map(abs).max() ?? 0)
        if peak > 0 {
            let g = targetPeak / peak
            for i in 0..<n { l[i] *= g; r[i] *= g }
        }
        wl.removeAll(); wr.removeAll()
        return (l, r)
    }

    // MARK: - 合成小工具

    /// 一个近乎纯正弦的音：2ms 起音、指数衰减；叠一丝二次谐波（-30dB）让它不那么「电子」。
    static func addNote(_ buf: inout [Float], freq: Double, at start: Double, amp: Double, decay: Double) {
        let s0 = Int(start * sampleRate)
        let attack = 0.002
        for i in s0..<buf.count {
            let t = Double(i - s0) / sampleRate
            let env = (t < attack ? t / attack : 1) * exp(-max(0, t - attack) / decay)
            if env < 1e-5 && t > attack { break }
            let ph = 2 * .pi * freq * t
            buf[i] += Float(amp * env * (sin(ph) + 0.03 * sin(2 * ph)))
        }
    }

    /// 本地改动：敲击声参数。modes = [(频率Hz, 振幅, 衰减秒)]；开头一小段撞击噪声；整体过一阶低通（截止越低越闷）；
    /// sweep = 音高从 n 倍快速滑回原位（软木塞那种「啵」）。
    struct Hit {
        let modes: [(Double, Double, Double)]
        let noise: Double
        let noiseMs: Double
        let lowpass: Double
        let length: Double
        var sweep: (Double, Double)? = nil
        var doubleGap: Double = 0.09

        static func preset(_ style: Style) -> Hit? {
            switch style {
            case .knock:    // 指节的「咚」+ 桌板共鸣
                return Hit(modes: [(150, 1.0, 0.030), (410, 0.45, 0.018), (980, 0.12, 0.008)],
                           noise: 0.25, noiseMs: 4, lowpass: 1100, length: 0.14)
            case .mahjong:  // 厚牌落桌：短促硬质，靠低通压掉脆感
                return Hit(modes: [(680, 1.0, 0.028), (1074, 0.55, 0.016), (1578, 0.2, 0.008)],
                           noise: 0.35, noiseMs: 4, lowpass: 1300, length: 0.12, doubleGap: 0.055)
            case .woodfish: // 空心木头，带一点余音
                return Hit(modes: [(470, 1.0, 0.055), (760, 0.35, 0.030), (1290, 0.12, 0.012)],
                           noise: 0.15, noiseMs: 4, lowpass: 1800, length: 0.22)
            case .goStone:  // 石子很短的「啪」+ 棋盘木头闷响
                return Hit(modes: [(240, 0.8, 0.060), (520, 0.5, 0.020), (1400, 0.15, 0.005)],
                           noise: 0.35, noiseMs: 3, lowpass: 1600, length: 0.2)
            case .cork:     // 「啵」：音高快速下滑
                return Hit(modes: [(260, 1.0, 0.040), (520, 0.2, 0.020)],
                           noise: 0.05, noiseMs: 4, lowpass: 1400, length: 0.16, sweep: (2.2, 0.012))
            default:
                return nil
            }
        }
    }

    static func addHit(_ buf: inout [Float], _ hit: Hit, pitch: Double, at start: Double, amp: Double) {
        let s0 = Int(start * sampleRate)
        let len = min(buf.count - s0, Int(hit.length * sampleRate))
        guard len > 0 else { return }
        var seed: UInt64 = 0x9E3779B97F4A7C15 &* UInt64(pitch * 1000)
        var phases = [Double](repeating: 0, count: hit.modes.count)
        var out = [Double](repeating: 0, count: len)
        for i in 0..<len {
            let t = Double(i) / sampleRate
            var k = 1.0
            if let (mult, tau) = hit.sweep { k = 1 + (mult - 1) * exp(-t / tau) }
            var v = 0.0
            for (m, mode) in hit.modes.enumerated() {
                phases[m] += 2 * .pi * mode.0 * pitch * k / sampleRate
                v += mode.1 * exp(-t / mode.2) * sin(phases[m])
            }
            if t < hit.noiseMs / 1000 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let noise = Double(seed >> 33) / Double(1 << 31) * 2 - 1
                v += hit.noise * noise * exp(-t / (hit.noiseMs / 3000))
            }
            out[i] = v
        }
        let a = exp(-2 * .pi * hit.lowpass / sampleRate)
        var y = 0.0
        for i in 0..<len {
            y = (1 - a) * out[i] + a * y
            let attack = min(1, Double(i) / (0.001 * sampleRate))
            buf[s0 + i] += Float(amp * attack * y)
        }
    }

    /// 小房间混响（Schroeder：4 路梳状 + 2 路全通），左右声道用略不同的延时，尾音自然散开。
    /// 湿声先过一个一阶低通，去掉高频毛刺，听着更暖。
    static func reverb(_ x: [Float]) -> ([Float], [Float]) {
        func channel(_ combMs: [Double], _ apMs: [Double]) -> [Float] {
            let rt60 = 0.3
            let preDelay = Int(0.008 * sampleRate)
            var sum = [Float](repeating: 0, count: x.count)
            for ms in combMs {
                let d = Int(ms / 1000 * sampleRate)
                let g = Float(pow(10, -3 * (ms / 1000) / rt60))
                var buf = [Float](repeating: 0, count: x.count)
                var lp: Float = 0
                for i in 0..<x.count {
                    let input = i >= preDelay ? x[i - preDelay] : 0
                    let fb = i >= d ? buf[i - d] : 0
                    lp = 0.7 * fb + 0.3 * lp          // 反馈路径里的阻尼：高频衰减更快
                    buf[i] = input + g * lp
                    sum[i] += buf[i]
                }
            }
            var y = sum.map { $0 / Float(combMs.count) }
            for ms in apMs {
                let d = Int(ms / 1000 * sampleRate)
                let g: Float = 0.5
                var out = [Float](repeating: 0, count: y.count)
                for i in 0..<y.count {
                    let xd = i >= d ? y[i - d] : 0
                    let yd = i >= d ? out[i - d] : 0
                    out[i] = -g * y[i] + xd + g * yd
                }
                y = out
            }
            var lp: Float = 0
            for i in 0..<y.count { lp = 0.45 * y[i] + 0.55 * lp; y[i] = lp }
            return y
        }
        let l = channel([29.7, 37.1, 41.1, 43.7], [5.0, 1.7])
        let r = channel([30.3, 36.4, 42.2, 44.9], [5.3, 1.9])
        return (l, r)
    }

    static func wav(left: [Float], right: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        let frames = min(left.count, right.count)
        let dataBytes = UInt32(frames * 4)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        func i16(_ s: Float) -> Int16 { Int16(max(-1, min(1, s)) * Float(Int16.max)) }
        for i in 0..<frames {
            withUnsafeBytes(of: i16(left[i]).littleEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: i16(right[i]).littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }
}
