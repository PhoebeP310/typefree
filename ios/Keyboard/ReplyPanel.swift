import UIKit

/// 回复页：风格（可多选）· 内容区（空 / 待生成 / 说想法 / 生成中 / 候选）· 底栏
/// 对方的消息显示在键盘顶栏左边（由 KeyboardViewController 负责），这里只管下面。
final class ReplyPanel: UIView {
    enum Phase: Equatable {
        case empty
        case ready
        case listening
        case transcribing
        case generating
        case results([String])
        case failed(String)
    }

    var onGenerate: (() -> Void)?
    var onIntentMic: (() -> Void)?
    var onClearIntent: (() -> Void)?
    var onPick: ((String) -> Void)?
    var onTonesChange: (([Tone]) -> Void)?

    private(set) var tones: [Tone]
    private(set) var phase: Phase = .empty
    private var intent: String?
    /// 出候选后又改了风格：「换一批」变成「按新风格重新生成」
    private var styleChangedSinceResults = false

    private let actions: KeyboardActions
    private var chips: [Tone: ToneChip] = [:]
    private let contentHost = UIView()
    private let returnButton = KeyButton(title: "发送", style: .function, fontSize: 15)
    private lazy var deleter = DeleteRepeater { [weak self] in self?.actions.deleteBackward() }

    init(tones: [Tone], toneOrder: [Tone], actions: KeyboardActions) {
        self.tones = tones
        self.actions = actions
        super.init(frame: .zero)
        build(toneOrder: toneOrder)
        refreshChips()
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshReturnTitle() { returnButton.setTitle(actions.returnTitle(), for: .normal) }

    func setPhase(_ newPhase: Phase) {
        if case .results = newPhase { styleChangedSinceResults = false }
        phase = newPhase
        render()
    }

    func setIntent(_ text: String?) {
        intent = text
        render()
    }

    // MARK: - 布局

    private func build(toneOrder: [Tone]) {
        let toneScroll = UIScrollView()
        toneScroll.showsHorizontalScrollIndicator = false
        toneScroll.alwaysBounceHorizontal = true
        toneScroll.clipsToBounds = false
        let toneStack = UIStackView()
        toneStack.axis = .horizontal
        toneStack.spacing = 8
        toneStack.alignment = .top
        toneStack.translatesAutoresizingMaskIntoConstraints = false
        toneScroll.addSubview(toneStack)
        for tone in toneOrder where tone != .review {
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

        let space = KeyButton(title: "空格", style: .function, fontSize: 15)
        space.setTitleColor(KTheme.secondary, for: .normal)
        space.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        let delete = KeyButton(image: "delete.left", style: .function)
        deleter.attach(to: delete)
        returnButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        refreshReturnTitle()
        let globe = KeyButton(image: "globe", style: .function)
        actions.attachGlobe(globe)
        let bottom = UIStackView(arrangedSubviews: [globe, space, delete, returnButton])
        bottom.axis = .horizontal
        bottom.spacing = 6

        let root = UIStackView(arrangedSubviews: [toneScroll, contentHost, bottom])
        root.axis = .vertical
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            toneScroll.heightAnchor.constraint(equalToConstant: 64),
            bottom.heightAnchor.constraint(equalToConstant: 44),
            globe.widthAnchor.constraint(equalToConstant: 44),
            delete.widthAnchor.constraint(equalToConstant: 52),
            returnButton.widthAnchor.constraint(equalToConstant: 72),
        ])
    }

    private func refreshChips() {
        for (tone, chip) in chips { chip.isOn = tones.contains(tone) }
    }

    // MARK: - 各状态

    private func render() {
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        let view: UIView
        switch phase {
        case .empty: view = emptyView()
        case .ready: view = readyView()
        case .listening: view = listeningView()
        case .transcribing: view = waitingView("听写中…")
        case .generating: view = waitingView(intent == nil ? "正在想怎么回…" : "按你的想法写回复…")
        case .results(let replies): view = resultsView(replies)
        case .failed(let message): view = failedView(message)
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
    }

    private func centered(_ views: [UIView], spacing: CGFloat = 10) -> UIView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        let wrap = UIView()
        wrap.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: wrap.leadingAnchor, constant: 16),
        ])
        return wrap
    }

    private func label(_ text: String, size: CGFloat, color: UIColor, weight: UIFont.Weight = .regular) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.textAlignment = .center
        l.numberOfLines = 0
        return l
    }

    private func pill(_ title: String, symbol: String? = nil, primary: Bool, width: CGFloat, action: Selector) -> UIButton {
        let b = UIButton(type: .custom)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: primary ? .semibold : .regular)
        b.setTitleColor(primary ? KTheme.micIcon : KTheme.text, for: .normal)
        b.backgroundColor = primary ? KTheme.mic : KTheme.fnKey
        if let symbol {
            b.setImage(KTheme.sfImage(symbol, 14, weight: .semibold), for: .normal)
            b.tintColor = primary ? KTheme.micIcon : KTheme.text
            b.imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
        }
        b.layer.cornerRadius = 25
        b.addTarget(self, action: action, for: .touchUpInside)
        b.widthAnchor.constraint(equalToConstant: width).isActive = true
        b.heightAnchor.constraint(equalToConstant: 50).isActive = true
        return b
    }

    private func emptyView() -> UIView {
        let icon = UIImageView(image: KTheme.sfImage("doc.on.clipboard", 26))
        icon.tintColor = KTheme.secondary
        let box = centered([icon,
                            label("先复制对方的消息", size: 15, color: KTheme.text, weight: .medium),
                            label("在聊天里长按对方的消息，点「复制」，再回到这里", size: 13, color: KTheme.secondary)])
        box.backgroundColor = KTheme.well
        box.layer.cornerRadius = 12
        return box
    }

    private func readyView() -> UIView {
        let generate = pill("生成回复", primary: true, width: 150, action: #selector(generateTapped))
        let speak = pill("说想法", symbol: "mic.fill", primary: false, width: 150, action: #selector(intentTapped))
        let row = UIStackView(arrangedSubviews: [generate, speak])
        row.spacing = 10
        return centered([row, label("可以先选风格；说想法的话，说完就自动生成", size: 12, color: KTheme.secondary)])
    }

    private func listeningView() -> UIView {
        let stop = UIButton(type: .custom)
        stop.backgroundColor = KTheme.recording
        stop.layer.cornerRadius = 28
        stop.setImage(KTheme.sfImage("stop.fill", 18), for: .normal)
        stop.tintColor = .white
        stop.accessibilityLabel = "说完了"
        stop.addTarget(self, action: #selector(intentTapped), for: .touchUpInside)
        stop.widthAnchor.constraint(equalToConstant: 172).isActive = true
        stop.heightAnchor.constraint(equalToConstant: 56).isActive = true
        return centered([stop, label("正在听你的想法…  说完点一下，自动生成", size: 13, color: KTheme.text)])
    }

    private func waitingView(_ text: String) -> UIView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        return centered([spinner, label(text, size: 13, color: KTheme.secondary)])
    }

    private func failedView(_ message: String) -> UIView {
        let retry = pill("再试一次", primary: false, width: 150, action: #selector(generateTapped))
        return centered([label(message, size: 13, color: KTheme.secondary), retry])
    }

    private func resultsView(_ replies: [String]) -> UIView {
        // 顶上一行：想法（✕ 去掉）或「加个想法」· 换一批
        let left = UIButton(type: .custom)
        left.titleLabel?.font = .systemFont(ofSize: 12)
        left.setTitleColor(KTheme.secondary, for: .normal)
        left.backgroundColor = KTheme.well
        left.layer.cornerRadius = 12
        left.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        left.titleLabel?.lineBreakMode = .byTruncatingTail
        if let intent {
            left.setTitle("想法：\(intent)  ✕", for: .normal)
            left.addTarget(self, action: #selector(clearIntentTapped), for: .touchUpInside)
        } else {
            left.setImage(KTheme.sfImage("mic.fill", 11), for: .normal)
            left.tintColor = KTheme.secondary
            left.setTitle(" 加个想法", for: .normal)
            left.addTarget(self, action: #selector(intentTapped), for: .touchUpInside)
        }
        let refresh = UIButton(type: .custom)
        refresh.setImage(KTheme.sfImage("arrow.clockwise", 11, weight: .semibold), for: .normal)
        refresh.tintColor = styleChangedSinceResults ? KTheme.text : KTheme.secondary
        refresh.setTitle(styleChangedSinceResults ? " 按新风格重新生成" : " 换一批", for: .normal)
        refresh.setTitleColor(styleChangedSinceResults ? KTheme.text : KTheme.secondary, for: .normal)
        refresh.titleLabel?.font = .systemFont(ofSize: 12, weight: styleChangedSinceResults ? .semibold : .regular)
        refresh.addTarget(self, action: #selector(generateTapped), for: .touchUpInside)
        let top = UIStackView(arrangedSubviews: [left, UIView(), refresh])
        top.axis = .horizontal
        top.spacing = 8
        left.heightAnchor.constraint(equalToConstant: 24).isActive = true
        left.widthAnchor.constraint(lessThanOrEqualToConstant: 230).isActive = true

        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 6
        for reply in replies {
            let card = UIButton(type: .custom)
            card.backgroundColor = KTheme.fnKey
            card.layer.cornerRadius = 12
            card.contentHorizontalAlignment = .left
            card.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            card.titleLabel?.numberOfLines = 2
            card.titleLabel?.font = .systemFont(ofSize: 14)
            card.titleLabel?.lineBreakMode = .byTruncatingTail
            card.setTitle(reply, for: .normal)
            card.setTitleColor(KTheme.text, for: .normal)
            card.addTarget(self, action: #selector(cardTapped(_:)), for: .touchUpInside)
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
            list.addArrangedSubview(card)
        }
        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = false
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            list.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            list.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        let stack = UIStackView(arrangedSubviews: [top, scroll])
        stack.axis = .vertical
        stack.spacing = 6
        return stack
    }

    // MARK: - 交互

    @objc private func toneTapped(_ chip: ToneChip) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        var selection = StyleSelection(tones: tones)
        selection.toggle(chip.tone)
        tones = selection.tones
        refreshChips()
        onTonesChange?(tones)
        if case .results = phase {
            styleChangedSinceResults = true
            render()
        }
    }

    @objc private func generateTapped() { onGenerate?() }
    @objc private func intentTapped() { onIntentMic?() }
    @objc private func clearIntentTapped() { onClearIntent?() }
    @objc private func cardTapped(_ sender: UIButton) {
        guard let text = sender.title(for: .normal) else { return }
        onPick?(text)
    }
    @objc private func spaceTapped() { actions.insert(" ") }
    @objc private func returnTapped() { actions.returnKey() }
}
