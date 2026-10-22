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
    /// 这一串自己敲过的字母：回车上屏原文时，万一引擎那边取不到就用它
    private var typed = ""
    /// 输入框里现在有没有「输入中」的字母
    private var hasMarked = false
    private var engineFailed = false
    private let returnButton = KeyButton(title: "发送", style: .function, fontSize: 15)
    private let lettersStack = UIStackView()
    private let symbolsStack = UIStackView()

    /// 数字和中文标点，照 iOS 原生中文键盘：「123」进，「#+=」看更多符号，左下「拼」回字母
    private static let numberRows: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", "：", "；", "（", "）", "¥", "@", "“", "”"],
        ["。", "，", "、", "？", "！", "."],
    ]
    private static let moreRows: [[String]] = [
        ["【", "】", "｛", "｝", "#", "%", "^", "*", "+", "="],
        ["_", "—", "\\", "｜", "～", "《", "》", "$", "&", "·"],
        ["…", "，", "^_^", "？", "！", "‘"],
    ]
    private enum SymbolLayer { case none, numbers, more }
    private var symbolLayer = SymbolLayer.none { didSet { applySymbolLayer() } }
    private var bottomComma: KeyButton?
    private var bottomLayerKey: KeyButton?
    private lazy var deleter = DeleteRepeater { [weak self] in self?.deleteTapped() }
    private lazy var trackpad = SpaceTrackpad(move: actions.moveCursor)

    private static let rows: [[(String, String)]] = [
        [("q", "iu"), ("w", "ei"), ("e", "e"), ("r", "uan"), ("t", "ue"), ("y", "un"), ("u", "sh"), ("i", "ch"), ("o", "uo"), ("p", "ie")],
        [("a", "a"), ("s", "ong"), ("d", "ai"), ("f", "en"), ("g", "eng"), ("h", "ang"), ("j", "an"), ("k", "ing"), ("l", "iang")],
        [("z", "ou"), ("x", "ia"), ("c", "ao"), ("v", "zh"), ("b", "in"), ("n", "iao"), ("m", "ian")],
    ]

    init(actions: KeyboardActions) {
        self.actions = actions
        super.init(frame: .zero)
        candidateBar.onSelect = { [weak self] index in self?.selectCandidate(index) }
        trackpad.isAllowed = { [weak self] in !(self?.composing ?? false) }
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 输入中回车 = 把敲的字母原样上屏（中英夹杂时直接敲英文），键上写「确认」，和系统拼音一致
    func refreshReturnTitle() { returnButton.setTitle(composing ? "确认" : actions.returnTitle(), for: .normal) }

    /// 离开这一页或键盘收起：丢掉没上屏的拼音
    func reset() {
        engine.clear()
        clearMarked()
        symbolLayer = .none
        refresh()
    }

    // MARK: - 布局

    private func build() {
        let rowsStack = lettersStack
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
                let apostrophe = KeyButton(title: "123", style: .function, fontSize: 15)
                apostrophe.accessibilityLabel = "数字和符号"
                apostrophe.addTarget(self, action: #selector(layerTapped), for: .touchUpInside)
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
        english.addTarget(self, action: #selector(bottomLayerTapped), for: .touchUpInside)
        bottomComma = comma
        bottomLayerKey = english
        let space = KeyButton(title: "空格", style: .letter, fontSize: 15)
        trackpad.attach(to: space)
        space.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        returnButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        refreshReturnTitle()
        let globe = KeyButton(image: "globe", style: .function)
        actions.attachGlobe(globe)
        let bottom = UIStackView(arrangedSubviews: [globe, comma, english, space, returnButton])
        bottom.axis = .horizontal
        bottom.spacing = 6

        symbolsStack.axis = .vertical
        symbolsStack.spacing = 12
        symbolsStack.distribution = .fillEqually
        symbolsStack.isHidden = true
        let root = UIStackView(arrangedSubviews: [rowsStack, symbolsStack, bottom])
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
        // 敲的字母（如 hcxl）直接显示在输入框里，带下划线，和系统拼音一样；选了候选或清空时换掉
        if state.isComposing {
            let raw = engine.rawInput()
            actions.setMarked(raw.isEmpty ? typed : raw)
            hasMarked = true
        } else {
            clearMarked()
        }
        if state.isComposing != composing {
            composing = state.isComposing
            if !composing { typed = "" }
            refreshReturnTitle()
            onComposingChange?(composing)
        }
    }

    private func commit(_ text: String?) {
        if let text, !text.isEmpty {
            clearMarked()   // 先撤掉输入中的字母，再上屏选中的字
            actions.insert(text)
        }
        refresh()
    }

    private func clearMarked() {
        guard hasMarked else { return }
        actions.setMarked("")
        actions.unmark()
        hasMarked = false
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
        if !composing { typed = "" }
        typed.append(sender.letter)
        commit(engine.input(Character(sender.letter)))
    }

    private func buildSymbols(_ rows: [[String]]) {
        symbolsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, row) in rows.enumerated() {
            let keys = row.map { title -> UIButton in
                let b = KeyButton(title: title, style: .letter, fontSize: title.count > 1 ? 16 : 20)
                b.addTarget(self, action: #selector(symbolTapped(_:)), for: .touchUpInside)
                return b
            }
            let keyRow = UIStackView(arrangedSubviews: keys)
            keyRow.axis = .horizontal
            keyRow.spacing = 6
            keyRow.distribution = .fillEqually
            if index == 2 {
                // 第三行：#+= / 123 · 六个标点（键更宽）· 删除
                let toggle = KeyButton(title: symbolLayer == .more ? "123" : "#+=", style: .function, fontSize: 15)
                toggle.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
                let delete = KeyButton(image: "delete.left", style: .function)
                deleter.attach(to: delete)
                let line = UIStackView(arrangedSubviews: [toggle, keyRow, delete])
                line.axis = .horizontal
                line.spacing = 14
                toggle.widthAnchor.constraint(equalToConstant: 46).isActive = true
                delete.widthAnchor.constraint(equalToConstant: 46).isActive = true
                symbolsStack.addArrangedSubview(line)
            } else {
                symbolsStack.addArrangedSubview(keyRow)
            }
        }
    }

    private func applySymbolLayer() {
        switch symbolLayer {
        case .none: break
        case .numbers: buildSymbols(Self.numberRows)
        case .more: buildSymbols(Self.moreRows)
        }
        let symbols = symbolLayer != .none
        symbolsStack.isHidden = !symbols
        lettersStack.isHidden = symbols
        // 符号层：左下角换成「拼」回字母（和原生键盘「123」/「拼」同一个位置），「，」隐藏
        bottomComma?.isHidden = symbols
        bottomLayerKey?.setTitle(symbols ? "拼" : "英", for: .normal)
        bottomLayerKey?.accessibilityLabel = symbols ? "回到拼音" : "英文键盘"
    }

    /// 字母层第三行左边的「123」
    @objc private func layerTapped() {
        if composing { selectCandidate(0) }
        symbolLayer = .numbers
    }

    @objc private func moreTapped() { symbolLayer = symbolLayer == .more ? .numbers : .more }

    /// 底栏「英」：字母层 = 去英文页；符号层 = 回字母
    @objc private func bottomLayerTapped() {
        if symbolLayer != .none { symbolLayer = .none } else { englishTapped() }
    }

    @objc private func symbolTapped(_ sender: UIButton) {
        guard let t = sender.title(for: .normal) else { return }
        if composing { selectCandidate(0) }
        actions.insert(t)
    }

    private func deleteTapped() {
        if composing {
            if !typed.isEmpty { typed.removeLast() }
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
            // 输入框里已经是敲的字母：直接确定下来，不再另插一遍
            if hasMarked {
                actions.unmark()
                hasMarked = false
                engine.clear()
                typed = ""
                refresh()
                return
            }
            let raw = engine.rawInput()
            let text = raw.isEmpty ? typed : raw
            engine.clear()
            typed = ""
            commit(text)
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

/// 输入中盖在顶栏上的候选条：上面一行小字拼音（太长只显示末尾），下面一整行候选，可横滑
final class CandidateBar: UIView {
    var onSelect: ((Int) -> Void)?

    private let preeditLabel = UILabel()
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        preeditLabel.font = .systemFont(ofSize: 11)
        preeditLabel.textColor = KTheme.secondary
        preeditLabel.lineBreakMode = .byTruncatingHead
        scroll.showsHorizontalScrollIndicator = false
        stack.axis = .horizontal
        stack.spacing = 18
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        [preeditLabel, scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            preeditLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            preeditLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            preeditLabel.topAnchor.constraint(equalTo: topAnchor, constant: -4),
            preeditLabel.heightAnchor.constraint(equalToConstant: 13),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: preeditLabel.bottomAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 2),
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
