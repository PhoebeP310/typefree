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
    var onStyleChange: ((StyleSelection) -> Void)?

    /// 和语音页同一份选择（语气 / 程度 / 篇幅），这里只是交互不同：收起在按钮里，点开再选
    var style: StyleSelection { picker.style }
    private(set) var phase: Phase = .empty
    private var intent: String?
    /// 出候选后又改了风格：「换一批」变成「按新风格重新生成」
    private var styleChangedSinceResults = false

    private let actions: KeyboardActions
    /// 风格默认收起，和「想法」「换一批」排在同一行；点「风格」展开
    private var stylesExpanded = false
    private let picker: StylePicker
    private let styleButton = UIButton(type: .custom)
    private let intentButton = UIButton(type: .custom)
    private let refreshButton = UIButton(type: .custom)
    private let contentHost = UIView()
    private let returnButton = KeyButton(title: "发送", style: .function, fontSize: 15)
    private lazy var deleter = DeleteRepeater { [weak self] in self?.actions.deleteBackward() }
    private lazy var trackpad = SpaceTrackpad(move: actions.moveCursor)

    init(style: StyleSelection, actions: KeyboardActions) {
        picker = StylePicker(style: style, excluding: [.review])
        self.actions = actions
        super.init(frame: .zero)
        build()
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshReturnTitle() { returnButton.setTitle(actions.returnTitle(), for: .normal) }

    func setPhase(_ newPhase: Phase) {
        if case .results = newPhase { styleChangedSinceResults = false }
        if newPhase == .generating || newPhase == .listening { stylesExpanded = false }
        phase = newPhase
        render()
    }

    /// 语音页改了风格时同步过来
    func setStyle(_ newStyle: StyleSelection) {
        picker.style = newStyle
        renderActionRow()
    }

    func setIntent(_ text: String?) {
        intent = text
        render()
    }

    // MARK: - 布局

    private func build() {
        picker.isHidden = true
        picker.onChange = { [weak self] style in
            guard let self else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self.onStyleChange?(style)
            if case .results = self.phase { self.styleChangedSinceResults = true }
            self.renderActionRow()
        }

        let space = KeyButton(title: "空格", style: .function, fontSize: 15)
        trackpad.attach(to: space)
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

        for b in [styleButton, intentButton, refreshButton] {
            b.titleLabel?.font = .systemFont(ofSize: 13)
            b.titleLabel?.lineBreakMode = .byTruncatingTail
            b.layer.cornerRadius = 15
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        styleButton.backgroundColor = KTheme.well
        intentButton.backgroundColor = KTheme.well
        styleButton.addTarget(self, action: #selector(styleTapped), for: .touchUpInside)
        intentButton.addTarget(self, action: #selector(intentRowTapped), for: .touchUpInside)
        refreshButton.addTarget(self, action: #selector(generateTapped), for: .touchUpInside)
        intentButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        styleButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        refreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let actionRow = UIStackView(arrangedSubviews: [styleButton, intentButton, UIView(), refreshButton])
        actionRow.axis = .horizontal
        actionRow.spacing = 8
        actionRow.alignment = .center

        let root = UIStackView(arrangedSubviews: [actionRow, picker, contentHost, bottom])
        root.axis = .vertical
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            actionRow.heightAnchor.constraint(equalToConstant: 30),
            bottom.heightAnchor.constraint(equalToConstant: 44),
            globe.widthAnchor.constraint(equalToConstant: 44),
            delete.widthAnchor.constraint(equalToConstant: 52),
            returnButton.widthAnchor.constraint(equalToConstant: 72),
        ])
    }

    // MARK: - 各状态

    private func renderActionRow() {
        picker.isHidden = !stylesExpanded
        contentHost.isHidden = stylesExpanded   // 展开选风格时内容区让出位置，收起再回来
        let styleTitle = stylesExpanded ? "收起" : Self.styleTitle(style)
        styleButton.setTitle(styleTitle, for: .normal)
        styleButton.setImage(KTheme.sfImage(stylesExpanded ? "chevron.up" : "chevron.down", 10, weight: .semibold), for: .normal)
        styleButton.semanticContentAttribute = .forceRightToLeft
        styleButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: -4)
        styleButton.tintColor = KTheme.secondary
        styleButton.setTitleColor(KTheme.text, for: .normal)

        let hasMessage = phase != .empty
        intentButton.isHidden = !hasMessage
        if let intent {
            intentButton.setImage(nil, for: .normal)
            intentButton.setTitle("想法：\(intent)  ✕", for: .normal)
            intentButton.setTitleColor(KTheme.text, for: .normal)
        } else {
            intentButton.setImage(KTheme.sfImage("mic.fill", 11), for: .normal)
            intentButton.tintColor = KTheme.secondary
            intentButton.setTitle(" 想法", for: .normal)
            intentButton.setTitleColor(KTheme.secondary, for: .normal)
        }

        var showRefresh = false
        if case .results = phase { showRefresh = true }
        if case .failed = phase { showRefresh = true }
        refreshButton.isHidden = !showRefresh
        let emphasize = styleChangedSinceResults
        refreshButton.setImage(KTheme.sfImage("arrow.clockwise", 11, weight: .semibold), for: .normal)
        refreshButton.tintColor = emphasize ? KTheme.text : KTheme.secondary
        refreshButton.setTitle(emphasize ? " 按新风格重新生成" : " 换一批", for: .normal)
        refreshButton.setTitleColor(emphasize ? KTheme.text : KTheme.secondary, for: .normal)
        refreshButton.titleLabel?.font = .systemFont(ofSize: 13, weight: emphasize ? .semibold : .regular)
        refreshButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 2)
    }

    private func render() {
        renderActionRow()
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
        return centered([row, label("想换风格点左上角；说想法的话，说完就自动生成", size: 12, color: KTheme.secondary)])
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
        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 6
        for reply in replies {
            let card = UIButton(type: .custom)
            card.backgroundColor = KTheme.fnKey
            card.layer.cornerRadius = 12
            card.contentHorizontalAlignment = .left
            card.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            card.titleLabel?.numberOfLines = 3
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
        return scroll
    }

    // MARK: - 交互

    /// 收起时按钮上显示选了什么：已选 emoji，加上不是默认的程度 / 篇幅，如「😜🤔 轻 · 扩充」
    static func styleTitle(_ style: StyleSelection) -> String {
        let tones = style.tones.filter { $0 != .review }
        var parts: [String] = []
        if !tones.isEmpty, style.intensity != .medium { parts.append(style.intensity.name) }
        if style.length != .original { parts.append(style.length.name) }
        let emoji = tones.map(\.emoji).joined()
        let text = parts.joined(separator: " · ")
        if emoji.isEmpty && text.isEmpty { return "风格" }
        return [emoji, text].filter { !$0.isEmpty }.joined(separator: " ")
    }

    @objc private func generateTapped() { onGenerate?() }

    @objc private func styleTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        stylesExpanded.toggle()
        renderActionRow()
    }

    @objc private func intentRowTapped() {
        if intent != nil { onClearIntent?() } else { onIntentMic?() }
    }
    @objc private func intentTapped() { onIntentMic?() }
    @objc private func clearIntentTapped() { onClearIntent?() }
    @objc private func cardTapped(_ sender: UIButton) {
        guard let text = sender.title(for: .normal) else { return }
        onPick?(text)
    }
    @objc private func spaceTapped() { actions.insert(" ") }
    @objc private func returnTapped() { actions.returnKey() }
}
