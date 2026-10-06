import XCTest
@testable import VoicePolishCore

// 本地改动：词库页同步热词流式排布
final class FlowLayoutTests: XCTestCase {
    func testEmpty() {
        let r = FlowLayout.layout(widths: [], maxWidth: 300, itemHeight: 26, spacing: 6, lineSpacing: 8)
        XCTAssertEqual(r.frames, [])
        XCTAssertEqual(r.height, 0)
    }

    func testSingleRow() {
        let r = FlowLayout.layout(widths: [50, 60, 70], maxWidth: 300, itemHeight: 26, spacing: 6, lineSpacing: 8)
        XCTAssertEqual(r.frames.map(\.minX), [0, 56, 122])
        XCTAssertEqual(r.frames.map(\.minY), [0, 0, 0])
        XCTAssertEqual(r.height, 26)
    }

    func testWrapsWhenNextDoesNotFit() {
        // 100 + 6 + 100 = 206；再放 100 需要到 312 > 300 → 换行
        let r = FlowLayout.layout(widths: [100, 100, 100], maxWidth: 300, itemHeight: 26, spacing: 6, lineSpacing: 8)
        XCTAssertEqual(r.frames[2], CGRect(x: 0, y: 34, width: 100, height: 26))
        XCTAssertEqual(r.height, 60)
    }

    func testExactFitStaysOnLine() {
        // 147 + 6 + 147 = 300 正好放下
        let r = FlowLayout.layout(widths: [147, 147], maxWidth: 300, itemHeight: 26, spacing: 6, lineSpacing: 8)
        XCTAssertEqual(r.frames.map(\.minY), [0, 0])
    }

    func testOversizedItemClampedAndAlone() {
        let r = FlowLayout.layout(widths: [40, 500, 40], maxWidth: 300, itemHeight: 26, spacing: 6, lineSpacing: 8)
        XCTAssertEqual(r.frames[0].minY, 0)
        XCTAssertEqual(r.frames[1], CGRect(x: 0, y: 34, width: 300, height: 26), "超宽的截到容器宽、另起一行")
        XCTAssertEqual(r.frames[2], CGRect(x: 0, y: 68, width: 40, height: 26))
        XCTAssertEqual(r.height, 94)
    }

    func testZeroWidthContainerDoesNotCrash() {
        let r = FlowLayout.layout(widths: [40, 40], maxWidth: 0, itemHeight: 26, spacing: 6, lineSpacing: 8)
        XCTAssertEqual(r.frames.count, 2)
        XCTAssertEqual(r.frames[1].minY, 34)
    }
}
