import UIKit

/// 语音页（方案 D）：语气网格 | 程度 · 篇幅 / 底栏 空格 · 麦克风 · 删除 · 发送
/// 麦克风点一下 = 开始 / 结束；长按 = 边说边选这一句翻译成英文还是粤语
final class VoicePanel: UIView {
    enum MicLook { case idle, recording, processing }
    /// 长按松手时落在哪：普通出字 / 翻译 / 取消
    enum HoldEnd: Equatable { case plain, translate(TranslateTarget), cancel }

    var onMicTap: (() -> Void)?
    /// 长按开始：返回 false 表示现在不能开始（比如正在整理），就不弹翻译目标
    var onMicHoldBegan: (() -> Bool)?
    var onMicHoldEnded: ((HoldEnd) -> Void)?
    var onStyleChange: ((StyleSelection) -> Void)?

    var style: StyleSelection { settingsArea.style }
    private let actions: KeyboardActions

    private let settingsArea: StylePicker
    let micButton = MicButton()
    private let messageLabel = PaddedLabel()
    private var bubbles: [TranslateTarget: TargetBubble] = [:]
    private var hover: HoldEnd = .plain
    private let returnButton = KeyButton(title: "发送", style: .function, fontSize: 15)
    private lazy var deleter = DeleteRepeater { [weak self] in self?.actions.deleteBackward() }
    private lazy var trackpad = SpaceTrackpad(move: actions.moveCursor)
    private let selection = UISelectionFeedbackGenerator()

    init(style: StyleSelection, actions: KeyboardActions) {
        var style = style
        style.migrateLengthTones()
        style.translate = nil
        // App 里隐藏了的、已经下架的（俏皮、佛系）语气不再生效
        style.tones.removeAll { $0.isHidden || !Tone.defaultVoiceGrid.contains($0) }
        self.settingsArea = StylePicker(style: style)
        self.actions = actions
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 只放不写就不知道的话（权限、出错）；nil 隐藏
    func setMessage(_ text: String?) {
        messageLabel.text = text
        messageLabel.isHidden = text == nil
    }

    func setMic(_ look: MicLook) { micButton.look = look }

    func refreshReturnTitle() { returnButton.setTitle(actions.returnTitle(), for: .normal) }

    // MARK: - 布局

    private func build() {
        settingsArea.onChange = { [weak self] style in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.onStyleChange?(style)
        }

        // 底栏：🌐 · 空格 · 麦克风 · 删除 · 发送
        let globe = KeyButton(image: "globe", style: .function)
        actions.attachGlobe(globe)
        let space = KeyButton(title: "空格", style: .function, fontSize: 15)
        trackpad.attach(to: space)
        space.setTitleColor(KTheme.secondary, for: .normal)
        space.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        let delete = KeyButton(image: "delete.left", style: .function)
        deleter.attach(to: delete)
        returnButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        refreshReturnTitle()
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(micHeld(_:)))
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = .greatestFiniteMagnitude
        micButton.addGestureRecognizer(hold)
        let bottom = UIStackView(arrangedSubviews: [globe, space, micButton, delete, returnButton])
        bottom.axis = .horizontal
        bottom.alignment = .center
        bottom.spacing = 6

        let root = UIStackView(arrangedSubviews: [settingsArea, bottom])
        root.axis = .vertical
        root.spacing = 0
        root.distribution = .equalSpacing
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: 52),
            globe.widthAnchor.constraint(equalToConstant: 44),
            globe.heightAnchor.constraint(equalToConstant: 44),
            space.heightAnchor.constraint(equalToConstant: 44),
            delete.widthAnchor.constraint(equalToConstant: 52),
            delete.heightAnchor.constraint(equalToConstant: 44),
            returnButton.widthAnchor.constraint(equalToConstant: 64),
            returnButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        // 出错 / 权限提示：盖在语气区上方居中
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: settingsArea.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: settingsArea.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])

        // 长按时弹出的翻译目标：麦克风左上 / 右上，拇指一滑就到
        for (target, dx) in [(TranslateTarget.english, -62.0), (.cantonese, 62.0)] {
            let bubble = TargetBubble(title: target.name)
            bubble.isHidden = true
            bubble.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bubble)
            NSLayoutConstraint.activate([
                bubble.centerXAnchor.constraint(equalTo: micButton.centerXAnchor, constant: dx),
                bubble.centerYAnchor.constraint(equalTo: micButton.centerYAnchor, constant: -90),
            ])
            bubbles[target] = bubble
        }
    }

    // MARK: - 选择

    /// 回复页改了风格时同步过来
    func setStyle(_ newStyle: StyleSelection) { settingsArea.style = newStyle }

    // MARK: - 麦克风

    @objc private func micTapped() { onMicTap?() }

    @objc private func micHeld(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard onMicHoldBegan?() == true else { gesture.isEnabled = false; gesture.isEnabled = true; return }
            hover = .plain
            showTargets(true)
        case .changed:
            let next = holdResult(at: gesture.location(in: self))
            if next != hover {
                hover = next
                selection.selectionChanged()
                refreshHover()
            }
        case .ended:
            let result = holdResult(at: gesture.location(in: self))
            showTargets(false)
            onMicHoldEnded?(result)
        case .cancelled, .failed:
            if !bubbles.values.allSatisfy(\.isHidden) {
                showTargets(false)
                onMicHoldEnded?(.plain)
            }
        default:
            break
        }
    }

    /// 手指在哪：落在圆钮上（四周放宽 16）= 翻译；拖到麦克风下方 = 取消；其余 = 普通出字
    private func holdResult(at point: CGPoint) -> HoldEnd {
        for (target, bubble) in bubbles where bubble.frame.insetBy(dx: -16, dy: -16).contains(point) {
            return .translate(target)
        }
        if point.y > micButton.frame.maxY + 24 || point.y > bounds.maxY + 8 { return .cancel }
        return .plain
    }

    private func showTargets(_ show: Bool) {
        UIView.animate(withDuration: 0.15) {
            self.settingsArea.alpha = show ? 0.18 : 1
            for bubble in self.bubbles.values {
                bubble.isHidden = !show
                bubble.isOn = false
            }
        }
        if !show { hover = .plain }
        micButton.isDimmed = false
    }

    private func refreshHover() {
        for (target, bubble) in bubbles { bubble.isOn = hover == .translate(target) }
        micButton.isDimmed = hover == .cancel
    }

    @objc private func spaceTapped() { actions.insert(" ") }
    @objc private func returnTapped() { actions.returnKey() }
}

/// 一个语气：emoji 圆钮；选中变实心，名字做成小标签压在圆钮底边（不占位置，选上取消不挪动网格）
final class ToneChip: UIControl {
    static let size: CGFloat = 40

    let tone: Tone
    private let circle = UIView()
    private let emoji = UILabel()
    private let nameTag = PaddedLabel(insets: UIEdgeInsets(top: 0, left: 5, bottom: 0, right: 5))

    var isOn = false { didSet { update() } }

    init(tone: Tone) {
        self.tone = tone
        super.init(frame: .zero)
        accessibilityLabel = tone.name
        accessibilityTraits = .button
        isAccessibilityElement = true

        circle.layer.cornerRadius = Self.size / 2
        emoji.text = tone.emoji
        emoji.font = .systemFont(ofSize: 22)
        emoji.textAlignment = .center
        nameTag.text = tone.name
        nameTag.font = .systemFont(ofSize: 9, weight: .bold)
        nameTag.textAlignment = .center
        nameTag.layer.cornerRadius = 7
        nameTag.layer.borderWidth = 2
        nameTag.clipsToBounds = true

        [circle, emoji, nameTag].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.isUserInteractionEnabled = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
            circle.topAnchor.constraint(equalTo: topAnchor),
            circle.leadingAnchor.constraint(equalTo: leadingAnchor),
            circle.trailingAnchor.constraint(equalTo: trailingAnchor),
            circle.bottomAnchor.constraint(equalTo: bottomAnchor),
            emoji.centerXAnchor.constraint(equalTo: centerXAnchor),
            emoji.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameTag.centerXAnchor.constraint(equalTo: centerXAnchor),
            nameTag.centerYAnchor.constraint(equalTo: bottomAnchor),
            nameTag.heightAnchor.constraint(equalToConstant: 15),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    // 底边的名字标签露在外面，点它也算点这个语气
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -4, dy: -6).contains(point)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        update()
    }

    private func update() {
        circle.backgroundColor = isOn ? KTheme.chipOn : .clear
        circle.layer.borderWidth = isOn ? 0 : 1
        circle.layer.borderColor = KTheme.chipStroke.resolvedColor(with: traitCollection).cgColor
        nameTag.isHidden = !isOn
        nameTag.backgroundColor = KTheme.chipOn
        nameTag.textColor = KTheme.chipOnText
        // 标签外圈描一圈键盘底色，和圆钮分开
        nameTag.layer.borderColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.17, alpha: 1) : UIColor(white: 0.82, alpha: 1) }
            .resolvedColor(with: traitCollection).cgColor
        accessibilityValue = isOn ? "已选中" : "未选中"
    }
}

/// 竖排单选：程度（轻 / 中 / 重）、篇幅（精简 / 原样 / 扩充 / 梳理）
final class SegmentColumn: UIView {
    var onSelect: ((Int) -> Void)?
    var selectedIndex = 0 { didSet { update() } }
    /// 不生效时变暗，仍然可以点
    var isActive = true { didSet { alpha = isActive ? 1 : 0.4 } }

    private var buttons: [UIButton] = []

    init(items: [String], label: String) {
        super.init(frame: .zero)
        accessibilityLabel = label
        backgroundColor = KTheme.well
        layer.cornerRadius = 9
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 2
        stack.distribution = .fillEqually
        for (i, item) in items.enumerated() {
            let b = UIButton(type: .custom)
            b.setTitle(item, for: .normal)
            b.layer.cornerRadius = 7
            b.tag = i
            b.accessibilityLabel = "\(label)：\(item)"
            b.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            buttons.append(b)
            stack.addArrangedSubview(b)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped(_ sender: UIButton) {
        guard sender.tag != selectedIndex else { return }
        selectedIndex = sender.tag
        onSelect?(sender.tag)
    }

    private func update() {
        for b in buttons {
            let on = b.tag == selectedIndex
            b.backgroundColor = on ? KTheme.raised : .clear
            b.setTitleColor(on ? KTheme.text : KTheme.secondary, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 12, weight: on ? .semibold : .regular)
            b.accessibilityTraits = on ? [.button, .selected] : .button
        }
    }
}

/// 长按麦克风时弹出的翻译目标
final class TargetBubble: UILabel {
    var isOn = false { didSet { update() } }

    init(title: String) {
        super.init(frame: .zero)
        text = title
        textAlignment = .center
        layer.cornerRadius = 24
        clipsToBounds = true
        widthAnchor.constraint(equalToConstant: 84).isActive = true
        heightAnchor.constraint(equalToConstant: 48).isActive = true
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        backgroundColor = isOn ? KTheme.mic : KTheme.fnKey
        textColor = isOn ? KTheme.micIcon : KTheme.text
        font = .systemFont(ofSize: 15, weight: isOn ? .bold : .medium)
        transform = isOn ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
    }
}

/// 带内边距的标签（出错提示、语气名字标签）
final class PaddedLabel: UILabel {
    private let insets: UIEdgeInsets

    init(insets: UIEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)) {
        self.insets = insets
        super.init(frame: .zero)
        if insets.top > 0 {
            font = .systemFont(ofSize: 13, weight: .medium)
            textColor = KTheme.text
            backgroundColor = KTheme.raised
            numberOfLines = 2
            textAlignment = .center
            layer.cornerRadius = 12
            clipsToBounds = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}

/// 底栏麦克风：待机白色、录音红色带声波、整理中转圈；长按拖到取消区时变灰
final class MicButton: UIControl {
    var look: VoicePanel.MicLook = .idle { didSet { update() } }
    var isDimmed = false { didSet { update() } }

    private let icon = UIImageView()
    private let stop = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let leftWave = WaveBars()
    private let rightWave = WaveBars()

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityTraits = .button
        isAccessibilityElement = true
        layer.cornerRadius = 26
        icon.image = KTheme.sfImage("mic.fill", 22, weight: .semibold)
        icon.contentMode = .center
        stop.layer.cornerRadius = 5
        stop.backgroundColor = .white
        spinner.hidesWhenStopped = true
        [icon, stop, spinner, leftWave, rightWave].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.isUserInteractionEnabled = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 128),
            heightAnchor.constraint(equalToConstant: 52),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            stop.centerXAnchor.constraint(equalTo: centerXAnchor),
            stop.centerYAnchor.constraint(equalTo: centerYAnchor),
            stop.widthAnchor.constraint(equalToConstant: 10),
            stop.heightAnchor.constraint(equalToConstant: 10),
            leftWave.trailingAnchor.constraint(equalTo: stop.leadingAnchor, constant: -8),
            rightWave.leadingAnchor.constraint(equalTo: stop.trailingAnchor, constant: 8),
            leftWave.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightWave.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftWave.widthAnchor.constraint(equalToConstant: 30),
            rightWave.widthAnchor.constraint(equalToConstant: 30),
            leftWave.heightAnchor.constraint(equalToConstant: 20),
            rightWave.heightAnchor.constraint(equalToConstant: 20),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.8 : 1 } }

    func pushLevel(_ level: Float) {
        leftWave.push(level, mirrored: true)
        rightWave.push(level, mirrored: false)
    }

    private func update() {
        switch look {
        case .idle:
            backgroundColor = KTheme.mic
            icon.tintColor = KTheme.micIcon
            accessibilityLabel = "开始说话"
        case .recording:
            backgroundColor = isDimmed ? KTheme.fnKey : KTheme.recording
            accessibilityLabel = "说完了"
        case .processing:
            backgroundColor = KTheme.mic
            spinner.color = KTheme.micIcon
            accessibilityLabel = "整理中"
        }
        icon.isHidden = look != .idle
        stop.isHidden = look != .recording
        leftWave.isHidden = look != .recording
        rightWave.isHidden = look != .recording
        look == .processing ? spinner.startAnimating() : spinner.stopAnimating()
        isEnabled = look != .processing
    }
}

/// 麦克风里的小声波：5 根竖条，越靠近停止键越新
final class WaveBars: UIView {
    private var levels = [Float](repeating: 0, count: 5)
    private var mirrored = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func push(_ level: Float, mirrored: Bool) {
        self.mirrored = mirrored
        levels.removeFirst()
        levels.append(level)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.85).cgColor)
        let step = rect.width / CGFloat(levels.count)
        let barWidth: CGFloat = 4
        for (i, raw) in levels.enumerated() {
            let index = mirrored ? levels.count - 1 - i : i
            let h = max(6, rect.height * CGFloat(min(max(raw, 0), 1)))
            let x = CGFloat(index) * step + (step - barWidth) / 2
            let bar = CGRect(x: x, y: rect.midY - h / 2, width: barWidth, height: h)
            ctx.addPath(UIBezierPath(roundedRect: bar, cornerRadius: 2).cgPath)
        }
        ctx.fillPath()
    }
}
