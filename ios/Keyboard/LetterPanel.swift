import UIKit

/// 英文键盘（含数字符号层）。双拼没做好前，「拼」页也用它的底栏 + 一句提示。
final class LetterPanel: UIView {
    private enum Layer { case letters, numbers, symbols }
    private enum Shift { case off, once, locked }

    private let actions: KeyboardActions
    private let placeholder: String?
    private var layer_ = Layer.letters { didSet { rebuildKeys() } }
    private var shift = Shift.off { didSet { refreshCase() } }
    private var lastShiftTap = Date.distantPast

    private let rowsStack = UIStackView()
    private var letterButtons: [UIButton] = []
    private var shiftButton: KeyButton?
    private let layerButton = KeyButton(title: "123", style: .function, fontSize: 15)
    private let returnButton = KeyButton(title: "发送", style: .function, fontSize: 15)
    private lazy var deleter = DeleteRepeater { [weak self] in self?.actions.deleteBackward() }
    private lazy var trackpad = SpaceTrackpad(move: actions.moveCursor)

    /// placeholder 非空 = 只显示这句提示和底栏（「拼」页）
    init(actions: KeyboardActions, placeholder: String? = nil) {
        self.actions = actions
        self.placeholder = placeholder
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshReturnTitle() { returnButton.setTitle(actions.returnTitle(), for: .normal) }

    private func build() {
        rowsStack.axis = .vertical
        rowsStack.spacing = 12
        rowsStack.distribution = .fillEqually

        let globe = KeyButton(image: "globe", style: .function)
        actions.attachGlobe(globe)
        layerButton.addTarget(self, action: #selector(layerTapped), for: .touchUpInside)
        let space = KeyButton(title: placeholder == nil ? "space" : "空格", style: .letter, fontSize: 15)
        trackpad.attach(to: space)
        space.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        returnButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        refreshReturnTitle()
        var bottomItems: [UIView] = [globe]
        if placeholder == nil { bottomItems.append(layerButton) }
        bottomItems += [space]
        if placeholder != nil {
            let delete = KeyButton(image: "delete.left", style: .function)
            deleter.attach(to: delete)
            bottomItems.append(delete)
            delete.widthAnchor.constraint(equalToConstant: 52).isActive = true
        }
        bottomItems.append(returnButton)
        let bottom = UIStackView(arrangedSubviews: bottomItems)
        bottom.axis = .horizontal
        bottom.spacing = 6

        let root = UIStackView()
        root.axis = .vertical
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        if let placeholder {
            let label = UILabel()
            label.text = placeholder
            label.font = .systemFont(ofSize: 15)
            label.textColor = KTheme.secondary
            label.textAlignment = .center
            label.numberOfLines = 0
            root.addArrangedSubview(label)
        } else {
            root.addArrangedSubview(rowsStack)
        }
        root.addArrangedSubview(bottom)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            globe.widthAnchor.constraint(equalToConstant: 44),
            returnButton.widthAnchor.constraint(equalToConstant: 72),
            bottom.heightAnchor.constraint(equalToConstant: 48),
        ])
        if placeholder == nil {
            layerButton.widthAnchor.constraint(equalToConstant: 48).isActive = true
            rebuildKeys()
        }
    }

    private var rows: [[String]] {
        switch layer_ {
        case .letters: return ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { $0.map(String.init) }
        case .numbers: return [Array("1234567890").map(String.init), ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""], [".", ",", "?", "!", "'"]]
        case .symbols: return [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="], ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"], [".", ",", "?", "!", "'"]]
        }
    }

    private func rebuildKeys() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        letterButtons.removeAll()
        let rows = rows
        for (index, row) in rows.enumerated() {
            let line = UIStackView()
            line.axis = .horizontal
            line.spacing = 6
            line.distribution = .fill
            var keys: [UIButton] = []
            for title in row {
                let key = KeyButton(title: title)
                key.addTarget(self, action: #selector(charTapped(_:)), for: .touchUpInside)
                keys.append(key)
            }
            letterButtons += keys
            let keyRow = UIStackView(arrangedSubviews: keys)
            keyRow.axis = .horizontal
            keyRow.spacing = 6
            keyRow.distribution = .fillEqually

            if index == 2 {
                // 第三行：⇧ / 符号切换 · 字母 · 删除
                let left: KeyButton
                if layer_ == .letters {
                    left = KeyButton(image: "shift", style: .function)
                    left.addTarget(self, action: #selector(shiftTapped), for: .touchUpInside)
                    shiftButton = left
                } else {
                    left = KeyButton(title: layer_ == .numbers ? "#+=" : "123", style: .function, fontSize: 15)
                    left.addTarget(self, action: #selector(symbolToggleTapped), for: .touchUpInside)
                    shiftButton = nil
                }
                let delete = KeyButton(image: "delete.left", style: .function)
                deleter.attach(to: delete)
                [left, keyRow, delete].forEach { line.addArrangedSubview($0) }
                line.setCustomSpacing(layer_ == .letters ? 14 : 22, after: left)
                line.setCustomSpacing(layer_ == .letters ? 14 : 22, after: keyRow)
                left.widthAnchor.constraint(equalToConstant: 46).isActive = true
                delete.widthAnchor.constraint(equalToConstant: 46).isActive = true
            } else if index == 1 && layer_ == .letters {
                // 第二行 9 个键，两边各让半个键
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
        layerButton.setTitle(layer_ == .letters ? "123" : "ABC", for: .normal)
        refreshCase()
    }

    private func refreshCase() {
        guard layer_ == .letters else { return }
        let upper = shift != .off
        for button in letterButtons {
            let t = button.title(for: .normal) ?? ""
            button.setTitle(upper ? t.uppercased() : t.lowercased(), for: .normal)
        }
        let name: String
        switch shift {
        case .off: name = "shift"
        case .once: name = "shift.fill"
        case .locked: name = "capslock.fill"
        }
        shiftButton?.setImage(KTheme.sfImage(name, 18), for: .normal)
    }

    @objc private func charTapped(_ sender: UIButton) {
        guard let t = sender.title(for: .normal) else { return }
        actions.insert(t)
        if shift == .once { shift = .off }
    }

    @objc private func shiftTapped() {
        let now = Date()
        if now.timeIntervalSince(lastShiftTap) < 0.35 {
            shift = .locked
        } else {
            shift = shift == .off ? .once : .off
        }
        lastShiftTap = now
    }

    @objc private func layerTapped() { layer_ = layer_ == .letters ? .numbers : .letters }
    @objc private func symbolToggleTapped() { layer_ = layer_ == .numbers ? .symbols : .numbers }
    @objc private func spaceTapped() { actions.insert(" ") }
    @objc private func returnTapped() { actions.returnKey() }
}
