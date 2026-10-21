import UIKit

/// 小鹤双拼页：字母键右下角标韵母；输入时顶栏换成「拼音 + 候选」（候选条由 KeyboardViewController 盖在顶栏上）
final class PinyinPanel: UIView {
    /// 输入中 / 不在输入，控制器据此切换顶栏
    var onComposingChange: ((Bool) -> Void)?
    var onSwitchToEnglish: (() -> Void)?

    let candidateBar = CandidateBar()

    private let actions: KeyboardActions
    private let engine = RimeEngine.shared
    private var composing = false
    private var engineFailed = false
    private let returnButton = KeyButton(title: "发送", style: .function, fontSize: 15)
    private lazy var deleter = DeleteRepeater { [weak self] in self?.deleteTapped() }

    private static let rows: [[(String, String)]] = [
        [("q", "iu"), ("w", "ei"), ("e", "e"), ("r", "uan"), ("t", "ue"), ("y", "un"), ("u", "sh"), ("i", "ch"), ("o", "uo"), ("p", "ie")],
        [("a", "a"), ("s", "ong"), ("d", "ai"), ("f", "en"), ("g", "eng"), ("h", "ang"), ("j", "an"), ("k", "ing"), ("l", "iang")],
        [("z", "ou"), ("x", "ia"), ("c", "ao"), ("v", "zh"), ("b", "in"), ("n", "iao"), ("m", "ian")],
    ]

    init(actions: KeyboardActions) {
        self.actions = actions
        super.init(frame: .zero)
        candidateBar.onSelect = { [weak self] index in self?.selectCandidate(index) }
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshReturnTitle() { returnButton.setTitle(actions.returnTitle(), for: .normal) }

    /// 离开这一页或键盘收起：丢掉没上屏的拼音
    func reset() {
        engine.clear()
        refresh()
    }

    // MARK: - 布局

    private func build() {
        let rowsStack = UIStackView()
        rowsStack.axis = .vertical
        rowsStack.spacing = 12
        rowsStack.distribution = .fillEqually
        for (index, row) in Self.rows.enumerated() {
            let keys = row.map { key -> UIButton in
                let b = HintKeyButton(letter: key.0, hint: key.1)
                b.addTarget(self, action: #selector(letterTapped(_:)), for: .touchUpInside)
                return b
            }
            let keyRow = UIStackView(arrangedSubviews: keys)
            keyRow.axis = .horizontal
            keyRow.spacing = 6
            keyRow.distribution = .fillEqually
            let line = UIStackView()
            line.axis = .horizontal
            line.spacing = 6
            if index == 2 {
                let apostrophe = KeyButton(title: "'", style: .function, fontSize: 20)
                apostrophe.accessibilityLabel = "分词"
                apostrophe.addTarget(self, action: #selector(apostropheTapped), for: .touchUpInside)
                let delete = KeyButton(image: "delete.left", style: .function)
                deleter.attach(to: delete)
                [apostrophe, keyRow, delete].forEach { line.addArrangedSubview($0) }
                line.setCustomSpacing(14, after: apostrophe)
                line.setCustomSpacing(14, after: keyRow)
                apostrophe.widthAnchor.constraint(equalToConstant: 46).isActive = true
                delete.widthAnchor.constraint(equalToConstant: 46).isActive = true
            } else if index == 1 {
                let wrap = UIView()
                keyRow.translatesAutoresizingMaskIntoConstraints = false
                wrap.addSubview(keyRow)
                NSLayoutConstraint.activate([
                    keyRow.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
                    keyRow.topAnchor.constraint(equalTo: wrap.topAnchor),
                    keyRow.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
                    keyRow.widthAnchor.constraint(equalTo: wrap.widthAnchor, multiplier: 0.9),
                ])
                line.addArrangedSubview(wrap)
            } else {
                line.addArrangedSubview(keyRow)
            }
            rowsStack.addArrangedSubview(line)
        }

        let comma = KeyButton(title: "，", style: .function, fontSize: 18)
        comma.addTarget(self, action: #selector(commaTapped), for: .touchUpInside)
        let english = KeyButton(title: "英", style: .function, fontSize: 15)
        english.addTarget(self, action: #selector(englishTapped), for: .touchUpInside)
        let space = KeyButton(title: "空格", style: .letter, fontSize: 15)
        space.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        returnButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        refreshReturnTitle()
        let globe = KeyButton(image: "globe", style: .function)
        actions.attachGlobe(globe)
        let bottom = UIStackView(arrangedSubviews: [globe, comma, english, space, returnButton])
        bottom.axis = .horizontal
        bottom.spacing = 6

        let root = UIStackView(arrangedSubviews: [rowsStack, bottom])
        root.axis = .vertical
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: 48),
            globe.widthAnchor.constraint(equalToConstant: 44),
            comma.widthAnchor.constraint(equalToConstant: 44),
            english.widthAnchor.constraint(equalToConstant: 44),
            returnButton.widthAnchor.constraint(equalToConstant: 72),
        ])
    }

    // MARK: - 输入

    private func refresh() {
        let state = engine.state()
        candidateBar.show(preedit: state.preedit, candidates: state.candidates)
        if state.isComposing != composing {
            composing = state.isComposing
            onComposingChange?(composing)
        }
    }

    private func commit(_ text: String?) {
        if let text, !text.isEmpty { actions.insert(text) }
        refresh()
    }

    private func ensureEngine() -> Bool {
        if engineFailed { return false }
        if !engine.start() {
            engineFailed = true
            candidateBar.show(preedit: "双拼引擎没加载起来，先用 EN 或语音吧", candidates: [])
            onComposingChange?(true)
            return false
        }
        return true
    }

    @objc private func letterTapped(_ sender: HintKeyButton) {
        guard ensureEngine() else { return }
        commit(engine.input(Character(sender.letter)))
    }

    @objc private func apostropheTapped() {
        guard composing, ensureEngine() else { return }
        commit(engine.input("'"))
    }

    private func deleteTapped() {
        if composing {
            engine.backspace()
            refresh()
        } else {
            actions.deleteBackward()
        }
    }

    private func selectCandidate(_ index: Int) {
        commit(engine.select(index))
    }

    @objc private func spaceTapped() {
        if composing { selectCandidate(0) } else { actions.insert(" ") }
    }

    @objc private func returnTapped() {
        if composing {
            let raw = engine.rawInput()
            engine.clear()
            commit(raw)
        } else {
            actions.returnKey()
        }
    }

    @objc private func commaTapped() {
        if composing { selectCandidate(0) }
        actions.insert("，")
    }

    @objc private func englishTapped() {
        if composing { reset() }
        onSwitchToEnglish?()
    }
}

/// 双拼字母键：中间大写字母，右下角小字韵母
final class HintKeyButton: KeyButton {
    let letter: String

    init(letter: String, hint: String) {
        self.letter = letter
        super.init(title: letter.uppercased(), style: .letter, fontSize: 20)
        accessibilityLabel = letter
        let hintLabel = UILabel()
        hintLabel.text = hint
        hintLabel.font = .systemFont(ofSize: 9)
        hintLabel.textColor = KTheme.secondary
        hintLabel.isUserInteractionEnabled = false
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 输入中盖在顶栏上的候选条：左边拼音，右边可横滑的候选
final class CandidateBar: UIView {
    var onSelect: ((Int) -> Void)?

    private let preeditLabel = UILabel()
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        preeditLabel.font = .systemFont(ofSize: 13)
        preeditLabel.textColor = KTheme.secondary
        preeditLabel.setContentHuggingPriority(.required, for: .horizontal)
        preeditLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        scroll.showsHorizontalScrollIndicator = false
        stack.axis = .horizontal
        stack.spacing = 18
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        let row = UIStackView(arrangedSubviews: [preeditLabel, scroll])
        row.axis = .horizontal
        row.spacing = 14
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.heightAnchor.constraint(equalTo: row.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(preedit: String, candidates: [String]) {
        preeditLabel.text = preedit
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, text) in candidates.enumerated() {
            let b = UIButton(type: .custom)
            b.setTitle(text, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 19, weight: i == 0 ? .semibold : .regular)
            b.setTitleColor(KTheme.text, for: .normal)
            b.tag = i
            b.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
        scroll.setContentOffset(.zero, animated: false)
    }

    @objc private func tapped(_ sender: UIButton) { onSelect?(sender.tag) }
}
