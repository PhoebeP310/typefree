import XCTest
@testable import VoicePolishCore

/// 工单 #1003：提示音现场合成（第二版：纯净正弦 + 中低音区 + 轻混响，对照 Typeless 的配方）。
final class CueSoundTests: XCTestCase {
    func testAllStylesAreShortQuietAndClickFree() {
        for style in CueSound.Style.allCases {
            for kind in [CueSound.Kind.start, .stop] {
                let (l, r) = CueSound.stereoSamples(style: style, kind: kind)
                XCTAssertEqual(l.count, r.count)
                let seconds = Double(l.count) / CueSound.sampleRate
                XCTAssertLessThanOrEqual(seconds, 0.55, "\(style) 太长，会拖住开口")
                let peak = max(l.map(abs).max() ?? 0, r.map(abs).max() ?? 0)
                XCTAssertLessThanOrEqual(peak, 0.1, "\(style) 音量超标（要比系统提示音轻得多）")
                XCTAssertGreaterThan(peak, 0.05, "\(style) 几乎没声")
                XCTAssertLessThan(abs(l.first!) + abs(r.first!), 0.005, "\(style) 起头有咔声")
                XCTAssertLessThan(abs(l.last!) + abs(r.last!), 0.005, "\(style) 结尾有咔声")
                XCTAssertNotEqual(l, r, "\(style) 应带一点左右散开的混响")
            }
        }
    }

    /// 音色要干净：能量集中在 250–800Hz，高频（>1500Hz）几乎没有——第一版就是泛音太多听着廉价
    func testEnergyStaysInWarmRegister() {
        for style in CueSound.Style.allCases {
            let s = CueSound.samples(style: style, kind: .start).map(Double.init)
            let sr = CueSound.sampleRate
            func bandEnergy(_ f: Double) -> Double {   // Goertzel 单频能量
                let k = 2 * cos(2 * .pi * f / sr); var s1 = 0.0, s2 = 0.0
                for x in s { let s0 = x + k * s1 - s2; s2 = s1; s1 = s0 }
                return s1 * s1 + s2 * s2 - k * s1 * s2
            }
            let warm = stride(from: 280.0, through: 800, by: 10).map(bandEnergy).reduce(0, +)
            let high = stride(from: 1500.0, through: 6000, by: 50).map(bandEnergy).reduce(0, +)
            XCTAssertLessThan(high / warm, 0.01, "\(style) 高频成分太多")
        }
    }

    func testStartAndStopDiffer() {
        for style in CueSound.Style.allCases {
            XCTAssertNotEqual(CueSound.samples(style: style, kind: .start), CueSound.samples(style: style, kind: .stop))
        }
    }

    func testWavHeader() {
        let d = CueSound.wavData(style: .fourth, kind: .start)
        XCTAssertEqual(String(data: d.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: d.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(d.count, 44 + CueSound.stereoSamples(style: .fourth, kind: .start).0.count * 4)
    }
}
