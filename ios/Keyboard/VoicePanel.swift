import UIKit

/// 语音页：语气（可多选、可横滑）· 翻译 / 麦克风 / 优化 · 状态行 · 底栏
final class VoicePanel: UIView {
    enum MicLook { case idle, recording, processing }

    var onMicTap: (() -> Void)?
    var onStyleChange: ((StyleSelection) -> Void)?

    private(set) var style: StyleSelection
    private var toneOrder: [Tone]
    private let actions: KeyboardActions

    private let toneScroll = UIScrollView()
    private let toneStack = UIStackView()
    private var chips: [Tone: ToneChip] = [:]
    private let translateButton = SideToggle(title: "翻译", symbol: "character.bubble")
    private let optimizeButton = SideToggle(title: "优化", symbol: "list.number")
    let micButton = MicButton()
    private let statusLabel = UILabel()
    private let returnButton = KeyButton(title: "发送", style: .function, fontSize: 15)
    private lazy var deleter = DeleteRepeater { [weak self] in self?.actions.deleteBackward() }

    init(style: StyleSelection, toneOrder: [Tone], actions: KeyboardActions) {
        self.style = style
        self.toneOrder = toneOrder
        self.actions = actions
        super.init(frame: .zero)
        build()
        refreshSelection()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setStatus(_ text: String, emphasized: Bool = false) {
        statusLabel.text = text
        statusLabel.textColor = emphasized ? KTheme.text : KTheme.secondary
    }

    func setMic(_ look: MicLook) { micButton.look = look }

    func refreshReturnTitle() { returnButton.setTitle(actions.returnTitle(), for: .normal) }

    // MARK: - 布局

    private func build() {
        // 语气
        toneScroll.showsHorizontalScrollIndicator = false
        toneScroll.alwaysBounceHorizontal = true
        toneScroll.clipsToBounds = false
        toneStack.axis = .horizontal
        toneStack.spacing = 8
        toneStack.alignment = .top
        toneStack.translatesAutoresizingMaskIntoConstraints = false
        toneScroll.addSubview(toneStack)
        for tone in toneOrder {
            let chip = ToneChip(tone: tone)
            chip.addTarget(self, action: #selector(toneTapped(_:)), for: .touchUpInside)
            chips[tone] = chip
            toneStack.addArrangedSubview(chip)
        }
        NSLayoutConstraint.activate([
            toneStack.leadingAnchor.constraint(equalTo: toneScroll.contentLayoutGuide.leadingAnchor, constant: 4),
            toneStack.trailingAnchor.constraint(equalTo: toneScroll.contentLayoutGuide.trailingAnchor, constant: -24),
            toneStack.topAnchor.constraint(equalTo: toneScroll.contentLayoutGuide.topAnchor, constant: 6),
            toneStack.bottomAnchor.constraint(equalTo: toneScroll.contentLayoutGuide.bottomAnchor),
            toneStack.heightAnchor.constraint(equalTo: toneScroll.frameLayoutGuide.heightAnchor, constant: -6),
        ])

        // 翻译 · 麦克风 · 优化（优化最常用，放最右）
        translateButton.addTarget(self, action: #selector(translateTapped), for: .touchUpInside)
        optimizeButton.addTarget(self, action: #selector(optimizeTapped), for: .touchUpInside)
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        let mainRow = UIStackView(arrangedSubviews: [translateButton, micButton, optimizeButton])
        mainRow.axis = .horizontal
        mainRow.alignment = .center
        mainRow.distribution = .equalSpacing

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 1
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.75

        let middle = UIStackView(arrangedSubviews: [mainRow, statusLabel])
        middle.axis = .vertical
        middle.spacing = 8
        let middleWrap = UIView()
        middle.translatesAutoresizingMaskIntoConstraints = false
        middleWrap.addSubview(middle)
        NSLayoutConstraint.activate([
            middle.leadingAnchor.constraint(equalTo: middleWrap.leadingAnchor, constant: 4),
            middle.trailingAnchor.constraint(equalTo: middleWrap.trailingAnchor, constant: -4),
            middle.centerYAnchor.constraint(equalTo: middleWrap.centerYAnchor),
        ])

        // 底栏：🌐 · 空格 · 删除 · 发送
        let globe = KeyButton(image: "globe", style: .function)
        actions.attachGlobe(globe)
        let space = KeyButton(title: "空格", style: .function, fontSize: 15)
        space.setTitleColor(KTheme.secondary, for: .normal)
        space.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        let delete = KeyButton(image: "delete.left", style: .function)
        deleter.attach(to: delete)
        returnButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        refreshReturnTitle()
        let bottom = UIStackView(arrangedSubviews: [globe, space, delete, returnButton])
        bottom.axis = .horizontal
        bottom.spacing = 6

        let root = UIStackView(arrangedSubviews: [toneScroll, middleWrap, bottom])
        root.axis = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            toneScroll.heightAnchor.constraint(equalToConstant: 66),
            bottom.heightAnchor.constraint(equalToConstant: 44),
            globe.widthAnchor.constraint(equalToConstant: 44),
            delete.widthAnchor.constraint(equalToConstant: 52),
            returnButton.widthAnchor.constraint(equalToConstant: 72),
        ])
    }

    // MARK: - 交互

    private func refreshSelection() {
        for (tone, chip) in chips { chip.isOn = style.tones.contains(tone) }
        translateButton.isOn = style.translate
        optimizeButton.isOn = style.optimize
    }

    @objc private func toneTapped(_ chip: ToneChip) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        style.toggle(chip.tone)
        refreshSelection()
        onStyleChange?(style)
    }

    @objc private func translateTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        style.translate.toggle()
        refreshSelection()
        onStyleChange?(style)
    }

    @objc private func optimizeTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        style.optimize.toggle()
        refreshSelection()
        onStyleChange?(style)
    }

    @objc private func micTapped() { onMicTap?() }
    @objc private func spaceTapped() { actions.insert(" ") }
    @objc private func returnTapped() { actions.returnKey() }
}

/// 一个语气：emoji 圆钮，选中变实心 + 右上角 ✓ + 下面出名字
final class ToneChip: UIControl {
    let tone: Tone
    private let circle = UIView()
    private let emoji = UILabel()
    private let badge = UIImageView()
    private let nameLabel = UILabel()

    var isOn = false { didSet { update() } }

    init(tone: Tone) {
        self.tone = tone
        super.init(frame: .zero)
        accessibilityLabel = tone.name
        accessibilityTraits = .button
        isAccessibilityElement = true

        circle.layer.cornerRadius = 20
        circle.isUserInteractionEnabled = false
        emoji.text = tone.emoji
        emoji.font = .systemFont(ofSize: 22)
        emoji.textAlignment = .center
        badge.image = KTheme.sfImage("checkmark", 8, weight: .heavy)
        badge.contentMode = .center
        badge.layer.cornerRadius = 7.5
        badge.layer.borderWidth = 2
        badge.clipsToBounds = true
        nameLabel.text = tone.name
        nameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.textAlignment = .center
        nameLabel.textColor = KTheme.text

        [circle, emoji, badge, nameLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.isUserInteractionEnabled = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 42),
            heightAnchor.constraint(equalToConstant: 58),
            circle.topAnchor.constraint(equalTo: topAnchor),
            circle.centerXAnchor.constraint(equalTo: centerXAnchor),
            circle.widthAnchor.constraint(equalToConstant: 40),
            circle.heightAnchor.constraint(equalToConstant: 40),
            emoji.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            emoji.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 15),
            badge.heightAnchor.constraint(equalToConstant: 15),
            badge.topAnchor.constraint(equalTo: circle.topAnchor, constant: -4),
            badge.trailingAnchor.constraint(equalTo: circle.trailingAnchor, constant: 4),
            nameLabel.topAnchor.constraint(equalTo: circle.bottomAnchor, constant: 3),
            nameLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        update()
    }

    private func update() {
        circle.backgroundColor = isOn ? KTheme.chipOn : .clear
        circle.layer.borderWidth = isOn ? 0 : 1
        circle.layer.borderColor = KTheme.chipStroke.resolvedColor(with: traitCollection).cgColor
        badge.isHidden = !isOn
        badge.backgroundColor = KTheme.chipOn
        badge.tintColor = KTheme.chipOnText
        // 徽标外圈用键盘底色描一圈，和圆钮分开
        badge.layer.borderColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.17, alpha: 1) : UIColor(white: 0.82, alpha: 1) }
            .resolvedColor(with: traitCollection).cgColor
        nameLabel.isHidden = !isOn
        accessibilityValue = isOn ? "已选中" : "未选中"
    }
}

/// 麦克风两侧的翻译 / 优化开关
final class SideToggle: UIControl {
    private let icon = UIImageView()
    private let label = UILabel()

    var isOn = false { didSet { update() } }

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        accessibilityLabel = title
        accessibilityTraits = .button
        isAccessibilityElement = true
        layer.cornerRadius = 18
        icon.image = KTheme.sfImage(symbol, 19)
        icon.contentMode = .center
        label.text = title
        label.font = .systemFont(ofSize: 12)
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 5
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 64),
            heightAnchor.constraint(equalToConstant: 72),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.7 : 1 } }

    private func update() {
        backgroundColor = isOn ? KTheme.raised : KTheme.well
        icon.tintColor = isOn ? KTheme.text : KTheme.secondary
        label.textColor = isOn ? KTheme.text : KTheme.secondary
        label.font = .systemFont(ofSize: 12, weight: isOn ? .semibold : .regular)
        accessibilityValue = isOn ? "已打开" : "已关闭"
    }
}

/// 中间的大麦克风：待机白色、录音红色带声波、整理中转圈
final class MicButton: UIControl {
    var look: VoicePanel.MicLook = .idle { didSet { update() } }

    private let icon = UIImageView()
    private let stop = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let leftWave = WaveBars()
    private let rightWave = WaveBars()

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityTraits = .button
        isAccessibilityElement = true
        layer.cornerRadius = 36
        icon.image = KTheme.sfImage("mic.fill", 26, weight: .semibold)
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
            widthAnchor.constraint(equalToConstant: 172),
            heightAnchor.constraint(equalToConstant: 72),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            stop.centerXAnchor.constraint(equalTo: centerXAnchor),
            stop.centerYAnchor.constraint(equalTo: centerYAnchor),
            stop.widthAnchor.constraint(equalToConstant: 20),
            stop.heightAnchor.constraint(equalToConstant: 20),
            leftWave.trailingAnchor.constraint(equalTo: stop.leadingAnchor, constant: -12),
            rightWave.leadingAnchor.constraint(equalTo: stop.trailingAnchor, constant: 12),
            leftWave.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightWave.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftWave.widthAnchor.constraint(equalToConstant: 40),
            rightWave.widthAnchor.constraint(equalToConstant: 40),
            leftWave.heightAnchor.constraint(equalToConstant: 28),
            rightWave.heightAnchor.constraint(equalToConstant: 28),
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
            backgroundColor = KTheme.recording
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
