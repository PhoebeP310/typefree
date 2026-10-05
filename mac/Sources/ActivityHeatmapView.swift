import Cocoa
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

/// 本地改动：首页「洞察」热力图（替换原来的「节律」一行圆点 RhythmStripView）。
/// GitHub 式：每列一周（周一起算，与 App 周统计同口径）、每行一个星期几，最新一周在最右；
/// 本地改动：网格铺满卡片内宽：放尽量多的周（格子 12–22pt、间距 3–4pt，最多 53 周，算法见 ActivityHeatmap.fillLayout）；
/// 左侧星期标签，列下月份标签；最底下一行左边写悬停那天（与网格左缘对齐）、右边是「更少 … 更多」图例（贴卡片内容右缘）。
/// 深浅按窗口内单日最多字数分 4 档（ActivityRhythm.intensityLevel），颜色沿用原节律圆点那个蓝。
/// 系统 tooltip 在这里不可靠，悬停信息自己画。
final class ActivityHeatmapView: NSView {
    /// 与原节律圆点同一个蓝（刻意的，不跟随主题强调色）
    static let accent = NSColor(red: 0.25, green: 0.52, blue: 1.0, alpha: 1)
    static let maxWeeks = 53   // 本地改动：26 → 53，配合铺满宽度
    private static let levelAlphas: [CGFloat] = [0, 0.25, 0.5, 0.75, 1.0]

    private let labelWidth: CGFloat = 20     // 左侧星期标签列
    // 本地改动：格子 10–18 → 12–22，间距随宽度在 3–4 之间（由 fillLayout 算）
    private let minGap: CGFloat = 3
    private let minCell: CGFloat = 12
    private let maxCell: CGFloat = 22
    private let monthRowHeight: CGFloat = 18
    private let legendRowHeight: CGFloat = 18

    private var records: [DailyRecord] = []
    private var theme: VPTheme = .automatic
    private var model: ActivityHeatmap?
    private var modelColumns = 0
    private var hover: (col: Int, row: Int)?
    private var tracking: NSTrackingArea?

    /// 往前翻了几页（每页 = 当前列数周），0 = 最新
    private(set) var pageOffset = 0
    /// 翻页按钮状态回调：(能往前翻, 能往后翻)
    var onPagingChanged: ((Bool, Bool) -> Void)?

    override var isFlipped: Bool { true }

    func apply(records: [DailyRecord], theme: VPTheme) {
        self.records = records
        self.theme = theme
        model = nil
        needsLayout = true
        needsDisplay = true
    }

    /// delta = +1 往前（更早）翻一页，-1 往后（更新）翻一页
    func page(by delta: Int) {
        if delta > 0 && model?.hasEarlier != true { return }
        let next = max(0, pageOffset + delta)
        guard next != pageOffset else { return }
        pageOffset = next
        model = nil
        hover = nil
        rebuildModelIfNeeded()
    }

    // MARK: - 尺寸

    // 本地改动：列数、格子、间距一起算，网格右缘正好贴视图右缘
    private var metrics: ActivityHeatmap.GridMetrics {
        ActivityHeatmap.fillLayout(width: bounds.width - labelWidth, minCell: minCell, maxCell: maxCell,
                                   minGap: minGap, maxColumns: Self.maxWeeks)
    }

    private var columnCount: Int { metrics.columns }
    private var cellSize: CGFloat { metrics.cell }
    private var gap: CGFloat { metrics.gap }

    private func gridHeight(cell: CGFloat) -> CGFloat { cell * 7 + gap * 6 }

    override var intrinsicContentSize: NSSize {
        let cell = bounds.width > 0 ? cellSize : minCell
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: gridHeight(cell: cell) + monthRowHeight + 6 + legendRowHeight)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged {
            invalidateIntrinsicContentSize()
            rebuildModelIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        rebuildModelIfNeeded()
    }

    private func rebuildModelIfNeeded() {
        let cols = columnCount
        guard model == nil || cols != modelColumns else { return }
        modelColumns = cols
        model = ActivityHeatmap.compute(records: records, weeks: cols, pageOffset: pageOffset)
        onPagingChanged?(model?.hasEarlier ?? false, pageOffset > 0)
        needsDisplay = true
    }

    private func cellRect(col: Int, row: Int, cell: CGFloat) -> NSRect {
        NSRect(x: labelWidth + CGFloat(col) * (cell + gap), y: CGFloat(row) * (cell + gap), width: cell, height: cell)
    }

    // MARK: - 悬停

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let cell = cellSize
        guard let model, p.x >= labelWidth, p.y >= 0, p.y < gridHeight(cell: cell) else { setHover(nil); return }
        let col = Int((p.x - labelWidth) / (cell + gap))
        let row = Int(p.y / (cell + gap))
        guard col < model.columns.count, row < 7, !model.columns[col][row].isFuture else { setHover(nil); return }
        setHover((col, row))
    }

    override func mouseExited(with event: NSEvent) { setHover(nil) }

    private func setHover(_ h: (col: Int, row: Int)?) {
        guard h?.col != hover?.col || h?.row != hover?.row else { return }
        hover = h
        needsDisplay = true
    }

    private func hoverText(_ c: ActivityHeatmap.Cell) -> String {
        let parts = c.date.split(separator: "-")
        let label = parts.count == 3 ? "\(Int(parts[1]) ?? 0)月\(Int(parts[2]) ?? 0)日" : c.date
        guard c.chars > 0 else { return "\(label) · 没有使用" }
        let nf = NumberFormatter(); nf.numberStyle = .decimal
        return "\(label) · \(nf.string(from: NSNumber(value: c.chars)) ?? "\(c.chars)") 字"
    }

    // MARK: - 绘制

    private var emptyFill: NSColor { theme.text3.withAlphaComponent(0.12) }

    private func fill(level: Int) -> NSColor {
        level == 0 ? emptyFill : Self.accent.withAlphaComponent(Self.levelAlphas[level])
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model, !model.columns.isEmpty else { return }
        let m = metrics
        let cell = m.cell, gap = m.gap
        let radius = max(2, cell * 0.22)
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: theme.text3]

        // 左侧星期标签（一 … 日）
        for (row, text) in ActivityHeatmap.weekdayLabels().enumerated() {
            let s = NSAttributedString(string: text, attributes: small)
            let size = s.size()
            s.draw(at: NSPoint(x: 0, y: CGFloat(row) * (cell + gap) + (cell - size.height) / 2))
        }

        // 格子
        for (col, days) in model.columns.enumerated() {
            for (row, day) in days.enumerated() {
                let rect = cellRect(col: col, row: row, cell: cell)
                if day.isFuture {
                    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
                    theme.sep.setStroke(); path.lineWidth = 1; path.stroke()
                    continue
                }
                let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                fill(level: day.level).setFill()
                path.fill()
                let hovered = hover?.col == col && hover?.row == row
                if day.isToday || hovered {
                    let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), xRadius: radius + 1, yRadius: radius + 1)
                    (hovered ? theme.text : Self.accent).setStroke()
                    ring.lineWidth = 1.5
                    ring.stroke()
                }
            }
        }

        // 月份标签：写在该列下方
        let monthY = gridHeight(cell: cell) + 4
        for m in model.monthLabels {
            let s = NSAttributedString(string: m.text, attributes: small)
            s.draw(at: NSPoint(x: labelWidth + CGFloat(m.column) * (cell + gap), y: monthY))
        }

        // 最底一行：右边图例「更少 ▢▢▢▢▢ 更多」贴卡片内容右缘，左边悬停那天与网格左缘对齐
        // 本地改动：图例改为按视图右缘（= 卡片内容右缘，网格已铺满）对齐，不再按网格实际宽度
        let gridRight = bounds.width
        let legendY = monthY + monthRowHeight + 2
        let swatch = min(cell, 11)
        let more = NSAttributedString(string: "更多", attributes: small)
        let less = NSAttributedString(string: "更少", attributes: small)
        var x = gridRight - more.size().width
        more.draw(at: NSPoint(x: x, y: legendY))
        x -= 6
        for level in stride(from: 4, through: 0, by: -1) {
            x -= swatch
            let r = NSRect(x: x, y: legendY + (legendRowHeight - swatch) / 2 - 1, width: swatch, height: swatch)
            let rr = max(2, swatch * 0.22)
            fill(level: level).setFill()
            NSBezierPath(roundedRect: r, xRadius: rr, yRadius: rr).fill()
            x -= 3
        }
        x -= 3 + less.size().width
        less.draw(at: NSPoint(x: x, y: legendY))

        if let h = hover, h.col < model.columns.count {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: theme.text]
            NSAttributedString(string: hoverText(model.columns[h.col][h.row]), attributes: attrs)
                .draw(at: NSPoint(x: labelWidth, y: legendY))
        }
    }
}
