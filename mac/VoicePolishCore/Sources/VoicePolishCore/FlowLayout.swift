import Foundation
import CoreGraphics

// 本地改动：词库页同步热词改成「按词宽自动换行」的小标签（流式排布）。
// 纯计算：给每个标签的宽度和容器宽度，从左到右排，放不下就换行；单个超宽的标签截到容器宽度、独占一行。
public enum FlowLayout {
    public struct Result: Equatable {
        public let frames: [CGRect]   // 左上角为原点（y 向下）
        public let height: CGFloat    // 总高度；没有元素为 0
    }

    public static func layout(widths: [CGFloat], maxWidth: CGFloat, itemHeight: CGFloat,
                              spacing: CGFloat, lineSpacing: CGFloat) -> Result {
        guard !widths.isEmpty else { return Result(frames: [], height: 0) }
        let limit = max(1, maxWidth)
        var frames: [CGRect] = []
        frames.reserveCapacity(widths.count)
        var x: CGFloat = 0, y: CGFloat = 0
        for raw in widths {
            let w = min(max(0, raw), limit)
            if x > 0 && x + w > limit {        // 本行已有元素且放不下 → 换行
                x = 0
                y += itemHeight + lineSpacing
            }
            frames.append(CGRect(x: x, y: y, width: w, height: itemHeight))
            x += w + spacing
        }
        return Result(frames: frames, height: y + itemHeight)
    }
}
