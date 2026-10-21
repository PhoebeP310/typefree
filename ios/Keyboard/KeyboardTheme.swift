import UIKit

/// 键盘配色：深色按设计稿，浅色贴近系统键盘。背景透明，用系统键盘底色。
enum KTheme {
    private static func dyn(_ light: UIColor, _ dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    private static func hex(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// 字母键
    static let key = dyn(.white, hex(0x636366))
    /// 功能键（删除、123、🌐…）
    static let fnKey = dyn(hex(0xABB1BA), hex(0x48484A))
    /// 嵌进去的底（分段切换、翻译 / 优化未开）
    static let well = dyn(hex(0xC3C7CE), hex(0x1C1C1E))
    /// 分段里选中的那块、翻译 / 优化打开
    static let raised = dyn(.white, hex(0x636366))
    /// 未选中语气的描边
    static let chipStroke = dyn(hex(0x9EA3AB), hex(0x545458))
    /// 选中语气的实心底 / ✓ 徽标
    static let chipOn = dyn(hex(0x1C1C1E), hex(0xE5E5EA))
    static let chipOnText = dyn(.white, hex(0x111111))
    /// 麦克风：全键盘唯一的高对比按钮
    static let mic = dyn(hex(0x111111), hex(0xF2F0EF))
    static let micIcon = dyn(.white, hex(0x111111))
    static let recording = UIColor.systemRed
    static let text = UIColor.label
    static let secondary = UIColor.secondaryLabel
    static let keyShadow = UIColor.black.withAlphaComponent(0.3)

    static func sfImage(_ name: String, _ size: CGFloat, weight: UIImage.SymbolWeight = .regular) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
    }
}

/// 普通键：按下变暗，带系统键盘那样的底部阴影
class KeyButton: UIButton {
    enum Style { case letter, function }

    private let style: Style

    init(title: String? = nil, image: String? = nil, style: Style = .letter, fontSize: CGFloat = 22) {
        self.style = style
        super.init(frame: .zero)
        if let title {
            setTitle(title, for: .normal)
            titleLabel?.font = .systemFont(ofSize: fontSize)
        }
        if let image { setImage(KTheme.sfImage(image, 18), for: .normal) }
        setTitleColor(KTheme.text, for: .normal)
        tintColor = KTheme.text
        layer.cornerRadius = 8
        layer.shadowColor = KTheme.keyShadow.cgColor
        layer.shadowOpacity = 1
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0
        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool { didSet { updateBackground() } }

    private func updateBackground() {
        let base = style == .letter ? KTheme.key : KTheme.fnKey
        backgroundColor = isHighlighted ? (style == .letter ? KTheme.fnKey : KTheme.key) : base
    }
}

/// 删除键：按住连删
final class DeleteRepeater {
    private var timer: Timer?
    private let action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }

    func attach(to button: UIButton) {
        button.addTarget(self, action: #selector(down), for: .touchDown)
        button.addTarget(self, action: #selector(up), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    @objc private func down() {
        action()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in self?.action() }
        }
    }

    @objc private func up() {
        timer?.invalidate()
        timer = nil
    }
}

/// 各页面共用的回调
struct KeyboardActions {
    var insert: (String) -> Void
    var deleteBackward: () -> Void
    var returnKey: () -> Void
    /// 给 🌐 键挂系统的切换输入法手势
    var attachGlobe: (UIButton) -> Void
    var returnTitle: () -> String
}
