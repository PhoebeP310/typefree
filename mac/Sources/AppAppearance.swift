import AppKit
import QuartzCore
import ObjectiveC

/// 配色「系统原生灰 · macOS 风」（2026-06 定稿）：浅色为正式配色，值不要动。
/// 深色只给主窗口（设置窗）用，由「设置 → 外观」控制（见 MainWindowAppearance）；
/// App 其余部分仍锁浅色（AppDelegate 里 NSApp.appearance = .aqua）。
/// 2026-09-11：Codex 曾把这里换成「曜石银白」，Ray 不认可，已恢复原值。
struct VPTheme {
    var bg: NSColor
    var card: NSColor
    var cardAlt: NSColor
    var answerBackground: NSColor
    var text: NSColor
    var text2: NSColor
    var text3: NSColor
    var sep: NSColor
    var accent: NSColor
    var accentSoft: NSColor
    var onAccent: NSColor       // 强调色实心底上的文字色（深底→白、浅底→深），与 accent 解耦
    var segSelBg: NSColor       // 分段控件选中药丸底色（系统风：浅灰轨道上浮起的白药丸）
    var danger: NSColor
    var ok: NSColor
    var sidebarBg: NSColor
    var sidebarSel: NSColor
    var sidebarHover: NSColor   // 侧栏悬停：原来就是白色 25% 透明
    var link: NSColor
    var heat: NSColor           // 本地改动：首页热力图格子色（默认主题保持原来那个蓝）

    /// 与原来 SettingsWindowController 里的 NSColor(hex:) 完全同一种写法，颜色值一模一样
    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255,
                alpha: 1)
    }

    static let light = VPTheme(
        bg: hex(0xFFFFFF),
        card: hex(0xFFFFFF),
        cardAlt: hex(0xF4F4F5),
        answerBackground: hex(0xFFFFFF),
        text: hex(0x111113),
        text2: hex(0x3F3F43),
        text3: hex(0x6E6E73),
        sep: NSColor(red: 0, green: 0, blue: 0, alpha: 0.08),
        accent: hex(0x111113),
        accentSoft: hex(0xF2F2F3),
        onAccent: hex(0xFFFFFF),
        segSelBg: hex(0xFFFFFF),
        danger: hex(0xC24545),
        ok: hex(0x2E8762),
        sidebarBg: hex(0xFFFFFF),
        sidebarSel: hex(0xF2F2F3),
        sidebarHover: NSColor.white.withAlphaComponent(0.25),
        link: NSColor.linkColor,
        heat: NSColor(red: 0.25, green: 0.52, blue: 1.0, alpha: 1)
    )

    /// 夜间配色「原生深灰」（2026-09-11，样板 mockups/dark-mode-options.html）：底色同 macOS 自带窗口 #1E1E1E，
    /// 卡片亮一档、边框看得清；三档文字用苹果系统灰，和浅色一样深浅分明。主按钮/开关反过来（亮底深字）。
    static let dark = VPTheme(
        bg: hex(0x1E1E1E),
        card: hex(0x282828),
        cardAlt: hex(0x323232),
        answerBackground: hex(0x282828),
        text: hex(0xF5F5F7),
        text2: hex(0xD1D1D6),
        text3: hex(0x8E8E93),
        sep: NSColor(red: 1, green: 1, blue: 1, alpha: 0.10),
        accent: hex(0xF5F5F7),
        accentSoft: hex(0x323232),
        onAccent: hex(0x1E1E1E),
        segSelBg: hex(0x4A4A4C),
        danger: hex(0xF07575),
        ok: hex(0x4CC38A),
        sidebarBg: hex(0x1E1E1E),
        sidebarSel: NSColor(red: 1, green: 1, blue: 1, alpha: 0.08),
        sidebarHover: hex(0x1E1E1E).withAlphaComponent(0.25),   // 同浅色：悬停不显色
        link: NSColor.linkColor,
        heat: NSColor(red: 0.25, green: 0.52, blue: 1.0, alpha: 1)
    )

    /// AppKit 控件持有动态 NSColor，不因系统切换而重建页面、丢失输入或焦点。
    static let automatic = VPTheme(
        bg: adaptive(\.bg), card: adaptive(\.card), cardAlt: adaptive(\.cardAlt),
        answerBackground: adaptive(\.answerBackground),
        text: adaptive(\.text), text2: adaptive(\.text2), text3: adaptive(\.text3),
        sep: adaptive(\.sep), accent: adaptive(\.accent), accentSoft: adaptive(\.accentSoft),
        onAccent: adaptive(\.onAccent), segSelBg: adaptive(\.segSelBg),
        danger: adaptive(\.danger), ok: adaptive(\.ok), sidebarBg: adaptive(\.sidebarBg),
        sidebarSel: adaptive(\.sidebarSel), sidebarHover: adaptive(\.sidebarHover), link: adaptive(\.link),
        heat: adaptive(\.heat)
    )

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { isDark($0) ? dark : light }
    }

    /// 本地改动：动态色解析时再读当前主题色，切主题只需刷新颜色，不用换掉控件手里的 NSColor
    private static func adaptive(_ keyPath: KeyPath<VPTheme, NSColor>) -> NSColor {
        NSColor(name: nil) { ColorTheme.current.palette(dark: isDark($0))[keyPath: keyPath] }
    }

    /// 只给小面积点缀染色：强调色、侧栏选中、热力图；底色/卡片/标签底保持原来的中性白灰（大面积染色发腻）
    fileprivate func tinted(_ t: ColorTheme.Tint) -> VPTheme {
        var v = self
        v.accent = Self.hex(t.accent)
        v.sidebarSel = Self.hex(t.soft)
        v.heat = Self.hex(t.heat)
        return v
    }

}

/// 本地改动：主题色（设置 → 外观 → 主题色），与深浅模式正交。存在 UserDefaults.standard。
/// 只影响主窗口；录音胶囊、引导窗等仍是原来的黑白。
enum ColorTheme: String, CaseIterable {
    case mono, pink, mint, blue, lavender

    static let userDefaultsKey = "ColorTheme"

    static var current: ColorTheme {
        ColorTheme(rawValue: UserDefaults.standard.string(forKey: userDefaultsKey) ?? "") ?? .mono
    }

    var title: String {
        switch self {
        case .mono: return "默认"
        case .pink: return "樱花粉"
        case .mint: return "薄荷"
        case .blue: return "雾蓝"
        case .lavender: return "薰衣草"
        }
    }

    struct Tint {
        let accent: UInt32, soft: UInt32, heat: UInt32
    }

    /// 浅色强调色都保证白字对比 ≥ 4.5:1；深色强调色是亮色，onAccent 沿用深色主题的深字
    private var tints: (light: Tint, dark: Tint)? {
        switch self {
        case .mono: return nil
        case .pink: return (
            Tint(accent: 0xD13A72, soft: 0xFCE4EE, heat: 0xEC4D8A),
            Tint(accent: 0xF58BB1, soft: 0x3D2832, heat: 0xF27AA6))
        case .mint: return (
            Tint(accent: 0x1A7F62, soft: 0xDDF1E9, heat: 0x2BB38A),
            Tint(accent: 0x6CD8B0, soft: 0x22362F, heat: 0x4CC79A))
        case .blue: return (
            Tint(accent: 0x2B63D1, soft: 0xE2EBFC, heat: 0x4085FF),
            Tint(accent: 0x86AEFF, soft: 0x243049, heat: 0x5B93FF))
        case .lavender: return (
            Tint(accent: 0x7350D0, soft: 0xECE5FB, heat: 0x9271E8),
            Tint(accent: 0xB7A2F7, soft: 0x302943, heat: 0xA48BF0))
        }
    }

    private static let cache: [String: VPTheme] = {
        var c: [String: VPTheme] = [:]
        for t in ColorTheme.allCases {
            c[t.rawValue + "-l"] = t.tints.map { VPTheme.light.tinted($0.light) } ?? .light
            c[t.rawValue + "-d"] = t.tints.map { VPTheme.dark.tinted($0.dark) } ?? .dark
        }
        return c
    }()

    /// 录音浮窗「墨黑」样式的声波色：黑底上用深色版强调色（亮一档）；默认主题 nil = 白波
    var overlayWave: NSColor? {
        guard let t = tints?.dark else { return nil }
        return NSColor(srgbRed: CGFloat((t.accent >> 16) & 0xFF) / 255,
                       green: CGFloat((t.accent >> 8) & 0xFF) / 255,
                       blue: CGFloat(t.accent & 0xFF) / 255, alpha: 1)
    }

    func palette(dark: Bool) -> VPTheme {
        Self.cache[rawValue + (dark ? "-d" : "-l")]!
    }

    /// 主题色变了：主窗口重建侧栏和页面
    static let didChangeNotification = Notification.Name("TypefreeColorThemeDidChange")
}

/// 主窗口（设置窗）和问 AI 面板的外观：跟随系统 / 浅色 / 深色，存在 UserDefaults.standard。
/// 主窗口弹出的子窗口、菜单会自动跟随主窗口；录音胶囊、状态栏菜单、引导窗、更新弹窗不受影响，
/// 仍随 App 锁浅色（Ray 2026-09-11：只做主窗口，别的别动；随后点名问 AI 面板也要跟）。
enum MainWindowAppearance: String {
    case system
    case light
    case dark

    static let userDefaultsKey = "MainWindowAppearance"

    static var current: MainWindowAppearance {
        MainWindowAppearance(rawValue: UserDefaults.standard.string(forKey: userDefaultsKey) ?? "") ?? .system
    }

    /// 外观可能变了（「设置 → 外观」切换，或系统深浅切换）：主窗口、问 AI 面板收到后各自重新套用 resolve()
    static let didChangeNotification = Notification.Name("TypefreeWindowAppearanceDidChange")

    /// 把系统深浅切换转成 didChangeNotification，全 App 只登记一次。
    /// 通知到达时全局设置偶尔还没写完，0.5s 后再发一次（外观没变的窗口什么也不做）。
    private static let systemObserver: NSObjectProtocol = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
    ) { _ in
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static func observeSystemChanges() { _ = systemObserver }

    /// 主窗口此刻实际用的外观（SettingsWindowController 设置窗口外观时同步）。
    /// CALayer 颜色第一次上色时视图多半还没进窗口，只能按它解析：App 锁了浅色，
    /// NSApp.effectiveAppearance 在主窗口深色时是错的。
    static var applied = NSAppearance(named: .aqua)!

    /// 系统当前是否深色。App 锁了浅色，读不到系统外观，改读全局设置
    /// （系统设为「自动」时它也随天黑天亮改写，2026-09-11 晚上实测读到 Dark）；
    /// 切换时系统发 AppleInterfaceThemeChangedNotification；主窗口变成前台、问 AI 面板弹出时也会再核对一次。
    static var systemIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// 按当前选项算出主窗口该用的外观
    static func resolve() -> NSAppearance {
        let dark: Bool
        switch current {
        case .system: dark = systemIsDark
        case .light: dark = false
        case .dark: dark = true
        }
        return NSAppearance(named: dark ? .darkAqua : .aqua)!
    }
}

extension NSColor {
    /// NSColor.blended 会提前解析动态颜色；让悬停色也随外观重新计算。
    func appearanceBlended(withFraction fraction: CGFloat, of other: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var result = self
            appearance.performAsCurrentDrawingAppearance {
                result = self.blended(withFraction: fraction, of: other) ?? self
            }
            return result
        }
    }
}

private final class AppearanceLayerColors: NSObject {
    var colors: [String: NSColor] = [:]
    var gradient: [NSColor]?
    var appearance: NSAppearance?
}

private var appearanceLayerColorsKey: UInt8 = 0

extension CALayer {
    private var appearanceColors: AppearanceLayerColors {
        if let colors = objc_getAssociatedObject(self, &appearanceLayerColorsKey) as? AppearanceLayerColors {
            return colors
        }
        let colors = AppearanceLayerColors()
        objc_setAssociatedObject(self, &appearanceLayerColorsKey, colors, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return colors
    }

    func setAppearanceBackground(_ color: NSColor) { setAppearanceColor(color, key: "backgroundColor") }
    func setAppearanceBorder(_ color: NSColor) { setAppearanceColor(color, key: "borderColor") }
    func setAppearanceShadow(_ color: NSColor) { setAppearanceColor(color, key: "shadowColor") }

    private func setAppearanceColor(_ color: NSColor, key: String) {
        let colors = appearanceColors
        colors.colors[key] = color
        (colors.appearance ?? MainWindowAppearance.applied).performAsCurrentDrawingAppearance {
            setValue(color.cgColor, forKey: key)
        }
    }

    fileprivate func refreshAppearance(_ appearance: NSAppearance) {
        guard let colors = objc_getAssociatedObject(self, &appearanceLayerColorsKey) as? AppearanceLayerColors else { return }
        colors.appearance = appearance
        for (key, color) in colors.colors { setValue(color.cgColor, forKey: key) }
        if let gradient = colors.gradient, let layer = self as? CAGradientLayer {
            layer.colors = gradient.map(\.cgColor)
        }
    }

    func setAppearanceGradient(_ colors: [NSColor]) {
        appearanceColors.gradient = colors
        (appearanceColors.appearance ?? MainWindowAppearance.applied).performAsCurrentDrawingAppearance {
            (self as? CAGradientLayer)?.colors = colors.map(\.cgColor)
        }
    }
}

/// CGColor 是快照，必须在外观变化时重新解析。只刷新颜色，不重建控件和编辑器。
class AppearanceObservingView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
        onAppearanceChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshAppearance()
    }

    func refreshAppearance() {
        let appearance = effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            var visited = Set<ObjectIdentifier>()
            func refreshLayer(_ layer: CALayer) {
                guard visited.insert(ObjectIdentifier(layer)).inserted else { return }
                layer.refreshAppearance(appearance)
                layer.sublayers?.forEach(refreshLayer)
            }
            func refreshView(_ view: NSView) {
                if let layer = view.layer { refreshLayer(layer) }
                view.needsDisplay = true
                view.subviews.forEach(refreshView)
            }
            refreshView(self)
            CATransaction.commit()
        }
    }
}
